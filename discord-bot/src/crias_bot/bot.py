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
from pathlib import Path

import discord
from discord import app_commands
from discord.ext import commands, tasks

from .agent_client import AgentClient, AgentClientError, AgentOfflineError
from .config import BotConfig
from .embeds import (
    agent_error,
    agent_offline,
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
    truncate_for_codeblock,
    warning,
)
from .healthcheck import HEARTBEAT_PATH

logger = logging.getLogger(__name__)


# RCON message sanitizer: strips control characters.
_RCON_MSG_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")

# ---------------------------------------------------------------------------
# Console stream constants (EXP-47 / EXP-61).
# ---------------------------------------------------------------------------

# EXP-61: game/mod-controlled log lines may contain triple backticks (which
# would break the code fence) and @everyone/@here (mass mentions). Every
# chunk posted to #console is sanitized and sent with mentions disabled.
_TRIPLE_BACKTICK_RE = re.compile(r"`{3,}")
# Content budget inside the code fence; Discord caps messages at 2000 chars.
_CONSOLE_MAX_CONTENT = 1800
# EXP-47: the agent closes StreamConsole at its server-side deadline
# (default 5 min) and emits this marker line just before closing.
_CONSOLE_DEADLINE_MARKER = "[crias-agent] console stream deadline reached"
# Reopen policy: exponential backoff 1s → 15s; give up after 5 consecutive
# unhealthy attempts (instant errors or sub-minute streams).
_CONSOLE_RECONNECT_INITIAL_DELAY = 1.0
_CONSOLE_RECONNECT_MAX_DELAY = 15.0
_CONSOLE_MAX_RECONNECT_FAILURES = 5
_CONSOLE_STREAM_MIN_LIFETIME = 60.0
# journalctl tail on reopen: cover the backoff gap without replaying the
# initial 50-line history on every deadline reopen.
_CONSOLE_RECONNECT_TAIL_LINES = 1
# Discord send failures tolerated before auto-stopping the stream.
_CONSOLE_MAX_SEND_FAILURES = 5

