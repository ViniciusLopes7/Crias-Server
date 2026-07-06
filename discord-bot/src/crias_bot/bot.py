"""Discord bot: slash commands and event bridge for the Crias-Server.

Exposes `/mc` commands (start/stop/restart/status/players/say/console/health)
and forwards agent events to Discord via standardized embeds.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import time

import discord
from discord import app_commands
from discord.ext import commands, tasks

from .agent_client import AgentClient, AgentClientError
from .config import BotConfig
from .embeds import (
    agent_error,
    command_result,
    console_stream_error,
    console_stream_started,
    console_stream_stopped,
    error,
    event_embed,
    health_report,
    permission_denied,
    players_list,
    say_confirmation,
    status_offline,
    status_online,
    warning,
)

logger = logging.getLogger(__name__)


# RCON message sanitizer: strips control characters.
_RCON_MSG_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def _sanitize_rcon_message(msg: str) -> str | None:
    """Sanitize RCON message; return None if invalid (newlines, controls, >200 chars)."""
    if not msg or not msg.strip():
        return None
    if "\n" in msg or "\r" in msg or "\0" in msg:
        return None
    if len(msg) > 200:
        return None
    sanitized = _RCON_MSG_RE.sub("", msg)
    if not sanitized.strip():
        return None
    return sanitized


class _RateLimiter:
    """Per-user sliding window rate limiter."""

    def __init__(self, max_calls: int = 5, period: float = 10.0) -> None:
        self.max_calls = max_calls
        self.period = period
        self._calls: dict[int, list[float]] = {}

    def is_allowed(self, user_id: int) -> bool:
        now = time.monotonic()
        history = self._calls.get(user_id, [])
        # keep calls within the window
        history = [t for t in history if now - t < self.period]
        if len(history) >= self.max_calls:
            self._calls[user_id] = history
            return False
        history.append(now)
        self._calls[user_id] = history
        return True


class CriasBot(commands.Bot):
    """Discord bot for the Crias-Server."""

    def __init__(self, config: BotConfig, agent: AgentClient) -> None:
        intents = discord.Intents.default()
        intents.message_content = False  # slash-only; no message content needed
        intents.members = False

        super().__init__(
            command_prefix=commands.when_mentioned_or("!"),
            intents=intents,
        )

        self.config = config
        self.agent = agent
        self._console_stream_active = False
        self._console_task: asyncio.Task | None = None
        # Atomic toggle guard to prevent zombie tasks on concurrent calls.
        self._console_lock: asyncio.Lock = asyncio.Lock()
        # per-user rate limiter
        self._rate_limiter = _RateLimiter(max_calls=5, period=10.0)

    async def setup_hook(self) -> None:
        """Sync slash commands to guild if FORCE_SYNC_COMMANDS is set."""
        await self.add_cog(MinecraftCog(self))

        # Sync only on demand to avoid Discord rate limits at every startup.
        force_sync = os.environ.get("FORCE_SYNC_COMMANDS", "false").strip().lower() == "true"
        if force_sync:
            if self.config.guild_id:
                guild = discord.Object(id=self.config.guild_id)
                self.tree.copy_global_to(guild=guild)
                synced = await self.tree.sync(guild=guild)
                logger.info("Sincronizados %d slash commands no guild %d", len(synced), guild.id)
            else:
                synced = await self.tree.sync()
                logger.info("Sincronizados %d slash commands globalmente", len(synced))
        else:
            logger.info("Sync de comandos pulado (set FORCE_SYNC_COMMANDS=true para forçar)")

        # Start event bridge background task.
        self.event_bridge.start()

    async def close(self) -> None:
        """Graceful shutdown: cancel tasks and close gRPC channel."""
        self.event_bridge.cancel()
        if self._console_task is not None:
            self._console_task.cancel()
            try:
                await self._console_task
            except asyncio.CancelledError:
                pass
        await self.agent.close()
        await super().close()

    # --- Permissões ---

    def is_admin(self, user: discord.User | discord.Member) -> bool:
        if isinstance(user, discord.User):
            return False
        if user.guild_permissions.administrator:
            return True
        return any(role.id in self.config.admin_role_ids for role in user.roles)

    def is_moderator(self, user: discord.User | discord.Member) -> bool:
        if self.is_admin(user):
            return True
        if not isinstance(user, discord.Member):
            return False
        return any(role.id in self.config.moderator_role_ids for role in user.roles)

    # --- Background tasks ---

    @tasks.loop(seconds=5)
    async def event_bridge(self) -> None:
        """Subscribe to agent events and post to Discord; reconnects on error."""
        try:
            async for ev in self.agent.subscribe_events():
                await self._dispatch_event(ev)
        except AgentClientError as e:
            logger.warning("EventBridge falhou (vai tentar de novo em 5s): %s", e)
        except (TimeoutError, OSError, ConnectionError) as e:
            logger.warning("EventBridge: erro de rede: %s", e)
        except Exception:
            # Catch-all for unexpected bugs; log traceback for diagnosis.
            logger.exception("Erro inesperado no EventBridge")

    @event_bridge.before_loop
    async def _before_event_bridge(self) -> None:
        await self.wait_until_ready()

    async def _dispatch_event(self, ev: dict) -> None:
        """Dispatch agent event to #controle channel via standardized embed."""
        if self.config.controle_channel_id is None:
            return

        channel = self.get_channel(self.config.controle_channel_id)
        if channel is None or not isinstance(channel, discord.TextChannel):
            return

        embed = event_embed(ev)
        if embed is None:
            # Unknown event: log and post short text fallback.
            event_type = ev.get("event_type", "")
            metadata = ev.get("metadata", {})
            logger.debug("Evento sem embed dedicado: %s", event_type)
            embed = warning(
                f"Evento: {event_type}",
                f"```\n{metadata}\n```",
            )

        try:
            await channel.send(embed=embed)
        except discord.HTTPException:
            logger.warning(
                "Falha ao postar evento %s no canal %d", ev.get("event_type"), channel.id
            )


