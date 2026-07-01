"""Fábrica centralizada de embeds do bot Discord.

Esta camada padroniza a identidade visual de TODAS as respostas do bot:

- Paleta de cores consistente (verde=success, vermelho=error, laranja=warning,
  azul=info, roxo=eventos, cinza=neutro).
- Thumbnail do escudo Crias em todos os embeds (branding).
- Timestamp UTC atual em cada embed (discord exibe em fuso do cliente).
- Footer com versão do bot e "Reino dos Crias".
- Título com emoji contextual.
- Helpers para success/error/warning/info/event para evitar boilerplate nos
  handlers de slash command.

Quem precisa de um embed específico (status, players, health) chama o helper
apropriado e depois adiciona campos com `add_field()` normalmente.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

import discord

if TYPE_CHECKING:
    pass


# ---------------------------------------------------------------------------
# Paleta de cores (discord.Color aceita int 24-bit RGB).
# ---------------------------------------------------------------------------


class Colors:
    """Cores canônicas do bot. Centralizadas para não dispersar por handlers."""

    SUCCESS = 0x57F287  # verde discord.py "blurple green"
    ERROR = 0xED4245  # vermelho discord.py "red"
    WARNING = 0xFEE75C  # amarelo discord.py "yellow"
    INFO = 0x5865F2  # blurple (azul-roxo discord)
    EVENT = 0x9B59B6  # roxo para eventos push (player join/leave, etc.)
    NEUTRAL = 0x95A5A6  # cinza para status offline / info neutra
    ONLINE = 0x2ECC71  # verde mais escuro para "online"
    OFFLINE = 0xE74C3C  # vermelho mais escuro para "offline"


# ---------------------------------------------------------------------------
# Identidade visual (constantes).
# ---------------------------------------------------------------------------

BOT_NAME = "Crias-Server"
BOT_VERSION = "1.1.0"
FOOTER_TEXT = f"Crias-Server v{BOT_VERSION} • Reino dos Crias"
# Thumbnail do escudo Crias (asset público do repo).
THUMBNAIL_URL = (
    "https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/"
    "assets/images/branding/EscudoCrias.png"
)


# ---------------------------------------------------------------------------
# Builders base.
# ---------------------------------------------------------------------------


def _base_embed(
    title: str,
    *,
    color: int = Colors.INFO,
    description: str | None = None,
    emoji: str = "",
) -> discord.Embed:
    """Cria embed com timestamp + footer + thumbnail já configurados.

    Args:
        title: título do embed. Se `emoji` for passado, é prefixado.
        color: cor da barra lateral (use Colors.*).
        description: texto principal (suporta markdown do Discord).
        emoji: emoji opcional para prefixar no título.
    """
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
# Helpers de semântica (success / error / warning / info).
# ---------------------------------------------------------------------------


def success(title: str, description: str | None = None) -> discord.Embed:
    """Embed verde para operações concluídas com sucesso."""
    return _base_embed(title, color=Colors.SUCCESS, description=description, emoji="✅")


def error(title: str, description: str | None = None) -> discord.Embed:
    """Embed vermelho para erros e falhas."""
    return _base_embed(title, color=Colors.ERROR, description=description, emoji="❌")


def warning(title: str, description: str | None = None) -> discord.Embed:
    """Embed amarelo para avisos não-fatais."""
    return _base_embed(title, color=Colors.WARNING, description=description, emoji="⚠️")


def info(title: str, description: str | None = None) -> discord.Embed:
    """Embed azul para informações neutras."""
    return _base_embed(title, color=Colors.INFO, description=description, emoji="ℹ️")


def permission_denied(required: str = "admin") -> discord.Embed:
    """Embed padronizado para falta de permissão (usado em todos os comandos)."""
    return error(
        "Permissão negada",
        f"Você precisa ser **{required}** para usar este comando.",
    )


def agent_error(detail: str) -> discord.Embed:
    """Embed padronizado para erros de comunicação com o agente gRPC."""
    return error(
        "Falha de comunicação com o agente",
        f"Não foi possível falar com o `crias-agent`.\n```\n{detail}\n```",
    )


# ---------------------------------------------------------------------------
# Embeds específicos de comandos.
# ---------------------------------------------------------------------------


def command_result(
    ok: bool,
    *,
    action: str,
    message: str,
    service: str = "",
) -> discord.Embed:
    """Embed para respostas de /mc start|stop|restart (sucesso ou falha).

    Args:
        ok: True se operação teve sucesso.
        action: verbo da ação ("iniciado", "parado", "reiniciado").
        message: mensagem retornada pelo agente.
        service: nome do serviço systemd (ex.: "minecraft").
    """
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
    """Embed detalhado para /mc status quando servidor está online."""
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

    # Linha 1: identidade do servidor (3 campos inline).
    embed.add_field(name="Stack", value=f"`{stack}`", inline=True)
    embed.add_field(name="Tier", value=f"`{tier}`", inline=True)
    embed.add_field(name="Uptime", value=f"`{uptime}`", inline=True)

    # Linha 2: players — destaque porque é o que mais interessa.
    players_str = ", ".join(f"`{p}`" for p in players) if players else "_ninguém online_"
    embed.add_field(
        name=f"👥 Players ({player_count}/{max_players if max_players else '?'})",
        value=players_str,
        inline=False,
    )

    # Linha 3: recursos.
    mem_str = f"`{mem_used} / {mem_max} MB`" if mem_max else f"`{mem_used} MB`"
    embed.add_field(name="Memória", value=mem_str, inline=True)
    embed.add_field(name="Agente", value=f"`v{version}`", inline=True)
    embed.add_field(name="\u200b", value="\u200b", inline=True)  # spacer

    return embed


def status_offline(service: str) -> discord.Embed:
    """Embed para /mc status quando servidor está offline."""
    return _base_embed(
        f"Status — {service}",
        color=Colors.OFFLINE,
        description="🔴 **Offline**",
        emoji="📊",
    )


def players_list(status: dict[str, Any]) -> discord.Embed:
    """Embed para /mc players."""
    players = status.get("players") or []
    count = int(status.get("player_count", 0) or 0)
    max_p = int(status.get("max_players", 0) or 0)

    if not players:
        return info(
            "Nenhum player online",
            "O servidor está vazio no momento.",
        )

    # Lista numerada para facilitar leitura quando há muitos players.
    lines = [f"**{i}.** `{p}`" for i, p in enumerate(players, start=1)]
    capacity = f" ({count}/{max_p})" if max_p else f" ({count})"
    return _base_embed(
        f"Players online{capacity}",
        color=Colors.INFO,
        description="\n".join(lines),
        emoji="👥",
    )


def health_report(h: dict[str, Any]) -> discord.Embed:
    """Embed para /mc health.

    Mostra: healthy, RCON, porta e mensagem. Cores variam com estado.
    """
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

    # Status principal em destaque.
    status_emoji = "✅ Saudável" if healthy else "⚠️ com problemas"
    embed.add_field(name="Estado", value=status_emoji, inline=True)

    # Indicadores individuais.
    rcon_str = "✅ respondendo" if rcon_ok else "❌ sem resposta"
    embed.add_field(name="RCON", value=rcon_str, inline=True)
    embed.add_field(name="Porta", value=f"`{port}`", inline=True)

    if message:
        embed.add_field(name="Mensagem", value=message, inline=False)

    return embed


def say_confirmation(message: str) -> discord.Embed:
    """Embed de confirmação para /mc say."""
    return success(
        "Mensagem enviada no chat",
        f"Mensagem entregue via RCON:\n```\n{message}\n```",
    )


def console_stream_started(channel_mention: str) -> discord.Embed:
    """Embed quando /mc console ativa o stream."""
    return success(
        "Stream de console ativado",
        f"Postando logs em tempo real em {channel_mention}.\n"
        "Use `/mc console` novamente para parar.",
    )


def console_stream_stopped() -> discord.Embed:
    """Embed quando /mc console desativa o stream."""
    return info(
        "Stream de console desativado",
        "Não vou postar mais logs em tempo real.",
    )


def console_stream_error(detail: str) -> discord.Embed:
    """Embed quando o stream de console cai."""
    return error(
        "Stream de console parou",
        f"Erro durante o stream:\n```\n{detail}\n```",
    )


# ---------------------------------------------------------------------------
# Embeds para eventos push (event_bridge → #controle).
# ---------------------------------------------------------------------------


def event_embed(ev: dict[str, Any]) -> discord.Embed | None:
    """Converte evento do agente em embed estruturado.

    Retorna None se o evento não for reconhecido (caller decide o que fazer).
    """
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

    # Evento desconhecido — retorna None para caller decidir.
    return None


# ---------------------------------------------------------------------------
# Helpers de formatação.
# ---------------------------------------------------------------------------


def _format_uptime(seconds: int) -> str:
    """Formata uptime em 'Xs', 'Xm', 'Xh Ym' ou 'Xd Yh'.

    Duplicada do bot.py para manter o módulo embeds auto-contido (evita import
    circular). Manter em sincronia com bot._format_uptime.
    """
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"
