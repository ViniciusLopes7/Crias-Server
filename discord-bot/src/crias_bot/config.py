"""Bot configuration via environment variables.

Loads from env (Railway) or local .env file.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

from dotenv import load_dotenv

# Load .env if present (local dev).
load_dotenv()

# auth_token format: 64 hex chars (256 bits, from openssl rand -hex 32).
_TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
_TOKEN_PLACEHOLDER = "CHANGE_ME_TO_RANDOM_64_HEX_CHARS"


@dataclass(frozen=True)
class BotConfig:
    """Immutable bot configuration."""

    # Required fields first (dataclass constraint).
    discord_token: str
    # Required gRPC agent fields.
    agent_host: str  # e.g. https://<host>.ts.net or localhost:8473
    agent_token: str  # 64 hex chars; must match /etc/crias/agent.yaml

    # Optional Discord fields.
    guild_id: int | None = None  # specific guild for immediate slash command sync

    # Permission role IDs.
    admin_role_ids: frozenset[int] = field(default_factory=frozenset)
    moderator_role_ids: frozenset[int] = field(default_factory=frozenset)

    # Channel IDs.
    controle_channel_id: int | None = None  # for start/stop notifications
    chat_minecraft_channel_id: int | None = None  # Discord <-> Minecraft bridge
    console_channel_id: int | None = None  # optional log stream

    # Behavior tuning.
    status_cache_seconds: int = 15  # GetStatus cache TTL
    reconnect_max_delay: int = 60  # max exponential backoff

    # Optional CA pinning for gRPC channel.
    agent_tls_ca_path: str | None = None
    agent_use_tls: bool = False


def load_config() -> BotConfig:
    """Load config from env; raise ValueError if required vars are missing."""
    token = os.environ.get("DISCORD_TOKEN", "")
    if not token:
        raise ValueError("DISCORD_TOKEN não definido no ambiente")

    agent_host = os.environ.get("CRIAS_AGENT_HOST", "")
    if not agent_host:
        raise ValueError("CRIAS_AGENT_HOST não definido (ex.: https://seu-host.ts.net)")

    agent_token = os.environ.get("CRIAS_AGENT_TOKEN", "")
    if not agent_token:
        raise ValueError("CRIAS_AGENT_TOKEN não definido (64 hex chars)")
    # validate format and reject placeholder
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

    # TLS
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
    """Parse comma-separated IDs ('123,456,789') into a frozenset."""
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
    """Read int env var with default; raise ValueError if invalid."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        raise ValueError(f"{name} deve ser um inteiro, obtido: {raw!r}") from None
