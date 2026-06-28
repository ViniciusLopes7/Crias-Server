"""Tests de contrato para AgentClient (sem rede real).

Estes testes validam a estrutura da classe e helpers sem precisar de um
agente gRPC real rodando. Usam mocks onde necessário.

Path setup é feito pelo conftest.py no diretório tests/.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

# Tenta importar; skipa se grpc_gen não gerado.
try:
    from crias_bot.agent_client import AgentClient, AgentClientError
except ImportError as e:
    pytest.skip(f"Não foi possível importar AgentClient: {e}", allow_module_level=True)


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
        # Simula cache populado.
        c._status_cache = (MagicMock(), 0.0)  # timestamp 0 = sempre fresco

        # Stub não existe, mas com cache não deve ser chamado.
        async def run():
            # Como não há _stub, sem cache daria erro. Com cache deve retornar dict.
            result = await c.get_status(use_cache=True, cache_ttl=999999.0)
            assert isinstance(result, dict)

        import asyncio

        asyncio.run(run())


class TestAgentClientError:
    def test_agent_client_error_is_exception(self):
        assert issubclass(AgentClientError, Exception)

    def test_agent_client_error_message(self):
        err = AgentClientError("something failed")
        assert str(err) == "something failed"