class MinecraftCog(commands.Cog):
    """Cog exposing the `/mc` slash commands."""

    group = app_commands.Group(name="mc", description="Comandos do Minecraft")

    def __init__(self, bot: CriasBot) -> None:
        self.bot = bot

    # ------------------------------------------------------------------
    # Internal helpers to reduce permission and error-handling boilerplate.
    # ------------------------------------------------------------------

    async def _check_admin(self, interaction: discord.Interaction) -> bool:
        """Check admin permission; replies with error and returns False if denied."""
        if self.bot.is_admin(interaction.user):
            return True
        await interaction.response.send_message(embed=permission_denied("admin"), ephemeral=True)
        return False

    async def _check_moderator(self, interaction: discord.Interaction) -> bool:
        """Check moderator+ permission; replies with error and returns False if denied."""
        if self.bot.is_moderator(interaction.user):
            return True
        await interaction.response.send_message(
            embed=permission_denied("moderador"), ephemeral=True
        )
        return False

    async def _send_agent_error(self, interaction: discord.Interaction, e: Exception) -> None:
        """Send agent error embed as followup."""
        await interaction.followup.send(embed=agent_error(str(e)))

    # ------------------------------------------------------------------
    # Slash commands.
    # ------------------------------------------------------------------

    @group.command(name="start", description="Liga o servidor")
    async def start(self, interaction: discord.Interaction) -> None:
        if not await self._check_admin(interaction):
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.start_server()
            embed = command_result(
                ok=bool(result["ok"]),
                action="iniciado",
                message=result.get("message", ""),
                service=result.get("service", ""),
            )
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="stop", description="Desliga o servidor")
    async def stop(self, interaction: discord.Interaction) -> None:
        if not await self._check_admin(interaction):
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.stop_server()
            embed = command_result(
                ok=bool(result["ok"]),
                action="parado",
                message=result.get("message", ""),
                service=result.get("service", ""),
            )
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="restart", description="Reinicia o servidor")
    async def restart(self, interaction: discord.Interaction) -> None:
        if not await self._check_admin(interaction):
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.restart_server()
            embed = command_result(
                ok=bool(result["ok"]),
                action="reiniciado",
                message=result.get("message", ""),
                service=result.get("service", ""),
            )
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="status", description="Mostra status do servidor")
    async def status(self, interaction: discord.Interaction) -> None:
        await interaction.response.defer(thinking=True)
        try:
            s = await self.bot.agent.get_status()
            if not s["service_active"]:
                embed = status_offline(s.get("service_name", "?"))
            else:
                embed = status_online(s)
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="players", description="Lista players online")
    async def players(self, interaction: discord.Interaction) -> None:
        await interaction.response.defer(thinking=True)
        try:
            s = await self.bot.agent.get_status()
            embed = players_list(s)
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="say", description="Manda mensagem no chat do jogo via RCON")
    @app_commands.describe(message="Mensagem a ser enviada (máx 200 caracteres)")
    async def say(self, interaction: discord.Interaction, message: str) -> None:
        if not await self._check_moderator(interaction):
            return
        # per-user rate limit
        if not self.bot._rate_limiter.is_allowed(interaction.user.id):
            await interaction.response.send_message(
                embed=warning(
                    "Muitas requisições", "Aguarde alguns segundos antes de tentar novamente."
                ),
                ephemeral=True,
            )
            return
        # sanitize before sending to RCON
        sanitized = _sanitize_rcon_message(message)
        if sanitized is None:
            await interaction.response.send_message(
                embed=error(
                    "Mensagem inválida",
                    "A mensagem não pode conter newlines, caracteres de controle, "
                    "ou exceder 200 caracteres.",
                ),
                ephemeral=True,
            )
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.send_rcon_command(f"say {sanitized}")
            if result.get("ok"):
                await interaction.followup.send(embed=say_confirmation(sanitized), ephemeral=True)
            else:
                err_msg = result.get("error", "erro desconhecido")
                await interaction.followup.send(
                    embed=error("Falha no RCON", f"```\n{err_msg}\n```"),
                    ephemeral=True,
                )
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="health", description="Verifica saúde do servidor")
    async def health(self, interaction: discord.Interaction) -> None:
        if not await self._check_admin(interaction):
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            h = await self.bot.agent.get_health()
            await interaction.followup.send(embed=health_report(h), ephemeral=True)
        except AgentClientError as e:
            await self._send_agent_error(interaction, e)

    @group.command(name="console", description="Ativa/desativa stream de console no canal #console")
    async def console(self, interaction: discord.Interaction) -> None:
        if not await self._check_admin(interaction):
            return

        # Atomic toggle to avoid races between concurrent admins.
        async with self.bot._console_lock:
            if self.bot._console_stream_active:
                # Disable.
                self.bot._console_stream_active = False
                if self.bot._console_task is not None:
                    self.bot._console_task.cancel()
                    self.bot._console_task = None
                await interaction.response.send_message(embed=console_stream_stopped())
                return

            # Enable.
            channel_id = self.bot.config.console_channel_id
            if channel_id is None:
                await interaction.response.send_message(
                    embed=error(
                        "Canal #console não configurado",
                        "Defina `DISCORD_CONSOLE_CHANNEL_ID` nas variáveis de ambiente do bot.",
                    ),
                    ephemeral=True,
                )
                return

            channel = self.bot.get_channel(channel_id)
            if channel is None or not isinstance(channel, discord.TextChannel):
                await interaction.response.send_message(
                    embed=error(
                        "Canal #console inválido",
                        f"Canal `{channel_id}` não encontrado ou não é um canal de texto.",
                    ),
                    ephemeral=True,
                )
                return

            self.bot._console_stream_active = True
            self.bot._console_task = asyncio.create_task(self._console_stream_loop(channel))
            await interaction.response.send_message(embed=console_stream_started(channel.mention))

    async def _console_stream_loop(self, channel: discord.TextChannel) -> None:
        """Consume StreamConsole and post to #console; 2s buffer, ~1800-char chunks (Discord limit)."""
        buffer: list[str] = []
        last_flush = time.monotonic()
        MAX_CHARS = 1800  # margin for ``` + newlines

        try:
            async for line in self.bot.agent.stream_console(tail_lines=50):
                buffer.append(line)

                # Flush every 2s or when buffer fills.
                now = time.monotonic()
                total_chars = sum(len(s) for s in buffer)
                if total_chars >= MAX_CHARS or (now - last_flush) >= 2.0:
                    if buffer:
                        # Split into chunks that fit within MAX_CHARS.
                        chunks = _partition_lines(buffer, MAX_CHARS)
                        for chunk in chunks:
                            try:
                                await channel.send(f"```\n{chunk}\n```")
                            except discord.HTTPException:
                                pass  # rate limited or message too long
                        buffer = []
                        last_flush = now
        except AgentClientError as e:
            logger.warning("Console stream falhou: %s", e)
            try:
                await channel.send(embed=console_stream_error(str(e)))
            except discord.HTTPException:
                pass
        except asyncio.CancelledError:
            logger.info("Console stream cancelado")
            raise
        finally:
            self.bot._console_stream_active = False


def _partition_lines(lines: list[str], max_chars: int) -> list[str]:
    """Split lines into chunks that fit within max_chars."""
    chunks: list[str] = []
    current: list[str] = []
    current_size = 0
    for line in lines:
        line_size = len(line) + 1  # +1 for \n
        if current_size + line_size > max_chars and current:
            chunks.append("\n".join(current))
            current = []
            current_size = 0
        current.append(line)
        current_size += line_size
    if current:
        chunks.append("\n".join(current))
    return chunks


def _format_uptime(seconds: int) -> str:
    """Format uptime as 'Xs', 'Xm', 'Xh Ym' or 'Xd Yh'."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"
