"""Tests para config.py."""

from __future__ import annotations

import dataclasses

import pytest

from crias_bot.config import BotConfig, _parse_id_list, _parse_optional_int, load_config


def test_parse_id_list_valid():
    result = _parse_id_list("111, 222, 333")
    assert result == frozenset({111, 222, 333})


def test_parse_id_list_empty():
    result = _parse_id_list("")
    assert result == frozenset()


def test_parse_id_list_with_invalid():
    result = _parse_id_list("111, abc, 333")
    assert result == frozenset({111, 333})


def test_parse_optional_int_valid():
    assert _parse_optional_int("12345") == 12345


def test_parse_optional_int_empty():
    assert _parse_optional_int("") is None
    assert _parse_optional_int("   ") is None


def test_parse_optional_int_invalid():
    assert _parse_optional_int("abc") is None


def test_load_config_missing_discord_token(monkeypatch):
    monkeypatch.delenv("DISCORD_TOKEN", raising=False)
    monkeypatch.delenv("CRIAS_AGENT_HOST", raising=False)
    monkeypatch.delenv("CRIAS_AGENT_TOKEN", raising=False)
    with pytest.raises(ValueError, match="DISCORD_TOKEN"):
        load_config()


def test_load_config_missing_agent_host(monkeypatch):
    monkeypatch.setenv("DISCORD_TOKEN", "fake_token")
    monkeypatch.delenv("CRIAS_AGENT_HOST", raising=False)
    monkeypatch.delenv("CRIAS_AGENT_TOKEN", raising=False)
    with pytest.raises(ValueError, match="CRIAS_AGENT_HOST"):
        load_config()


def test_load_config_missing_agent_token(monkeypatch):
    monkeypatch.setenv("DISCORD_TOKEN", "fake_token")
    monkeypatch.setenv("CRIAS_AGENT_HOST", "https://example.ts.net")
    monkeypatch.delenv("CRIAS_AGENT_TOKEN", raising=False)
    with pytest.raises(ValueError, match="CRIAS_AGENT_TOKEN"):
        load_config()


def test_load_config_full(monkeypatch):
    monkeypatch.setenv("DISCORD_TOKEN", "tok")
    monkeypatch.setenv("CRIAS_AGENT_HOST", "https://host.ts.net")
    monkeypatch.setenv("CRIAS_AGENT_TOKEN", "abc123")
    monkeypatch.setenv("DISCORD_GUILD_ID", "123")
    monkeypatch.setenv("DISCORD_ADMIN_ROLE_IDS", "111,222")
    monkeypatch.setenv("DISCORD_MODERATOR_ROLE_IDS", "333")
    monkeypatch.setenv("DISCORD_CONTROLE_CHANNEL_ID", "444")
    monkeypatch.setenv("STATUS_CACHE_SECONDS", "30")
    monkeypatch.setenv("RECONNECT_MAX_DELAY", "120")

    cfg = load_config()
    assert cfg.discord_token == "tok"
    assert cfg.agent_host == "https://host.ts.net"
    assert cfg.agent_token == "abc123"
    assert cfg.guild_id == 123
    assert cfg.admin_role_ids == frozenset({111, 222})
    assert cfg.moderator_role_ids == frozenset({333})
    assert cfg.controle_channel_id == 444
    assert cfg.status_cache_seconds == 30
    assert cfg.reconnect_max_delay == 120


def test_bot_config_is_frozen():
    cfg = BotConfig(
        discord_token="x",
        agent_host="x",
        agent_token="x",
    )
    # FrozenInstanceError é específico para dataclass(frozen=True).
    with pytest.raises(dataclasses.FrozenInstanceError):
        cfg.discord_token = "y"


def test_bot_config_defaults():
    cfg = BotConfig(
        discord_token="tok",
        agent_host="host",
        agent_token="token",
    )
    assert cfg.guild_id is None
    assert cfg.admin_role_ids == frozenset()
    assert cfg.moderator_role_ids == frozenset()
    assert cfg.controle_channel_id is None
    assert cfg.status_cache_seconds == 15
    assert cfg.reconnect_max_delay == 60


def test_bot_config_with_optional_fields():
    cfg = BotConfig(
        discord_token="tok",
        agent_host="host",
        agent_token="token",
        guild_id=123,
        admin_role_ids=frozenset({1, 2}),
        controle_channel_id=999,
        status_cache_seconds=30,
    )
    assert cfg.guild_id == 123
    assert cfg.admin_role_ids == frozenset({1, 2})
    assert cfg.controle_channel_id == 999
    assert cfg.status_cache_seconds == 30
