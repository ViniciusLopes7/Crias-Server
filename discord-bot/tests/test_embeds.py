"""Testes para o módulo crias_bot.embeds.

Valida que os builders de embed produzem estruturas consistentes:
- Cores corretas por semântica (success=verde, error=vermelho, etc.)
- Thumbnail e footer sempre presentes (identidade visual)
- Timestamp sempre presente
- Campos esperados em embeds específicos (status_online, health_report, etc.)
- event_embed mapeia cada tipo de evento conhecido

Não precisa de conexão Discord real — só valida a estrutura do objeto
discord.Embed (que é uma classe plain Python).
"""

from __future__ import annotations

# Importa embeds; skipa se discord.py não instalado.
try:
    from crias_bot.embeds import (
        Colors,
        agent_error,
        command_result,
        console_stream_error,
        console_stream_started,
        console_stream_stopped,
        error,
        event_embed,
        health_report,
        info,
        permission_denied,
        players_list,
        say_confirmation,
        status_offline,
        status_online,
        success,
        warning,
    )
except ImportError:
    import pytest

    pytest.skip("discord.py não instalado; teste de embeds pulado", allow_module_level=True)

import discord

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _has_thumbnail(embed: discord.Embed) -> bool:
    return embed.thumbnail is not None and bool(embed.thumbnail.url)


def _has_footer(embed: discord.Embed) -> bool:
    return embed.footer is not None and bool(embed.footer.text)


def _has_timestamp(embed: discord.Embed) -> bool:
    return embed.timestamp is not None


# ---------------------------------------------------------------------------
# Testes de helpers base (success / error / warning / info).
# ---------------------------------------------------------------------------


class TestBaseBuilders:
    def test_success_uses_green_color(self):
        e = success("ok", "desc")
        assert e.color.value == Colors.SUCCESS
        assert "ok" in e.title
        assert e.description == "desc"

    def test_error_uses_red_color(self):
        e = error("boom", "desc")
        assert e.color.value == Colors.ERROR

    def test_warning_uses_yellow_color(self):
        e = warning("cuidado")
        assert e.color.value == Colors.WARNING

    def test_info_uses_blue_color(self):
        e = info("hello")
        assert e.color.value == Colors.INFO

    def test_all_embeds_have_thumbnail(self):
        for e in [
            success("ok"),
            error("boom"),
            warning("cuidado"),
            info("hello"),
        ]:
            assert _has_thumbnail(e), f"thumbnail faltando em {e.title}"

    def test_all_embeds_have_footer(self):
        for e in [success("ok"), error("boom"), warning("cuidado"), info("hello")]:
            assert _has_footer(e), f"footer faltando em {e.title}"
            assert "Crias-Server" in e.footer.text

    def test_all_embeds_have_timestamp(self):
        for e in [success("ok"), error("boom"), warning("cuidado"), info("hello")]:
            assert _has_timestamp(e), f"timestamp faltando em {e.title}"

    def test_emoji_is_prefixed_to_title(self):
        e = success("Done")
        # success usa emoji ✅
        assert e.title.startswith("✅")


# ---------------------------------------------------------------------------
# Testes de helpers específicos.
# ---------------------------------------------------------------------------


class TestPermissionDenied:
    def test_default_is_admin(self):
        e = permission_denied()
        assert e.color.value == Colors.ERROR
        assert "admin" in e.description

    def test_custom_role(self):
        e = permission_denied("moderador")
        assert "moderador" in e.description


class TestAgentError:
    def test_contains_detail_in_codeblock(self):
        e = agent_error("connection refused")
        assert "connection refused" in e.description
        assert "```" in e.description
        assert e.color.value == Colors.ERROR


class TestCommandResult:
    def test_success_case(self):
        e = command_result(ok=True, action="iniciado", message="ok", service="minecraft")
        assert e.color.value == Colors.SUCCESS
        assert "iniciado" in e.title
        assert any(f.name == "Serviço" for f in e.fields)

    def test_failure_case(self):
        e = command_result(ok=False, action="iniciar", message="timeout", service="mc")
        assert e.color.value == Colors.ERROR
        assert "Falha" in e.title

    def test_no_service_field_when_empty(self):
        e = command_result(ok=True, action="reiniciado", message="ok", service="")
        assert not any(f.name == "Serviço" for f in e.fields)


class TestStatusOnline:
    def test_full_status(self):
        s = {
            "service_name": "minecraft",
            "stack": "minecraft",
            "hardware_tier": "HIGH",
            "uptime_seconds": 3661,  # 1h 1m 1s
            "players": ["Steve", "Alex"],
            "player_count": 2,
            "max_players": 20,
            "memory_used_mb": 1024,
            "memory_max_mb": 4096,
            "version": "1.1.0",
        }
        e = status_online(s)
        assert e.color.value == Colors.ONLINE
        # Campos chave devem estar presentes.
        field_names = {f.name for f in e.fields}
        assert "Stack" in field_names
        assert "Tier" in field_names
        assert "Uptime" in field_names
        assert "Memória" in field_names
        assert "Agente" in field_names
        # Uptime formatado: 1h 1m
        uptime_field = next(f for f in e.fields if f.name == "Uptime")
        assert "1h" in uptime_field.value
        # Players devem aparecer como `Steve`, `Alex`
        players_field = next(f for f in e.fields if "Players" in f.name)
        assert "Steve" in players_field.value
        assert "Alex" in players_field.value

    def test_empty_players(self):
        s = {
            "service_name": "terraria",
            "stack": "terraria",
            "hardware_tier": "LOW",
            "uptime_seconds": 30,
            "players": [],
            "player_count": 0,
            "max_players": 16,
            "memory_used_mb": 0,
            "memory_max_mb": 0,
            "version": "",
        }
        e = status_online(s)
        players_field = next(f for f in e.fields if "Players" in f.name)
        assert "ninguém" in players_field.value

    def test_handles_missing_keys_gracefully(self):
        # Dict com chaves faltantes não deve crashar.
        s = {"service_name": "mc"}
        e = status_online(s)
        assert e.color.value == Colors.ONLINE


