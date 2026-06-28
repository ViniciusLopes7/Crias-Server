"""Bot Discord principal: slash commands + bridge de eventos.

Comandos:
  /mc start       Admin   Liga o servidor
  /mc stop        Admin   Desliga graceful
  /mc restart     Admin   Reinicia
  /mc status      Todos   Online/offline, players, RAM, tier
  /mc players     Todos   Lista quem está online
  /mc say <msg>   Mod+    Manda mensagem no chat do jogo via RCON
  /mc logs [n]    Admin   Últimas N linhas do journalctl (via StreamConsole tail)
  /mc console     Admin   Ativa/desativa stream de console no canal #console
  /mc health      Admin   Health check passivo
"""
from __future__ import annotations

import asyncio
import logging
import time

import discord
from discord import app_commands
from discord.ext import commands, tasks

from .agent_client import AgentClient, AgentClientError
from .config import BotConfig

logger = logging.getLogger(__name__)


class CriasBot(commands.Bot):
    """Bot Discord para o Crias-Server."""

    def __init__(self, config: BotConfig, agent: AgentClient) -> None:
        intents = discord.Intents.default()
        intents.message_content = False  # não precisamos ler mensagens (só slash)
        intents.members = False

        super().__init__(
            command_prefix=commands.when_mentioned_or("!"),
            intents=intents,
        )

        self.config = config
        self.agent = agent
        self._console_stream_active = False
        self._console_task: asyncio.Task | None = None

    async def setup_hook(self) -> None:
        """Sincroniza slash commands no guild específico (se definido)."""
        await self.add_cog(MinecraftCog(self))

        if self.config.guild_id:
            guild = discord.Object(id=self.config.guild_id)
            self.tree.copy_global_to(guild=guild)
            synced = await self.tree.sync(guild=guild)
            logger.info("Sincronizados %d slash commands no guild %d", len(synced), guild.id)
        else:
            synced = await self.tree.sync()
            logger.info("Sincronizados %d slash commands globalmente", len(synced))

        # Inicia background task de eventos.
        self.event_bridge.start()

    async def close(self) -> None:
        """Graceful shutdown: cancela tasks e fecha canal gRPC."""
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
        """Subscreve a eventos do agente e posta no Discord.

        Reconecta automaticamente em caso de erro.
        """
        try:
            async for ev in self.agent.subscribe_events():
                await self._dispatch_event(ev)
        except AgentClientError as e:
            logger.warning("EventBridge falhou (vai tentar de novo em 5s): %s", e)
        except (TimeoutError, OSError, ConnectionError) as e:
            logger.warning("EventBridge: erro de rede: %s", e)
        except Exception:
            # Catch-all para bugs inesperados; loga traceback para diagnóstico.
            logger.exception("Erro inesperado no EventBridge")

    @event_bridge.before_loop
    async def _before_event_bridge(self) -> None:
        await self.wait_until_ready()

    async def _dispatch_event(self, ev: dict) -> None:
        """Mapeia evento do agente para mensagem Discord no canal #controle."""
        if self.config.controle_channel_id is None:
            return

        channel = self.get_channel(self.config.controle_channel_id)
        if channel is None or not isinstance(channel, discord.TextChannel):
            return

        event_type = ev.get("event_type", "")
        metadata = ev.get("metadata", {})

        # Mapeamento simples de evento → emoji + mensagem.
        messages = {
            "ServerStarted": ("🟢", f"**Servidor iniciado** ({ev.get('service', '')})"),
            "ServerStopped": ("🔴", f"**Servidor parado** ({ev.get('service', '')})"),
            "PlayerJoined": ("➡️", f"**{metadata.get('player', '?')}** entrou no servidor"),
            "PlayerLeft": ("⬅️", f"**{metadata.get('player', '?')}** saiu do servidor"),
            "HealthWarning": ("⚠️", f"**Aviso de saúde**: {metadata.get('reason', 'unknown')}"),
        }

        emoji, msg = messages.get(event_type, ("ℹ️", f"Evento {event_type}: {metadata}"))
        try:
            await channel.send(f"{emoji} {msg}")
        except discord.HTTPException:
            logger.warning("Falha ao postar evento %s no canal %d", event_type, channel.id)


