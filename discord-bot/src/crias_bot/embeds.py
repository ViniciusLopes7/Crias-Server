"""Centralized Discord embed factory.

Standardizes visual identity (colors, thumbnail, timestamp, footer) and
provides per-semantic and per-command builders.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

import discord

if TYPE_CHECKING:
    pass


# P4: matches runs of 3+ consecutive backticks. Sanitizing these in user
# content prevents premature codeblock-fence termination (a triple-backtick
# in the middle of `````\n{detail}\n````` would close the fence early and the
# rest of the content would be parsed as Markdown).
_BACKTICK_RUN_RE = re.compile(r"`{3,}")


# ---------------------------------------------------------------------------
# Color palette (discord.Color accepts 24-bit RGB int).
# ---------------------------------------------------------------------------


class Colors:
    """Canonical bot colors, centralized to avoid divergence across handlers."""

    SUCCESS = 0x57F287  # verde discord.py "blurple green"
    ERROR = 0xED4245  # vermelho discord.py "red"
    WARNING = 0xFEE75C  # amarelo discord.py "yellow"
    INFO = 0x5865F2  # blurple (azul-roxo discord)
    EVENT = 0x9B59B6  # roxo para eventos push (player join/leave, etc.)
    NEUTRAL = 0x95A5A6  # cinza para status offline / info neutra
    ONLINE = 0x2ECC71  # verde mais escuro para "online"
    OFFLINE = 0xE74C3C  # vermelho mais escuro para "offline"


# ---------------------------------------------------------------------------
# Visual identity constants.
# ---------------------------------------------------------------------------

BOT_NAME = "Crias-Server"
BOT_VERSION = "1.1.0"
FOOTER_TEXT = f"Crias-Server v{BOT_VERSION} • Reino dos Crias"
# Crias shield thumbnail (public repo asset).
THUMBNAIL_URL = (
    "https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/"
    "assets/images/branding/EscudoCrias.png"
)


# ---------------------------------------------------------------------------
# Base builders.
# ---------------------------------------------------------------------------


def _base_embed(
    title: str,
    *,
    color: int = Colors.INFO,
    description: str | None = None,
    emoji: str = "",
) -> discord.Embed:
    """Create embed with timestamp, footer, and thumbnail preconfigured."""
    full_title = f"{emoji} {title}" if emoji else title
    embed = discord.Embed(
        title=full_title,
        description=description,
        color=color,
        timestamp=datetime.now(UTC),
    )
    embed.set_footer(text=FOOTER_TEXT)
    embed.set_thumbnail(url=THUMBNAIL_URL)
    return embed


# ---------------------------------------------------------------------------
# Semantic helpers (success / error / warning / info).
# ---------------------------------------------------------------------------


def success(title: str, description: str | None = None) -> discord.Embed:
    """Green embed for successful operations."""
    return _base_embed(title, color=Colors.SUCCESS, description=description, emoji="✅")


def error(title: str, description: str | None = None) -> discord.Embed:
    """Red embed for errors and failures."""
    return _base_embed(title, color=Colors.ERROR, description=description, emoji="❌")


def warning(title: str, description: str | None = None) -> discord.Embed:
    """Yellow embed for non-fatal warnings."""
    return _base_embed(title, color=Colors.WARNING, description=description, emoji="⚠️")


def info(title: str, description: str | None = None) -> discord.Embed:
    """Blue embed for neutral information."""
    return _base_embed(title, color=Colors.INFO, description=description, emoji="ℹ️")


def permission_denied(required: str = "admin") -> discord.Embed:
    """Standard permission-denied embed used across commands."""
    return error(
        "Permissão negada",
        f"Você precisa ser **{required}** para usar este comando.",
    )


def agent_error(detail: str) -> discord.Embed:
    """Standard embed for gRPC agent communication errors."""
    return error(
        "Falha de comunicação com o agente",
        f"Não foi possível falar com o `crias-agent`.\n```\n{truncate_for_codeblock(detail)}\n```",
    )


# ---------------------------------------------------------------------------
# Command-specific embeds.
# ---------------------------------------------------------------------------


def command_result(
    ok: bool,
    *,
    action: str,
    message: str,
    service: str = "",
) -> discord.Embed:
    """Embed for /mc start|stop|restart results (success or failure)."""
    if ok:
        embed = success(
            f"Servidor {action}",
            description=message,
        )
    else:
        embed = error(
            f"Falha ao {action} servidor",
            description=message,
        )
    if service:
        embed.add_field(name="Serviço", value=f"`{service}`", inline=True)
    return embed


def status_online(status: dict[str, Any]) -> discord.Embed:
    """Detailed embed for /mc status when server is online."""
    service = status.get("service_name", "?")
    stack = status.get("stack", "?")
    tier = status.get("hardware_tier") or "—"
    uptime = _format_uptime(int(status.get("uptime_seconds", 0) or 0))
    players = status.get("players") or []
    player_count = int(status.get("player_count", 0) or 0)
    max_players = int(status.get("max_players", 0) or 0)
    mem_used = int(status.get("memory_used_mb", 0) or 0)
    mem_max = int(status.get("memory_max_mb", 0) or 0)
    version = status.get("version") or "—"

    embed = _base_embed(
        f"Status — {service}",
        color=Colors.ONLINE,
        description="🟢 **Online**",
        emoji="📊",
    )

    # Row 1: server identity (3 inline fields).
    embed.add_field(name="Stack", value=f"`{stack}`", inline=True)
    embed.add_field(name="Tier", value=f"`{tier}`", inline=True)
    embed.add_field(name="Uptime", value=f"`{uptime}`", inline=True)

    # Row 2: players (highlighted).
    players_str = ", ".join(f"`{p}`" for p in players) if players else "_ninguém online_"
    embed.add_field(
        name=f"👥 Players ({player_count}/{max_players if max_players else '?'})",
        value=players_str,
        inline=False,
    )

    # Row 3: resources.
    mem_str = f"`{mem_used} / {mem_max} MB`" if mem_max else f"`{mem_used} MB`"
    embed.add_field(name="Memória", value=mem_str, inline=True)
    embed.add_field(name="Agente", value=f"`v{version}`", inline=True)
    embed.add_field(name="\u200b", value="\u200b", inline=True)  # spacer

    return embed


def status_offline(service: str) -> discord.Embed:
    """Embed for /mc status when server is offline."""
    return _base_embed(
        f"Status — {service}",
        color=Colors.OFFLINE,
        description="🔴 **Offline**",
        emoji="📊",
    )


def players_list(status: dict[str, Any]) -> discord.Embed:
    """Embed for /mc players."""
    players = status.get("players") or []
    count = int(status.get("player_count", 0) or 0)
    max_p = int(status.get("max_players", 0) or 0)

    if not players:
        return info(
            "Nenhum player online",
            "O servidor está vazio no momento.",
        )

    # Numbered list for readability with many players.
    lines = [f"**{i}.** `{p}`" for i, p in enumerate(players, start=1)]
    capacity = f" ({count}/{max_p})" if max_p else f" ({count})"
    return _base_embed(
        f"Players online{capacity}",
        color=Colors.INFO,
        description="\n".join(lines),
        emoji="👥",
    )


def health_report(h: dict[str, Any]) -> discord.Embed:
    """Embed for /mc health showing healthy, RCON, port, and message."""
    healthy = bool(h.get("healthy"))
    rcon_ok = bool(h.get("rcon_responsive"))
    port = h.get("port", "—")
    service = h.get("service", "?")
    message = h.get("message", "")

    color = Colors.SUCCESS if healthy else Colors.WARNING
    embed = _base_embed(
        f"Health — {service}",
        color=color,
        emoji="🏥",
    )

    # Main status highlighted.
    status_emoji = "✅ Saudável" if healthy else "⚠️ com problemas"
    embed.add_field(name="Estado", value=status_emoji, inline=True)

    # Individual indicators.
    rcon_str = "✅ respondendo" if rcon_ok else "❌ sem resposta"
    embed.add_field(name="RCON", value=rcon_str, inline=True)
    embed.add_field(name="Porta", value=f"`{port}`", inline=True)

    if message:
        # P9: Discord caps embed field values at 1024 chars; route through
        # ``truncate_for_codeblock`` so an unusually long agent message
        # doesn't trigger a 400 from Discord. The backtick-sanitization in
        # ``truncate_for_codeblock`` is a benign side-effect here.
        embed.add_field(
            name="Mensagem",
            value=truncate_for_codeblock(message, max_len=1024),
            inline=False,
        )

    return embed


def say_confirmation(message: str) -> discord.Embed:
    """Confirmation embed for /mc say."""
    return success(
        "Mensagem enviada no chat",
        f"Mensagem entregue via RCON:\n```\n{message}\n```",
    )


def console_stream_started(channel_mention: str) -> discord.Embed:
    """Embed when /mc console enables the stream."""
    return success(
        "Stream de console ativado",
        f"Postando logs em tempo real em {channel_mention}.\n"
        "Use `/mc console` novamente para parar.",
    )


def console_stream_stopped() -> discord.Embed:
    """Embed when /mc console disables the stream."""
    return info(
        "Stream de console desativado",
        "Não vou postar mais logs em tempo real.",
    )


def console_stream_error(detail: str) -> discord.Embed:
    """Embed when console stream fails."""
    return error(
        "Stream de console parou",
        f"Erro durante o stream:\n```\n{truncate_for_codeblock(detail)}\n```",
    )


# ---------------------------------------------------------------------------
# Push event embeds (event_bridge -> #controle).
# ---------------------------------------------------------------------------


def event_embed(ev: dict[str, Any]) -> discord.Embed | None:
    """Convert agent event to structured embed; return None if unknown."""
    event_type = ev.get("event_type", "")
    metadata = ev.get("metadata", {}) or {}
    service = ev.get("service", "")
    stack = ev.get("stack", "")

    if event_type == "ServerStarted":
        return _base_embed(
            "Servidor iniciado",
            color=Colors.ONLINE,
            description=f"🟢 **{service}** está online agora.",
            emoji="🟢",
        )
    if event_type == "ServerStopped":
        return _base_embed(
            "Servidor parado",
            color=Colors.OFFLINE,
            description=f"🔴 **{service}** foi desligado.",
            emoji="🔴",
        )
    if event_type == "PlayerJoined":
        player = metadata.get("player", "?")
        embed = _base_embed(
            "Player entrou",
            color=Colors.EVENT,
            description=f"➡️ **{player}** entrou no servidor.",
            emoji="➡️",
        )
        if service:
            embed.add_field(name="Servidor", value=f"`{service}`", inline=True)
        return embed
    if event_type == "PlayerLeft":
        player = metadata.get("player", "?")
        embed = _base_embed(
            "Player saiu",
            color=Colors.EVENT,
            description=f"⬅️ **{player}** saiu do servidor.",
            emoji="⬅️",
        )
        if service:
            embed.add_field(name="Servidor", value=f"`{service}`", inline=True)
        return embed
    if event_type == "HealthWarning":
        reason = metadata.get("reason", "unknown")
        embed = warning(
            "Aviso de saúde",
            f"O agente reportou um problema de saúde:\n`{reason}`",
        )
        if service:
            embed.add_field(name="Servidor", value=f"`{service}`", inline=True)
        if stack:
            embed.add_field(name="Stack", value=f"`{stack}`", inline=True)
        return embed

    # Unknown event: return None for caller to handle.
    return None


# ---------------------------------------------------------------------------
# Formatting helpers.
# ---------------------------------------------------------------------------


def _format_uptime(seconds: int) -> str:
    """Format uptime as 'Xs', 'Xm', 'Xh Ym' or 'Xd Yh'.

    Duplicated from bot.py to avoid circular import; keep in sync.
    """
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"


def truncate_for_codeblock(text: str, max_len: int = 1800) -> str:
    """Truncate text so it fits inside a fenced code block.

    Discord caps message length at 2000 chars. Code block fences and
    surrounding framing consume the remaining ~200 chars. Append a
    truncation marker when content is shortened.

    P4: also sanitize runs of 3+ backticks (````` `````) to a single
    backtick so user content can't prematurely close the fenced code block.
    All callers of this helper benefit, including ``agent_error`` and
    ``console_stream_error``.
    """
    # Sanitize first so the substitution doesn't push us over max_len.
    text = _BACKTICK_RUN_RE.sub("`", text)
    if len(text) <= max_len:
        return text
    marker = "…(truncado)"
    return text[: max_len - len(marker)] + marker
