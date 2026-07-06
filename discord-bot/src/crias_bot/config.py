"""Configuração do bot via variáveis de ambiente.

Lê do ambiente (Railway injeta via variáveis) ou de .env local.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

from dotenv import load_dotenv

# Carrega .env se existir (desenvolvimento local).
load_dotenv()

# Validação de formato do auth_token (BOT-040).
# 64 hex chars = 256 bits de entropia (gerado por `openssl rand -hex 32`).
_TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
_TOKEN_PLACEHOLDER = "CHANGE_ME_TO_RANDOM_64_HEX_CHARS"


@dataclass(frozen=True)
class BotConfig:
    """Configuração imutável do bot Discord."""

    # Discord (campos obrigatórios primeiro — dataclass não permite non-default após default)
    discord_token: str
    # Agente gRPC (também obrigatórios)
    agent_host: str  # https://<host>.ts.net (Tailscale Funnel) ou localhost:8473
    agent_token: str  # 64 hex chars, deve bater com /etc/crias/agent.yaml

    # Discord opcionais
    guild_id: int | None = None  # guild específico para sync imediato de slash commands

    # Permissões (IDs de roles Discord)
    admin_role_ids: frozenset[int] = field(default_factory=frozenset)
    moderator_role_ids: frozenset[int] = field(default_factory=frozenset)

    # Canais
    controle_channel_id: int | None = None  # onde postar start/stop notifications
    chat_minecraft_channel_id: int | None = None  # bridge Discord <-> Minecraft
    console_channel_id: int | None = None  # stream de logs (opcional)

    # Comportamento
    status_cache_seconds: int = 15  # cache de GetStatus (não consulta agente a cada msg)
    reconnect_max_delay: int = 60  # backoff exponencial até 60s

    # TLS (BOT-004): pinning de CA opcional para o canal gRPC
    agent_tls_ca_path: str | None = None
    agent_use_tls: bool = False


def load_config() -> BotConfig:
    """Carrega config do ambiente. Levanta ValueError se obrigatórios faltarem."""
    token = os.environ.get("DISCORD_TOKEN", "")
    if not token:
        raise ValueError("DISCORD_TOKEN não definido no ambiente")

    agent_host = os.environ.get("CRIAS_AGENT_HOST", "")
    if not agent_host:
        raise ValueError("CRIAS_AGENT_HOST não definido (ex.: https://seu-host.ts.net)")

    agent_token = os.environ.get("CRIAS_AGENT_TOKEN", "")
    if not agent_token:
        raise ValueError("CRIAS_AGENT_TOKEN não definido (64 hex chars)")
    # BOT-040: valida formato e rejeita placeholder
    if agent_token == _TOKEN_PLACEHOLDER:
        raise ValueError(
            "CRIAS_AGENT_TOKEN ainda é o placeholder — "
            "gere com: openssl rand -hex 32"
        )
    if not _TOKEN_RE.match(agent_token):
        raise ValueError(
            "CRIAS_AGENT_TOKEN deve ter 64 caracteres hex "
            "(gerado por openssl rand -hex 32)"
        )

    guild_id_raw = os.environ.get("DISCORD_GUILD_ID", "").strip()
    guild_id = int(guild_id_raw) if guild_id_raw else None

    admin_ids = _parse_id_list(os.environ.get("DISCORD_ADMIN_ROLE_IDS", ""))
    mod_ids = _parse_id_list(os.environ.get("DISCORD_MODERATOR_ROLE_IDS", ""))

    controle_id = _parse_optional_int(os.environ.get("DISCORD_CONTROLE_CHANNEL_ID", ""))
    chat_mc_id = _parse_optional_int(os.environ.get("DISCORD_CHAT_MC_CHANNEL_ID", ""))
    console_id = _parse_optional_int(os.environ.get("DISCORD_CONSOLE_CHANNEL_ID", ""))

    cache_secs = _parse_int_env("STATUS_CACHE_SECONDS", 15)
    reconnect_max = _parse_int_env("RECONNECT_MAX_DELAY", 60)

    # TLS (BOT-004)
    tls_ca_path = os.environ.get("CRIAS_AGENT_TLS_CA_PATH", "").strip() or None
    use_tls = os.environ.get("CRIAS_AGENT_USE_TLS", "false").strip().lower() == "true"

    return BotConfig(
        discord_token=token,
        guild_id=guild_id,
        admin_role_ids=admin_ids,
        moderator_role_ids=mod_ids,
        controle_channel_id=controle_id,
        chat_minecraft_channel_id=chat_mc_id,
        console_channel_id=console_id,
        agent_host=agent_host,
        agent_token=agent_token,
        status_cache_seconds=cache_secs,
        reconnect_max_delay=reconnect_max,
        agent_tls_ca_path=tls_ca_path,
        agent_use_tls=use_tls,
    )


def _parse_id_list(raw: str) -> frozenset[int]:
    """Parseia lista de IDs separados por vírgula: '123,456,789' → frozenset."""
    if not raw.strip():
        return frozenset()
    ids = set()
    for part in raw.split(","):
        part = part.strip()
        if part:
            try:
                ids.add(int(part))
            except ValueError:
                continue
    return frozenset(ids)


def _parse_optional_int(raw: str) -> int | None:
    raw = raw.strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _parse_int_env(name: str, default: int) -> int:
    """Lê variável de ambiente inteira com default e tratamento de erro."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        raise ValueError(f"{name} deve ser um inteiro, obtido: {raw!r}") from None