class MinecraftCog(commands.Cog):
    """Cog com slash commands /mc."""

    group = app_commands.Group(name="mc", description="Comandos do Minecraft")

    def __init__(self, bot: CriasBot) -> None:
        self.bot = bot

    @group.command(name="start", description="Liga o servidor")
    async def start(self, interaction: discord.Interaction) -> None:
        if not self.bot.is_admin(interaction.user):
            await interaction.response.send_message("❌ Sem permissão (admin necessário).", ephemeral=True)
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.start_server()
            if result["ok"]:
                await interaction.followup.send(f"✅ {result['message']}")
            else:
                await interaction.followup.send(f"❌ {result['message']}")
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro: {e}")

    @group.command(name="stop", description="Desliga o servidor")
    async def stop(self, interaction: discord.Interaction) -> None:
        if not self.bot.is_admin(interaction.user):
            await interaction.response.send_message("❌ Sem permissão (admin necessário).", ephemeral=True)
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.stop_server()
            if result["ok"]:
                await interaction.followup.send(f"✅ {result['message']}")
            else:
                await interaction.followup.send(f"❌ {result['message']}")
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro: {e}")

    @group.command(name="restart", description="Reinicia o servidor")
    async def restart(self, interaction: discord.Interaction) -> None:
        if not self.bot.is_admin(interaction.user):
            await interaction.response.send_message("❌ Sem permissão (admin necessário).", ephemeral=True)
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.restart_server()
            if result["ok"]:
                await interaction.followup.send(f"✅ {result['message']}")
            else:
                await interaction.followup.send(f"❌ {result['message']}")
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro: {e}")

    @group.command(name="status", description="Mostra status do servidor")
    async def status(self, interaction: discord.Interaction) -> None:
        await interaction.response.defer(thinking=True)
        try:
            s = await self.bot.agent.get_status()
            if not s["service_active"]:
                embed = discord.Embed(
                    title=f"📊 Status — {s['service_name']}",
                    description="🔴 **Offline**",
                    color=discord.Color.red(),
                )
            else:
                uptime = _format_uptime(s["uptime_seconds"])
                players_list = ", ".join(s["players"]) if s["players"] else "_ninguém_"
                embed = discord.Embed(
                    title=f"📊 Status — {s['service_name']}",
                    description="🟢 **Online**",
                    color=discord.Color.green(),
                )
                embed.add_field(name="Stack", value=s["stack"], inline=True)
                embed.add_field(name="Tier", value=s.get("hardware_tier", "?"), inline=True)
                embed.add_field(name="Uptime", value=uptime, inline=True)
                embed.add_field(
                    name=f"Players ({s['player_count']})",
                    value=players_list,
                    inline=False,
                )
                embed.add_field(
                    name="Memória",
                    value=f"{s['memory_used_mb']} / {s['memory_max_mb']} MB",
                    inline=True,
                )
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro ao consultar status: {e}")

    @group.command(name="players", description="Lista players online")
    async def players(self, interaction: discord.Interaction) -> None:
        await interaction.response.defer(thinking=True)
        try:
            s = await self.bot.agent.get_status()
            if not s["players"]:
                await interaction.followup.send("📭 Nenhum player online.")
            else:
                lines = [f"• **{p}**" for p in s["players"]]
                embed = discord.Embed(
                    title=f"👥 Players online ({s['player_count']})",
                    description="\n".join(lines),
                    color=discord.Color.blue(),
                )
                await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro: {e}")

    @group.command(name="say", description="Manda mensagem no chat do jogo via RCON")
    @app_commands.describe(message="Mensagem a ser enviada")
    async def say(self, interaction: discord.Interaction, message: str) -> None:
        if not self.bot.is_moderator(interaction.user):
            await interaction.response.send_message("❌ Sem permissão (moderador+ necessário).", ephemeral=True)
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            result = await self.bot.agent.send_rcon_command(f"say {message}")
            if result["ok"]:
                await interaction.followup.send(f"✅ Mensagem enviada: `{message}`")
            else:
                await interaction.followup.send(f"❌ {result.get('error', 'erro desconhecido')}")
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro: {e}")

    @group.command(name="health", description="Verifica saúde do servidor")
    async def health(self, interaction: discord.Interaction) -> None:
        if not self.bot.is_admin(interaction.user):
            await interaction.response.send_message("❌ Sem permissão (admin necessário).", ephemeral=True)
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        try:
            h = await self.bot.agent.get_health()
            color = discord.Color.green() if h["healthy"] else discord.Color.orange()
            embed = discord.Embed(
                title=f"🏥 Health — {h['service']}",
                color=color,
            )
            embed.add_field(name="Healthy", value="✅" if h["healthy"] else "⚠️", inline=True)
            embed.add_field(name="RCON", value="✅" if h["rcon_responsive"] else "❌", inline=True)
            embed.add_field(name="Porta", value=str(h.get("port", "?")), inline=True)
            embed.add_field(name="Mensagem", value=h.get("message", ""), inline=False)
            await interaction.followup.send(embed=embed)
        except AgentClientError as e:
            await interaction.followup.send(f"❌ Erro: {e}")

    @group.command(name="console", description="Ativa/desativa stream de console no canal #console")
    async def console(self, interaction: discord.Interaction) -> None:
        if not self.bot.is_admin(interaction.user):
            await interaction.response.send_message("❌ Sem permissão (admin necessário).", ephemeral=True)
            return

        if self.bot._console_stream_active:
            # Desativar.
            self.bot._console_stream_active = False
            if self.bot._console_task is not None:
                self.bot._console_task.cancel()
                self.bot._console_task = None
            await interaction.response.send_message("🔇 Stream de console desativado.")
        else:
            # Ativar.
            channel_id = self.bot.config.console_channel_id
            if channel_id is None:
                await interaction.response.send_message(
                    "❌ Canal #console não configurado. Defina `DISCORD_CONSOLE_CHANNEL_ID`.",
                    ephemeral=True,
                )
                return

            channel = self.bot.get_channel(channel_id)
            if channel is None or not isinstance(channel, discord.TextChannel):
                await interaction.response.send_message(
                    f"❌ Canal {channel_id} não encontrado ou não é texto.",
                    ephemeral=True,
                )
                return

            self.bot._console_stream_active = True
            self.bot._console_task = asyncio.create_task(self._console_stream_loop(channel))
            await interaction.response.send_message(
                f"📡 Stream de console ativado em {channel.mention}. Use `/mc console` novamente para parar."
            )

    async def _console_stream_loop(self, channel: discord.TextChannel) -> None:
        """Loop que consome StreamConsole e posta no canal #console em blocos.

        Buffer de 2s + limite de ~1800 chars por mensagem (Discord limita 2000).
        """
        buffer: list[str] = []
        last_flush = time.monotonic()
        MAX_CHARS = 1800  # margem para ``` + newlines

        try:
            async for line in self.bot.agent.stream_console(tail_lines=50):
                buffer.append(line)

                # Flush a cada 2s ou se buffer acumular texto suficiente.
                now = time.monotonic()
                total_chars = sum(len(s) for s in buffer)
                if total_chars >= MAX_CHARS or (now - last_flush) >= 2.0:
                    if buffer:
                        # Particiona em chunks que cabem em 1800 chars.
                        chunks = _partition_lines(buffer, MAX_CHARS)
                        for chunk in chunks:
                            try:
                                await channel.send(f"```\n{chunk}\n```")
                            except discord.HTTPException:
                                pass  # rate limited ou msg muito longa
                        buffer = []
                        last_flush = now
        except AgentClientError as e:
            logger.warning("Console stream falhou: %s", e)
            try:
                await channel.send(f"❌ Stream de console parou: {e}")
            except discord.HTTPException:
                pass
        except asyncio.CancelledError:
            logger.info("Console stream cancelado")
            raise
        finally:
            self.bot._console_stream_active = False


def _partition_lines(lines: list[str], max_chars: int) -> list[str]:
    """Particiona lista de linhas em chunks que cabem em max_chars."""
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
    """Formata uptime em 'Xh Ym' ou 'Xd Yh'."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"