# _send_console_buffer outcomes.
_FLUSH_OK = "ok"
_FLUSH_RETRY = "retry"
_FLUSH_STOP = "stop"


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
        # CR-22: login state — the heartbeat file is only written when set.
        self._bot_ready = False
        # CR-30: log the manual-sync notice only once per process.
        self._sync_notice_logged = False

    async def setup_hook(self) -> None:
        """Sync slash commands to guild if FORCE_SYNC_COMMANDS is set."""
        await self.add_cog(MinecraftCog(self))

        # Register global slash command error handler (M-10) so unhandled
        # exceptions don't leave interactions stuck in "Bot is thinking...".
        self.tree.error(self._handle_app_command_error)

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
        # CR-22: liveness heartbeat for the Docker healthcheck.
        self.heartbeat.start()

    async def on_ready(self) -> None:
        """Mark the bot as ready (heartbeat gate) and log sync guidance.

        CR-30: on a fresh deploy without FORCE_SYNC_COMMANDS the bot comes
        online with no commands, which looks broken. Log (once) that sync
        is manual and how to trigger it, including how many app commands
        are registered locally.
        """
        self._bot_ready = True
        if self._sync_notice_logged:
            return
        self._sync_notice_logged = True
        force_sync = os.environ.get("FORCE_SYNC_COMMANDS", "false").strip().lower() == "true"
        if not force_sync:
            logger.info(
                "Sync de comandos é manual: %d comandos registrados localmente. "
                "Para sincronizar com o Discord, defina FORCE_SYNC_COMMANDS=true "
                "e reinicie o bot (guild sync é instantâneo; global pode levar ~1h).",
                len(self.tree.get_commands()),
            )

    async def close(self) -> None:
        """Graceful shutdown: cancel tasks and close gRPC channel."""
        self.event_bridge.cancel()
        self.heartbeat.cancel()  # CR-22
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
        except AgentOfflineError:
            # CR-09: bounded connection wait — the supervised background
            # reconnect keeps trying; retry on the next loop tick.
            logger.debug("EventBridge: agente offline; tentarei de novo no próximo ciclo")
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

    @tasks.loop(seconds=30)
    async def heartbeat(self) -> None:
        """CR-22: write a liveness heartbeat file for the Docker healthcheck.

        The file is only written while the bot is connected
        (``_bot_ready``); a running tick itself proves the event loop is
        alive. ``crias_bot.healthcheck`` fails when the file goes stale
        (bot hung or gateway dead). Harmless outside containers — it is
        just a small file in /tmp.
        """
        if not self._bot_ready:
            return
        try:
            Path(HEARTBEAT_PATH).write_text(str(time.time()))
        except OSError as e:
            # Read-only FS, permissions, ... — the healthcheck will surface
            # persistent problems.
            logger.debug("Heartbeat: falha ao escrever %s: %s", HEARTBEAT_PATH, e)

    @heartbeat.before_loop
    async def _before_heartbeat(self) -> None:
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
                # EXP-61: metadata is game-controlled — sanitize backticks and
                # bound the length before interpolating into a code block.
                f"```\n{truncate_for_codeblock(str(metadata))}\n```",
            )

        try:
            await channel.send(embed=embed)
        except discord.HTTPException:
            logger.warning(
                "Falha ao postar evento %s no canal %d", ev.get("event_type"), channel.id
            )

    async def _handle_app_command_error(
        self,
        interaction: discord.Interaction,
        app_error: app_commands.AppCommandError,
    ) -> None:
        """Global catch-all for unhandled slash command exceptions.

        Logs the traceback and replies with a generic error embed so the user
        isn't stuck in "Bot is thinking..." for 15 minutes. Uses followup.send
        when the interaction has already been responded to; otherwise falls
        back to response.send_message (the only valid call on a fresh
        interaction). Parameter named `app_error` to avoid shadowing the
        imported `error` embed builder.
        """
        logger.exception("Erro não tratado em slash command: %s", app_error)
        generic = error(
            "Erro inesperado",
            "Ocorreu um erro ao processar o comando. Os logs foram registrados.",
        )
        try:
            if interaction.response.is_done():
                await interaction.followup.send(embed=generic, ephemeral=True)
            else:
                await interaction.response.send_message(embed=generic, ephemeral=True)
        except discord.HTTPException as e:
            logger.warning(
                "Não foi possível enviar mensagem de erro para a interaction %s: %s",
                interaction.id,
                e,
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
        """Send agent error embed as followup; fall back to plain text on HTTP failure.

        CR-09: ``AgentOfflineError`` gets a dedicated friendly, ephemeral
        reply (``agent_offline``) instead of the generic communication-error
        embed, so users know exactly what to check.
        """
        if isinstance(e, AgentOfflineError):
            try:
                await interaction.followup.send(embed=agent_offline(), ephemeral=True)
            except discord.HTTPException:
                logger.warning("Falha ao enviar embed de agente offline: %s", e)
            return
        try:
            await interaction.followup.send(embed=agent_error(str(e)))
        except discord.HTTPException:
            logger.warning("Falha ao enviar embed de erro de agente: %s", e)
            try:
                await interaction.followup.send(
                    f"❌ Falha de comunicação com o agente: `{str(e)[:1900]}`",
                )
            except discord.HTTPException:
                logger.error("Falha também no fallback de texto simples para erro de agente")

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
        # per-user rate limit.
        # P11: the rate-limit slot is consumed BEFORE input validation
        # intentionally. Validating first would let an attacker probe the
        # validator (e.g., sending borderline-length messages to learn the
        # exact length / character limits) without consuming a slot, enabling
        # enumeration via crafted invalid inputs. The cost (a moderator
        # "wastes" a slot on a malformed message) is acceptable.
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
                try:
                    await interaction.followup.send(
                        # EXP-61: RCON output is game-controlled — sanitize
                        # backticks and bound the length.
                        embed=error("Falha no RCON", f"```\n{truncate_for_codeblock(err_msg)}\n```"),
                        ephemeral=True,
                    )
                except discord.HTTPException:
                    logger.warning("Falha ao enviar embed de erro RCON: %s", err_msg[:200])
                    try:
                        await interaction.followup.send(
                            f"❌ Falha no RCON: `{err_msg[:1900]}`",
                            ephemeral=True,
                        )
                    except discord.HTTPException:
                        logger.error("Falha também no fallback de texto simples para erro RCON")
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
        """Consume StreamConsole and post to #console; 2s buffer, ~1800-char chunks.

        EXP-47: the agent closes StreamConsole at its server-side deadline
        (default 5 min). When the stream ends while the session is still
        active, this loop reopens it automatically with exponential backoff
        (1s → 15s) so the session keeps delivering logs; the agent's
        deadline marker line is filtered from the output. An attempt that
        saw the deadline marker or streamed for at least
        ``_CONSOLE_STREAM_MIN_LIFETIME`` is healthy and resets the backoff;
        short-lived/erroring attempts count toward
        ``_CONSOLE_MAX_RECONNECT_FAILURES`` consecutive failures.

        The session stops when: the user runs the stop command, the task is
        cancelled (bot shutdown), the #console channel disappears, Discord
        sends fail ``_CONSOLE_MAX_SEND_FAILURES`` times in a row, or
        reconnecting fails ``_CONSOLE_MAX_RECONNECT_FAILURES`` times in a
        row — the last two post a visible notice.

        On send failure the buffer is preserved and retried on the next flush
        so no console lines are silently dropped.
        """
        buffer: list[str] = []
        last_flush = time.monotonic()
        consecutive_send_failures = 0
        reconnect_delay = _CONSOLE_RECONNECT_INITIAL_DELAY
        consecutive_reconnect_failures = 0
        # First stream replays recent journal history; reopens use a minimal
        # tail so the 50-line history is not re-posted on every deadline.
        tail_lines = 50

        try:
            while self.bot._console_stream_active:
                attempt_started = time.monotonic()
                saw_deadline_marker = False
                try:
                    async for line in self.bot.agent.stream_console(tail_lines=tail_lines):
                        if _CONSOLE_DEADLINE_MARKER in line:
                            # Agent-side stream deadline: the stream is about
                            # to close and is reopened below (EXP-47). Filter
                            # the marker from user-visible output.
                            saw_deadline_marker = True
                            continue
                        buffer.append(line)

                        # Flush every 2s or when buffer fills.
                        now = time.monotonic()
                        total_chars = sum(len(s) for s in buffer)
                        if total_chars >= _CONSOLE_MAX_CONTENT or (now - last_flush) >= 2.0:
                            if not buffer:
                                last_flush = now
                                continue
                            status = await _send_console_buffer(channel, buffer)
                            if status == _FLUSH_STOP:
                                # Channel deleted — stop the stream (finally
                                # clears _console_stream_active).
                                return
                            if status == _FLUSH_OK:
                                # All chunks sent — clear buffer and reset
                                # the failure counter.
                                buffer = []
                                consecutive_send_failures = 0
                            else:
                                consecutive_send_failures += 1
                                if (
                                    consecutive_send_failures
                                    >= _CONSOLE_MAX_SEND_FAILURES
                                ):
                                    logger.warning(
                                        "Console stream: %d falhas consecutivas de envio; "
                                        "parando stream",
                                        consecutive_send_failures,
                                    )
                                    await self._notify_console_stream_auto_stopped(
                                        channel,
                                        "Stream de console parado após falhas consecutivas "
                                        "de envio.",
                                    )
                                    return
                                # Keep buffer for retry on next flush; advance
                                # last_flush so we don't busy-spin on it.
                            last_flush = now
                except AgentClientError as e:
                    logger.warning("Console stream interrompido (vai reconectar): %s", e)

                # Stream ended (agent deadline EOF or an error). Honor a user
                # stop that happened while we were streaming.
                if not self.bot._console_stream_active:
                    return

                # Best-effort flush of lines buffered during the attempt so
                # output keeps flowing across the reconnect gap.
                if buffer:
                    status = await _send_console_buffer(channel, buffer)
                    if status == _FLUSH_STOP:
                        return
                    if status == _FLUSH_OK:
                        buffer = []
                    last_flush = time.monotonic()

                tail_lines = _CONSOLE_RECONNECT_TAIL_LINES

                attempt_healthy = saw_deadline_marker or (
                    time.monotonic() - attempt_started >= _CONSOLE_STREAM_MIN_LIFETIME
                )
                if attempt_healthy:
                    consecutive_reconnect_failures = 0
                    reconnect_delay = _CONSOLE_RECONNECT_INITIAL_DELAY
                else:
                    consecutive_reconnect_failures += 1
                    if consecutive_reconnect_failures >= _CONSOLE_MAX_RECONNECT_FAILURES:
                        logger.warning(
                            "Console stream: %d falhas consecutivas de reconexão; "
                            "parando stream",
                            consecutive_reconnect_failures,
                        )
                        reason = (
                            "Falhas consecutivas de reconexão ao agente. "
                            "Use `/mc console` para reativar quando o agente voltar."
                        )
                        try:
                            await channel.send(embed=console_stream_error(reason))
                        except discord.HTTPException:
                            logger.warning(
                                "Falha ao avisar fim do console stream no canal %d", channel.id
                            )
                        await self._notify_console_stream_auto_stopped(channel, reason)
                        return

                await asyncio.sleep(reconnect_delay)
                if not attempt_healthy:
                    reconnect_delay = min(reconnect_delay * 2, _CONSOLE_RECONNECT_MAX_DELAY)
        except asyncio.CancelledError:
            logger.info("Console stream cancelado")
            raise
        finally:
            # P1: only clear state if this task is still the recorded console
            # task. If Admin A's task was cancelled and Admin B immediately
            # started a new task, task A's finally must NOT clobber task B's
            # freshly-set `_console_stream_active=True` / `_console_task`.
            if asyncio.current_task() is self.bot._console_task:
                self.bot._console_stream_active = False
                self.bot._console_task = None

    async def _notify_console_stream_auto_stopped(
        self, failed_channel: discord.TextChannel, reason: str
    ) -> None:
        """Notify the control channel that the console stream auto-stopped.

        Skips notification when the control channel is unset or is the same as
        the failed channel (the message would also fail).
        """
        controle_id = self.bot.config.controle_channel_id
        if controle_id is None or controle_id == failed_channel.id:
            return
        controle = self.bot.get_channel(controle_id)
        if controle is None or not isinstance(controle, discord.TextChannel):
            return
        try:
            await controle.send(embed=warning("Console stream parado", reason))
        except discord.HTTPException:
            logger.warning(
                "Falha ao notificar canal de controle %d sobre parada do console stream",
                controle_id,
            )


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


def _sanitize_console_text(text: str) -> str:
    """Neutralize runs of 3+ backticks so log lines can't break the code fence (EXP-61).

    Inserts a zero-width space after the first backtick (````` ``` ````` becomes
    ````` `\\u200b`` ````). A regex over runs of 3+ is required: a plain
    ``str.replace("```", ...)`` would leave a trailing triple when the run
    has 4+ backticks.
    """
    return _TRIPLE_BACKTICK_RE.sub("`\u200b``", text)


def _format_console_chunk(chunk: str) -> str:
    """Wrap a log chunk in a code fence, sanitized and hard-truncated (EXP-61).

    Sanitizing can grow the text (each triple backtick gains one char), so
    the truncation happens after sanitization — the final message is
    guaranteed to stay under Discord's 2000-char limit including the fence.
    """
    sanitized = _sanitize_console_text(chunk)
    if len(sanitized) > _CONSOLE_MAX_CONTENT:
        sanitized = sanitized[: _CONSOLE_MAX_CONTENT - 1] + "…"
    return f"```\n{sanitized}\n```"


async def _send_console_buffer(channel: discord.TextChannel, buffer: list[str]) -> str:
    """Post buffered console lines as fenced chunks (EXP-61).

    Returns ``_FLUSH_OK`` (all sent), ``_FLUSH_RETRY`` (transient Discord
    error — the caller keeps the buffer and retries on the next flush) or
    ``_FLUSH_STOP`` (channel deleted). Every send disables mentions: log
    lines are game-controlled and may contain @everyone/@here. The buffer
    is never modified here.
    """
    if not buffer:
        return _FLUSH_OK
    for chunk in _partition_lines(buffer, _CONSOLE_MAX_CONTENT):
        payload = _format_console_chunk(chunk)
        try:
            await channel.send(payload, allowed_mentions=discord.AllowedMentions.none())
        except discord.NotFound:
            logger.warning("Console stream: canal %d não existe mais", channel.id)
            return _FLUSH_STOP
        except discord.HTTPException as send_err:
            logger.warning(
                "Console stream: falha ao enviar chunk no canal %d: %s",
                channel.id,
                send_err,
            )
            return _FLUSH_RETRY
    return _FLUSH_OK


def _format_uptime(seconds: int) -> str:
    """Format uptime as 'Xs', 'Xm', 'Xh Ym' or 'Xd Yh'."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"
