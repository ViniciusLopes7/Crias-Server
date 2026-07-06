"""Tests de contrato para AgentClient (sem rede real).

Estes testes validam a estrutura da classe, helpers e os wrappers RPC
assíncronos usando mocks para o stub gRPC (sem abrir channel real).

Cobertura (TST-005):
  - Init / metadata / cache structure (testes originais preservados).
  - start_server / stop_server / restart_server: sucesso, RpcError, stub=None.
  - get_status: sucesso, cache hit, cache miss, RpcError.
  - send_rcon_command: sucesso e falha.
  - get_health: sucesso.
  - Reconexão com backoff exponencial (connect() com alvo inalcançável).
  - _status_to_dict: mapeamento de campos.

Path setup é feito pelo conftest.py no diretório tests/.
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock

import grpc
import pytest

# Tenta importar; skipa se grpc_gen não gerado.
try:
    from crias_bot.agent_client import AgentClient, AgentClientError, _status_to_dict
    from crias_bot.grpc_gen import crias_pb2
except ImportError as e:
    pytest.skip(f"Não foi possível importar AgentClient: {e}", allow_module_level=True)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _make_client() -> AgentClient:
    """Cria AgentClient com stubs mockados (sem rede)."""
    c = AgentClient(host="localhost:8473", token="test-token")
    # Substitui stubs por mocks para evitar connect() real.
    c._stub = MagicMock()
    c._event_stub = MagicMock()
    return c


def _make_status_response(**overrides) -> crias_pb2.StatusResponse:
    """Cria uma StatusResponse proto com defaults sane."""
    defaults = {
        "service_active": True,
        "service_name": "minecraft",
        "stack": "minecraft",
        "player_count": 2,
        "players": ["Steve", "Alex"],
        "max_players": 20,
        "uptime_seconds": 3600,
        "hardware_tier": "HIGH",
        "memory_used_mb": 1024,
        "memory_max_mb": 4096,
        "version": "1.1.0",
    }
    defaults.update(overrides)
    return crias_pb2.StatusResponse(**defaults)


# ---------------------------------------------------------------------------
# Tests originais (preservados).
# ---------------------------------------------------------------------------


class TestAgentClientInit:
    def test_init_stores_host_token(self):
        c = AgentClient(host="https://example.ts.net", token="abc123")
        assert c.host == "https://example.ts.net"
        assert c.token == "abc123"

    def test_init_default_max_reconnect_delay(self):
        c = AgentClient(host="localhost:8473", token="x")
        assert c.max_reconnect_delay == 60

    def test_init_custom_max_reconnect_delay(self):
        c = AgentClient(host="localhost:8473", token="x", max_reconnect_delay=30)
        assert c.max_reconnect_delay == 30

    def test_init_starts_disconnected(self):
        c = AgentClient(host="localhost:8473", token="x")
        assert c._channel is None
        assert c._stub is None
        assert c._event_stub is None

    def test_init_status_cache_is_none(self):
        c = AgentClient(host="localhost:8473", token="x")
        assert c._status_cache is None


class TestAgentClientMetadata:
    def test_metadata_contains_token(self):
        c = AgentClient(host="localhost:8473", token="secret_token")
        md = c._metadata()
        assert ("x-api-token", "secret_token") in md

    def test_metadata_is_list_of_tuples(self):
        c = AgentClient(host="localhost:8473", token="x")
        md = c._metadata()
        assert isinstance(md, list)
        for entry in md:
            assert isinstance(entry, tuple)
            assert len(entry) == 2
            assert isinstance(entry[0], str)
            assert isinstance(entry[1], str)


class TestAgentClientCache:
    def test_status_cache_ttl_default(self):
        c = AgentClient(host="localhost:8473", token="x")
        assert c._status_cache_ttl == 15.0

    def test_get_status_with_cache_no_call(self):
        """Se cache está populado, get_status não deve chamar o stub."""
        c = AgentClient(host="localhost:8473", token="x")
        # Simula cache populado com uma StatusResponse real (TST-008: usar
        # objeto proto real em vez de MagicMock garante que _status_to_dict
        # é exercitado de ponta a ponta — se o helper quebrar em tipos
        # errados, o teste falha em vez de dar falso positivo).
        resp = _make_status_response()
        c._status_cache = (resp, 0.0)  # timestamp 0 = sempre fresco

        # Stub não existe, mas com cache não deve ser chamado.
        async def run():
            result = await c.get_status(use_cache=True, cache_ttl=999999.0)
            assert isinstance(result, dict)
            # Cache hit deve trazer os campos do proto real.
            assert result["service_name"] == "minecraft"
            assert result["player_count"] == 2
            assert result["players"] == ["Steve", "Alex"]

        asyncio.run(run())

    def test_get_status_cache_expired_calls_stub(self):
        """Cache expirado deve chamar o stub e atualizar o cache."""
        c = _make_client()
        # Popula cache com timestamp antigo (expirado).
        old_resp = _make_status_response(service_name="old")
        c._status_cache = (old_resp, 0.0)

        new_resp = _make_status_response(service_name="new", player_count=10)
        c._stub.GetStatus = AsyncMock(return_value=new_resp)

        async def run():
            # cache_ttl=0.0 força cache a sempre estar expirado.
            result = await c.get_status(use_cache=True, cache_ttl=0.0)
            assert result["service_name"] == "new"
            assert result["player_count"] == 10
            c._stub.GetStatus.assert_awaited_once()

        asyncio.run(run())

    def test_get_status_skip_cache(self):
        """use_cache=False deve sempre chamar o stub."""
        c = _make_client()
        resp = _make_status_response(service_name="fresh")
        c._stub.GetStatus = AsyncMock(return_value=resp)
        # Popula cache mesmo assim.
        c._status_cache = (_make_status_response(service_name="cached"), 0.0)

        async def run():
            result = await c.get_status(use_cache=False)
            assert result["service_name"] == "fresh"
            c._stub.GetStatus.assert_awaited_once()

        asyncio.run(run())


class TestAgentClientError:
    def test_agent_client_error_is_exception(self):
        assert issubclass(AgentClientError, Exception)

    def test_agent_client_error_message(self):
        err = AgentClientError("something failed")
        assert str(err) == "something failed"


# ---------------------------------------------------------------------------
# Novos testes — RPCs (TST-005).
# ---------------------------------------------------------------------------


class TestStartServer:
    def test_success(self):
        c = _make_client()
        c._stub.StartServer = AsyncMock(
            return_value=crias_pb2.StartResponse(ok=True, message="ok", service_name="minecraft")
        )

        async def run():
            result = await c.start_server()
            assert result == {"ok": True, "message": "ok", "service": "minecraft"}
            c._stub.StartServer.assert_awaited_once()
            # Verifica que metadata com token foi passada.
            args, kwargs = c._stub.StartServer.call_args
            assert ("x-api-token", "test-token") in kwargs["metadata"]

        asyncio.run(run())

    def test_failure_response(self):
        """Agente retorna ok=False — cliente deve propagar como dict (não exceção)."""
        c = _make_client()
        c._stub.StartServer = AsyncMock(
            return_value=crias_pb2.StartResponse(ok=False, message="falha: systemctl", service_name="mc")
        )

        async def run():
            result = await c.start_server()
            assert result["ok"] is False
            assert "falha" in result["message"]

        asyncio.run(run())

    def test_rpc_error_wraps_to_agent_client_error(self):
        c = _make_client()

        # RpcError é base class; instanciamos via construtor para simular.
        def raise_rpc(*a, **kw):
            raise grpc.RpcError("connection refused")

        c._stub.StartServer = AsyncMock(side_effect=raise_rpc)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.start_server()
            assert "StartServer falhou" in str(exc_info.value)

        asyncio.run(run())


class TestStopServer:
    def test_success(self):
        c = _make_client()
        c._stub.StopServer = AsyncMock(
            return_value=crias_pb2.StopResponse(ok=True, message="servidor parado", service_name="minecraft")
        )

        async def run():
            result = await c.stop_server()
            assert result["ok"] is True
            assert result["service"] == "minecraft"

        asyncio.run(run())

    def test_rpc_error(self):
        c = _make_client()

        def raise_rpc(*a, **kw):
            raise grpc.RpcError("unavailable")

        c._stub.StopServer = AsyncMock(side_effect=raise_rpc)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.stop_server()
            assert "StopServer falhou" in str(exc_info.value)

        asyncio.run(run())


class TestRestartServer:
    def test_success(self):
        c = _make_client()
        c._stub.RestartServer = AsyncMock(
            return_value=crias_pb2.RestartResponse(ok=True, message="servidor reiniciado", service_name="minecraft")
        )

        async def run():
            result = await c.restart_server()
            assert result["ok"] is True
            assert "reiniciado" in result["message"]

        asyncio.run(run())

    def test_rpc_error(self):
        c = _make_client()

        def raise_rpc(*a, **kw):
            raise grpc.RpcError("deadline exceeded")

        c._stub.RestartServer = AsyncMock(side_effect=raise_rpc)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.restart_server()
            assert "RestartServer falhou" in str(exc_info.value)

        asyncio.run(run())


class TestGetStatus:
    def test_success_no_cache(self):
        c = _make_client()
        c._stub.GetStatus = AsyncMock(return_value=_make_status_response())

        async def run():
            result = await c.get_status(use_cache=False)
            assert result["service_active"] is True
            assert result["service_name"] == "minecraft"
            assert result["player_count"] == 2
            assert result["players"] == ["Steve", "Alex"]
            assert result["max_players"] == 20
            assert result["uptime_seconds"] == 3600
            assert result["hardware_tier"] == "HIGH"
            assert result["memory_used_mb"] == 1024
            assert result["memory_max_mb"] == 4096
            assert result["version"] == "1.1.0"

        asyncio.run(run())

    def test_populates_cache_after_call(self):
        c = _make_client()
        c._stub.GetStatus = AsyncMock(return_value=_make_status_response())

        async def run():
            await c.get_status(use_cache=False)
            assert c._status_cache is not None
            cached_resp, cached_at = c._status_cache
            assert cached_resp.service_name == "minecraft"
            # cached_at deve ser ~agora.
            import time

            assert time.monotonic() - cached_at < 1.0

        asyncio.run(run())

    def test_rpc_error(self):
        c = _make_client()

        def raise_rpc(*a, **kw):
            raise grpc.RpcError("internal")

        c._stub.GetStatus = AsyncMock(side_effect=raise_rpc)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.get_status(use_cache=False)
            assert "GetStatus falhou" in str(exc_info.value)

        asyncio.run(run())


class TestGetHealth:
    def test_success_healthy(self):
        c = _make_client()
        c._stub.GetHealth = AsyncMock(
            return_value=crias_pb2.HealthResponse(
                healthy=True,
                service_name="minecraft",
                port_listening=True,
                port=25565,
                rcon_responsive=True,
                message="healthy",
            )
        )

        async def run():
            result = await c.get_health()
            assert result["healthy"] is True
            assert result["service"] == "minecraft"
            assert result["port_listening"] is True
            assert result["port"] == 25565
            assert result["rcon_responsive"] is True
            assert result["message"] == "healthy"

        asyncio.run(run())

    def test_success_unhealthy(self):
        c = _make_client()
        c._stub.GetHealth = AsyncMock(
            return_value=crias_pb2.HealthResponse(
                healthy=False,
                service_name="minecraft",
                port_listening=False,
                port=25565,
                rcon_responsive=False,
                message="porta 25565 não está em escuta",
            )
        )

        async def run():
            result = await c.get_health()
            assert result["healthy"] is False
            assert "não está em escuta" in result["message"]

        asyncio.run(run())

    def test_rpc_error(self):
        c = _make_client()

        def raise_rpc(*a, **kw):
            raise grpc.RpcError("unavailable")

        c._stub.GetHealth = AsyncMock(side_effect=raise_rpc)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.get_health()
            assert "GetHealth falhou" in str(exc_info.value)

        asyncio.run(run())


class TestSendRconCommand:
    def test_success(self):
        c = _make_client()
        c._stub.SendRconCommand = AsyncMock(
            return_value=crias_pb2.SendRconCommandResponse(
                ok=True, output="[Server] Hello from Discord", error=""
            )
        )

        async def run():
            result = await c.send_rcon_command("say Hello from Discord")
            assert result["ok"] is True
            assert "Hello from Discord" in result["output"]
            assert result["error"] == ""
            # Verifica que o comando foi passado no request.
            args, kwargs = c._stub.SendRconCommand.call_args
            req = args[0] if args else kwargs.get("request")
            assert req.command == "say Hello from Discord"

        asyncio.run(run())

    def test_failure_with_error_message(self):
        c = _make_client()
        c._stub.SendRconCommand = AsyncMock(
            return_value=crias_pb2.SendRconCommandResponse(
                ok=False, output="", error="comando não whitelistado"
            )
        )

        async def run():
            result = await c.send_rcon_command("stop")
            assert result["ok"] is False
            assert "whitelist" in result["error"]

        asyncio.run(run())

    def test_rpc_error(self):
        c = _make_client()

        def raise_rpc(*a, **kw):
            raise grpc.RpcError("rcon disconnected")

        c._stub.SendRconCommand = AsyncMock(side_effect=raise_rpc)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.send_rcon_command("list")
            assert "SendRconCommand falhou" in str(exc_info.value)

        asyncio.run(run())


class TestStatusToDict:
    """Testa o helper _status_to_dict diretamente (TST-008: garante que
    refatorações no helper não quebrem silenciosamente o cache hit)."""

    def test_full_mapping(self):
        resp = _make_status_response()
        d = _status_to_dict(resp)
        assert d == {
            "service_active": True,
            "service_name": "minecraft",
            "stack": "minecraft",
            "player_count": 2,
            "players": ["Steve", "Alex"],
            "max_players": 20,
            "uptime_seconds": 3600,
            "hardware_tier": "HIGH",
            "memory_used_mb": 1024,
            "memory_max_mb": 4096,
            "version": "1.1.0",
        }

    def test_empty_players_list(self):
        resp = _make_status_response(players=[], player_count=0)
        d = _status_to_dict(resp)
        assert d["players"] == []
        assert d["player_count"] == 0

    def test_field_types(self):
        """Garante que o helper retorna tipos Python nativos (não tipos proto)."""
        resp = _make_status_response()
        d = _status_to_dict(resp)
        assert isinstance(d["players"], list)
        assert isinstance(d["player_count"], int)
        assert isinstance(d["uptime_seconds"], int)
        assert isinstance(d["memory_used_mb"], int)


# ---------------------------------------------------------------------------
# Reconnection logic (TST-005: cobre linhas 75-134 de agent_client.py).
# ---------------------------------------------------------------------------


class TestConnectBackoff:
    """Testa a lógica de reconexão com backoff exponencial sem abrir socket
    real. Patchamos grpc_aio.insecure_channel para nunca ficar ready."""

    def test_connect_retries_with_backoff_until_max_delay(self, monkeypatch):
        """connect() deve fazer retry com backoff crescente até max_reconnect_delay,
        sem exceder o teto."""
        # Cliente com max_reconnect_delay baixo para o teste não demorar.
        c = AgentClient(host="localhost:1", token="x", max_reconnect_delay=2)

        # Patcha asyncio.sleep para capturar delays sem esperar de verdade.
        delays: list[float] = []
        original_sleep = asyncio.sleep

        async def fake_sleep(d):
            if d >= 1.0:
                delays.append(d)
            await original_sleep(0)

        monkeypatch.setattr("crias_bot.agent_client.asyncio.sleep", fake_sleep)

        # Patcha insecure_channel para retornar um channel que nunca fica ready.
        class FakeChannel:
            async def channel_ready(self):
                raise TimeoutError("never ready")

            async def close(self):
                pass

        monkeypatch.setattr(
            "crias_bot.agent_client.grpc_aio.insecure_channel",
            lambda target, **kwargs: FakeChannel(),
        )

        # Patcha asyncio.wait_for: channel_ready (timeout=5.0) sempre falha;
        # backoff delay (timeout<5.0) registra e simula timeout do _closing.wait().
        async def fake_wait_for(coro, timeout):
            # Não aguarda a coro — apenas decide com base no timeout.
            coro.close()  # evita "never awaited" warning
            # Cede controle para o loop de eventos (permite cancelamento)
            await original_sleep(0)
            if timeout and timeout >= 5.0:
                raise TimeoutError("never ready")
            # Backoff delay: registra e simula timeout do _closing.wait()
            if timeout and 0 < timeout < 5.0:
                delays.append(timeout)
                raise TimeoutError()
            raise TimeoutError("never ready")

        monkeypatch.setattr("crias_bot.agent_client.asyncio.wait_for", fake_wait_for)

        async def run():
            # Roda connect() em background e cancela após algumas iterações.
            task = asyncio.create_task(c.connect())
            # Usa original_sleep (não o fake) para o wait interno do teste.
            await original_sleep(0.1)
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        asyncio.run(run())

        # Devemos ter pelo menos 1 delay de backoff registrado.
        assert len(delays) >= 1, f"esperado >=1 retry, obtido delays={delays}"
        # Nenhum delay deve exceder max_reconnect_delay=2.
        for d in delays:
            assert d <= 2.0, f"delay {d} excede max_reconnect_delay=2"
        # Sequência deve ser crescente (1.0, 2.0, 2.0, 2.0, ...) — backoff.
        assert delays[0] == 1.0, f"primeiro delay esperado 1.0, obtido {delays[0]}"

    def test_connect_returns_immediately_if_already_connected(self):
        """Se stubs já estão setados, connect() retorna sem fazer nada."""
        c = _make_client()  # stubs já mockados

        async def run():
            # Deve retornar imediatamente (sem chamar insecure_channel).
            await c.connect()

        # Se connect() tentasse abrir channel real, asyncio.run travaria.
        asyncio.run(run())


class TestEnsureConnected:
    def test_ensure_connected_skips_when_stubs_set(self):
        c = _make_client()

        async def run():
            # Stub já está setado — não deve chamar connect().
            await c._ensure_connected()
            # Se chegou aqui sem hangar/erro, OK.

        asyncio.run(run())

    def test_ensure_connected_calls_connect_when_stubs_none(self, monkeypatch):
        c = AgentClient(host="localhost:1", token="x")
        # stubs são None inicialmente.

        connect_called = False

        async def fake_connect():
            nonlocal connect_called
            connect_called = True
            # Simula que connect conseguiu stub.
            c._stub = MagicMock()
            c._event_stub = MagicMock()

        monkeypatch.setattr(c, "connect", fake_connect)

        async def run():
            await c._ensure_connected()

        asyncio.run(run())
        assert connect_called


class TestClose:
    def test_close_with_no_channel_is_noop(self):
        c = AgentClient(host="localhost:8473", token="x")
        # _channel é None — close() não deve panicar.

        async def run():
            await c.close()

        asyncio.run(run())

    def test_close_clears_stubs(self, monkeypatch):
        c = _make_client()

        # Substitui _channel por um fake com close() async.
        class FakeChannel:
            async def close(self):
                pass

        c._channel = FakeChannel()

        async def run():
            await c.close()

        asyncio.run(run())
        assert c._channel is None
        assert c._stub is None
        assert c._event_stub is None


# ---------------------------------------------------------------------------
# Stub=None edge cases (quando connect falha e stubs continuam None).
# ---------------------------------------------------------------------------


class TestRpcWhenStubIsNone:
    """Garante que RPCs lançam AgentClientError quando stub é None
    (caso de connect() falha e _ensure_connected não conseguiu recuperar)."""

    def _make_disconnected_client(self) -> AgentClient:
        c = AgentClient(host="localhost:1", token="x")
        # Força _ensure_connected a não fazer nada (simula connect() falho).
        c._stub = None
        c._event_stub = None
        return c

    def test_start_server_raises_when_disconnected(self, monkeypatch):
        c = self._make_disconnected_client()

        async def fake_ensure(self_):
            # Não faz nada — stubs continuam None.
            pass

        monkeypatch.setattr(AgentClient, "_ensure_connected", fake_ensure)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.start_server()
            assert "não conectado" in str(exc_info.value)

        asyncio.run(run())

    def test_get_status_raises_when_disconnected(self, monkeypatch):
        c = self._make_disconnected_client()

        async def fake_ensure(self_):
            pass

        monkeypatch.setattr(AgentClient, "_ensure_connected", fake_ensure)

        async def run():
            with pytest.raises(AgentClientError) as exc_info:
                await c.get_status(use_cache=False)
            assert "não conectado" in str(exc_info.value)

        asyncio.run(run())