class TestStatusOffline:
    def test_offline_uses_offline_color(self):
        e = status_offline("minecraft")
        assert e.color.value == Colors.OFFLINE
        assert "Offline" in e.description
        assert "minecraft" in e.title


class TestPlayersList:
    def test_empty_players(self):
        s = {"players": [], "player_count": 0, "max_players": 0}
        e = players_list(s)
        # info embed é azul
        assert e.color.value == Colors.INFO
        assert "Nenhum" in e.title

    def test_with_players(self):
        s = {"players": ["Steve", "Alex"], "player_count": 2, "max_players": 20}
        e = players_list(s)
        assert e.color.value == Colors.INFO
        assert "Steve" in e.description
        assert "Alex" in e.description
        assert "2/20" in e.title


class TestHealthReport:
    def test_healthy(self):
        h = {
            "healthy": True,
            "service": "minecraft",
            "port": 25565,
            "rcon_responsive": True,
            "message": "healthy",
        }
        e = health_report(h)
        assert e.color.value == Colors.SUCCESS
        assert any("Saudável" in f.value for f in e.fields)

    def test_unhealthy(self):
        h = {
            "healthy": False,
            "service": "minecraft",
            "port": 25565,
            "rcon_responsive": False,
            "message": "rcon indisponível",
        }
        e = health_report(h)
        assert e.color.value == Colors.WARNING
        assert any("sem resposta" in f.value for f in e.fields)


class TestSayConfirmation:
    def test_contains_message_in_codeblock(self):
        e = say_confirmation("Hello world")
        assert "Hello world" in e.description
        assert "```" in e.description
        assert e.color.value == Colors.SUCCESS


class TestConsoleEmbeds:
    def test_started(self):
        e = console_stream_started("<#123>")
        assert e.color.value == Colors.SUCCESS
        assert "<#123>" in e.description

    def test_stopped(self):
        e = console_stream_stopped()
        assert e.color.value == Colors.INFO

    def test_error(self):
        e = console_stream_error("stream broken")
        assert e.color.value == Colors.ERROR
        assert "stream broken" in e.description


# ---------------------------------------------------------------------------
# Testes do event_embed.
# ---------------------------------------------------------------------------


class TestEventEmbed:
    def test_server_started(self):
        ev = {
            "event_type": "ServerStarted",
            "service": "minecraft",
            "stack": "minecraft",
            "metadata": {},
        }
        e = event_embed(ev)
        assert e is not None
        assert e.color.value == Colors.ONLINE

    def test_server_stopped(self):
        ev = {"event_type": "ServerStopped", "service": "minecraft", "metadata": {}}
        e = event_embed(ev)
        assert e is not None
        assert e.color.value == Colors.OFFLINE

    def test_player_joined(self):
        ev = {
            "event_type": "PlayerJoined",
            "service": "minecraft",
            "metadata": {"player": "Steve"},
        }
        e = event_embed(ev)
        assert e is not None
        assert e.color.value == Colors.EVENT
        assert "Steve" in e.description

    def test_player_left(self):
        ev = {
            "event_type": "PlayerLeft",
            "service": "minecraft",
            "metadata": {"player": "Alex"},
        }
        e = event_embed(ev)
        assert e is not None
        assert "Alex" in e.description

    def test_health_warning(self):
        ev = {
            "event_type": "HealthWarning",
            "service": "minecraft",
            "stack": "minecraft",
            "metadata": {"reason": "rcon_timeout"},
        }
        e = event_embed(ev)
        assert e is not None
        assert e.color.value == Colors.WARNING
        assert "rcon_timeout" in e.description

    def test_unknown_event_returns_none(self):
        ev = {"event_type": "UnknownFuture", "metadata": {}}
        e = event_embed(ev)
        assert e is None

    def test_all_event_embeds_have_thumbnail_and_footer(self):
        cases = [
            {"event_type": "ServerStarted", "service": "mc", "metadata": {}},
            {"event_type": "ServerStopped", "service": "mc", "metadata": {}},
            {"event_type": "PlayerJoined", "service": "mc", "metadata": {"player": "x"}},
            {"event_type": "PlayerLeft", "service": "mc", "metadata": {"player": "x"}},
            {"event_type": "HealthWarning", "service": "mc", "metadata": {"reason": "x"}},
        ]
        for ev in cases:
            e = event_embed(ev)
            assert e is not None
            assert _has_thumbnail(e), f"thumbnail faltando em {ev['event_type']}"
            assert _has_footer(e), f"footer faltando em {ev['event_type']}"
            assert _has_timestamp(e), f"timestamp faltando em {ev['event_type']}"
