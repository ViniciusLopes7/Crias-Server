"""Cliente gRPC para o crias-agent.

Wrapper assíncrono sobre grpc.aio com:
  - Reconexão com backoff exponencial (1s, 2s, 4s, ... até 60s)
  - Cache curto de GetStatus (default 15s)
  - Helper para converter respostas proto em dicts Python
  - asyncio.Lock para evitar race conditions em connect concorrente

Geração do código proto:
  python -m grpc_tools.protoc \
      -I ../discord-agent/proto \
      --python_out=grpc_gen \
      --grpc_python_out=grpc_gen \
      ../discord-agent/proto/crias.proto
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from typing import Any

import grpc
from grpc import aio as grpc_aio

# Código gerado pelo grpc_tools.protoc.
# Em produção, este import aponta para grpc_gen.crias_pb2 etc.
try:
    from .grpc_gen import crias_pb2, crias_pb2_grpc
except ImportError as exc:
    # Fallback para desenvolvimento: proto não gerado ainda.
    raise ImportError(
        "Código protobuf não gerado. Execute:\n"
        "  cd discord-bot && python -m grpc_tools.protoc "
        "-I ../discord-agent/proto --python_out=grpc_gen "
        "--grpc_python_out=grpc_gen ../discord-agent/proto/crias.proto"
    ) from exc


logger = logging.getLogger(__name__)


class AgentClientError(Exception):
    """Erro de comunicação com o agente."""


class AgentClient:
    """Cliente gRPC assíncrono para o crias-agent.

    Seguro para uso concorrente: múltiplas coroutines podem chamar
    RPCs simultaneamente. A conexão é gerenciada por um asyncio.Lock
    para evitar duplicação de channels em retries concorrentes.
    """

    def __init__(self, host: str, token: str, max_reconnect_delay: int = 60) -> None:
        self.host = host
        self.token = token
        self.max_reconnect_delay = max_reconnect_delay

        self._channel: grpc_aio.Channel | None = None
        self._stub: crias_pb2_grpc.ServerControlStub | None = None
        self._event_stub: crias_pb2_grpc.EventBusStub | None = None

        # Lock para serializar connect() chamado concorrentemente por
        # _ensure_connected() de múltiplas coroutines.
        self._connect_lock: asyncio.Lock = asyncio.Lock()

        # Cache de GetStatus.
        self._status_cache: tuple[crias_pb2.StatusResponse, float] | None = None
        self._status_cache_ttl: float = 15.0  # segundos

    async def connect(self) -> None:
        """Conecta ao agente com backoff exponencial até 60s.

        Se já conectado, retorna imediatamente. Se uma conexão anterior
        existe mas falhou, fecha-a antes de criar nova (evita FD leak).
        """
        async with self._connect_lock:
            # Double-check após adquirir lock (outra coroutine pode ter conectado).
            if self._stub is not None and self._event_stub is not None:
                return

            delay = 1.0
            while True:
                # Fecha channel anterior se existir (evita resource leak).
                if self._channel is not None:
                    try:
                        await self._channel.close()
                    except Exception:
                        pass
                    self._channel = None
                    self._stub = None
                    self._event_stub = None

                try:
                    target = self.host
                    if target.startswith("https://"):
                        # Tailscale Funnel: HTTPS com TLS.
                        target = target[len("https://") :]
                        creds = grpc.ssl_channel_credentials()
                        self._channel = grpc_aio.secure_channel(
                            target,
                            creds,
                            options=[
                                ("grpc.max_receive_message_length", 1 * 1024 * 1024),
                            ],
                        )
                    elif target.startswith("http://"):
                        target = target[len("http://") :]
                        self._channel = grpc_aio.insecure_channel(target)
                    else:
                        # Asume host:port sem esquema = insecure.
                        self._channel = grpc_aio.insecure_channel(target)

                    # Aguarda channel estar pronto (timeout 5s).
                    await asyncio.wait_for(self._channel.channel_ready(), timeout=5.0)

                    self._stub = crias_pb2_grpc.ServerControlStub(self._channel)
                    self._event_stub = crias_pb2_grpc.EventBusStub(self._channel)
                    logger.info("conectado ao agente em %s", self.host)
                    return
                except (grpc.RpcError, TimeoutError, OSError) as e:
                    logger.warning("connect falhou (tentativa próxima em %.1fs): %s", delay, e)
                    # Fecha channel parcialmente criado para evitar leak.
                    if self._channel is not None:
                        try:
                            await self._channel.close()
                        except Exception:
                            pass
                        self._channel = None
                    await asyncio.sleep(min(delay, self.max_reconnect_delay))
                    delay *= 2

    async def close(self) -> None:
        """Fecha o canal gRPC."""
        async with self._connect_lock:
            if self._channel is not None:
                await self._channel.close()
                self._channel = None
                self._stub = None
                self._event_stub = None

    def _metadata(self) -> list[tuple[str, str]]:
        return [("x-api-token", self.token)]

    async def _ensure_connected(self) -> None:
        if self._stub is None or self._event_stub is None:
            await self.connect()

    # --- ServerControl RPCs ---

    async def start_server(self) -> dict[str, Any]:
        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            resp = await self._stub.StartServer(
                crias_pb2.StartRequest(),
                metadata=self._metadata(),
            )
            return {"ok": resp.ok, "message": resp.message, "service": resp.service_name}
        except grpc.RpcError as e:
            raise AgentClientError(f"StartServer falhou: {e}") from e

    async def stop_server(self) -> dict[str, Any]:
        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            resp = await self._stub.StopServer(
                crias_pb2.StopRequest(),
                metadata=self._metadata(),
            )
            return {"ok": resp.ok, "message": resp.message, "service": resp.service_name}
        except grpc.RpcError as e:
            raise AgentClientError(f"StopServer falhou: {e}") from e

    async def restart_server(self) -> dict[str, Any]:
        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            resp = await self._stub.RestartServer(
                crias_pb2.RestartRequest(),
                metadata=self._metadata(),
            )
            return {"ok": resp.ok, "message": resp.message, "service": resp.service_name}
        except grpc.RpcError as e:
            raise AgentClientError(f"RestartServer falhou: {e}") from e

    async def get_status(
        self, use_cache: bool = True, cache_ttl: float | None = None
    ) -> dict[str, Any]:
        """Retorna status do servidor. Usa cache curto por default."""
        if use_cache and self._status_cache is not None:
            cached_resp, cached_at = self._status_cache
            ttl = cache_ttl if cache_ttl is not None else self._status_cache_ttl
            if time.monotonic() - cached_at < ttl:
                return _status_to_dict(cached_resp)

        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            resp = await self._stub.GetStatus(
                crias_pb2.GetStatusRequest(),
                metadata=self._metadata(),
            )
            self._status_cache = (resp, time.monotonic())
            return _status_to_dict(resp)
        except grpc.RpcError as e:
            raise AgentClientError(f"GetStatus falhou: {e}") from e

    async def get_health(self) -> dict[str, Any]:
        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            resp = await self._stub.GetHealth(
                crias_pb2.GetHealthRequest(),
                metadata=self._metadata(),
            )
            return {
                "healthy": resp.healthy,
                "service": resp.service_name,
                "port_listening": resp.port_listening,
                "port": resp.port,
                "rcon_responsive": resp.rcon_responsive,
                "message": resp.message,
            }
        except grpc.RpcError as e:
            raise AgentClientError(f"GetHealth falhou: {e}") from e

    async def send_rcon_command(self, command: str) -> dict[str, Any]:
        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            resp = await self._stub.SendRconCommand(
                crias_pb2.SendRconCommandRequest(command=command),
                metadata=self._metadata(),
            )
            return {"ok": resp.ok, "output": resp.output, "error": resp.error}
        except grpc.RpcError as e:
            raise AgentClientError(f"SendRconCommand falhou: {e}") from e

    async def stream_console(self, tail_lines: int = 50) -> AsyncIterator[str]:
        """Stream de console do servidor. Itera indefinidamente até o caller cancelar."""
        await self._ensure_connected()
        if self._stub is None:
            raise AgentClientError("não conectado ao agente")
        try:
            stream = self._stub.StreamConsole(
                crias_pb2.StreamConsoleRequest(tail_lines=tail_lines),
                metadata=self._metadata(),
            )
            async for line in stream:
                yield line.line
        except grpc.RpcError as e:
            raise AgentClientError(f"StreamConsole falhou: {e}") from e

    # --- EventBus RPCs ---

    async def subscribe_events(
        self, event_types: list[str] | None = None
    ) -> AsyncIterator[dict[str, Any]]:
        """Subscreve a eventos do agente. Itera indefinidamente."""
        await self._ensure_connected()
        assert self._event_stub is not None
        try:
            req = crias_pb2.SubscribeEventsRequest()
            if event_types:
                req.event_types.extend(event_types)
            stream = self._event_stub.SubscribeEvents(req, metadata=self._metadata())
            async for ev in stream:
                yield {
                    "event_id": ev.event_id,
                    "event_type": ev.event_type,
                    "timestamp": ev.timestamp_unix,
                    "service": ev.service_name,
                    "stack": ev.stack,
                    "metadata": dict(ev.metadata),
                }
        except grpc.RpcError as e:
            raise AgentClientError(f"SubscribeEvents falhou: {e}") from e


def _status_to_dict(resp: crias_pb2.StatusResponse) -> dict[str, Any]:
    return {
        "service_active": resp.service_active,
        "service_name": resp.service_name,
        "stack": resp.stack,
        "player_count": resp.player_count,
        "players": list(resp.players),
        "max_players": resp.max_players,
        "uptime_seconds": resp.uptime_seconds,
        "hardware_tier": resp.hardware_tier,
        "memory_used_mb": resp.memory_used_mb,
        "memory_max_mb": resp.memory_max_mb,
        "version": resp.version,
    }
