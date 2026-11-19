"""Tests do stream de console (EXP-47 reconnect + EXP-61 sanitização).

Valida sem Discord/gRPC real:
  - _sanitize_console_text / _format_console_chunk: neutralização de
    backticks triplos (e runs de 4+) e truncamento <2000 chars.
  - _send_console_buffer: chunks sanitizados, allowed_mentions=none,
    status ok/retry/stop.
  - _console_stream_loop: reopen após deadline marker do agente (sem replay
    do histórico de 50 linhas), backoff exponencial 1→15s, reset do backoff
    em reopen saudável, desistência após 5 falhas consecutivas com aviso
    visível, parada por comando do usuário e por falhas de envio.

Técnicas: CriasBot via __new__ (sem gateway), FakeAgent com tentativas
scriptadas de stream_console, asyncio.sleep do módulo bot acelerado.
"""

from __future__ import annotations

import asyncio
import contextlib
import time
from unittest.mock import AsyncMock, MagicMock

import discord
import pytest

try:
    from crias_bot.agent_client import AgentClientError
    from crias_bot.bot import (
        _CONSOLE_DEADLINE_MARKER,
        _FLUSH_OK,
        _FLUSH_RETRY,
        _FLUSH_STOP,
        CriasBot,
        MinecraftCog,
        _format_console_chunk,
        _sanitize_console_text,
        _send_console_buffer,
    )
    from crias_bot.config import BotConfig
except ImportError:
    pytest.skip(
        "discord.py não instalado; testes de console stream pulados", allow_module_level=True
    )


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _make_bot(agent) -> CriasBot:
    """Cria CriasBot via __new__ (sem gateway) com um agent fake."""
    bot = CriasBot.__new__(CriasBot)
    bot.config = BotConfig(discord_token="x", agent_host="localhost:8473", agent_token="y")
    bot.agent = agent
    bot._console_stream_active = True
    bot._console_task = None
    return bot


def _make_channel() -> MagicMock:
    channel = MagicMock()
    channel.id = 42
    channel.send = AsyncMock()
    return channel


class FakeAgent:
    """AgentClient stand-in: cada chamada a stream_console() consome uma tentativa.

    Uma tentativa pode ser:
      - list[str | callable]: linhas a emitir; callables são executados como
        efeito colateral (ex.: desativar a sessão) antes de continuar;
      - BaseException: levantada na primeira iteração (erro de RPC);
      - None: stream que nunca termina (espera cancelamento).
    """

    def __init__(self, attempts: list) -> None:
        self.attempts = list(attempts)
        self.calls: list[int] = []

    async def stream_console(self, tail_lines: int = 50):
        self.calls.append(tail_lines)
        attempt = self.attempts.pop(0) if self.attempts else None
        if isinstance(attempt, BaseException):
            raise attempt
        if attempt is None:
            await asyncio.Event().wait()
            return
        for item in attempt:
            if callable(item):
                item()
            else:
                yield item


def _fast_sleep(monkeypatch) -> list[float]:
    """Acelera o asyncio.sleep do módulo bot; retorna os delays registrados."""
    real_sleep = asyncio.sleep
    delays: list[float] = []

    async def fast_sleep(d):
        delays.append(d)
        await real_sleep(0)

    monkeypatch.setattr("crias_bot.bot.asyncio.sleep", fast_sleep)
    return delays


# ---------------------------------------------------------------------------
# EXP-61: sanitização e formatação de chunks.
# ---------------------------------------------------------------------------


class TestSanitizeConsoleText:
    def test_neutralizes_triple_backticks(self):
        out = _sanitize_console_text("user wrote ```python\nprint('hi')\n``` lol")
        assert "```" not in out
        # backtick + zero-width space + dois backticks
        assert "`\u200b``" in out

    def test_neutralizes_runs_of_four_or_more(self):
        """str.replace simples deixaria um ``` trailing em runs de 4+."""
        for run in ("````", "`````", "``````"):
            out = _sanitize_console_text(run)
            assert "```" not in out, f"run {run!r} não neutralizada: {out!r}"

    def test_double_backtick_unchanged(self):
        assert _sanitize_console_text("`inline` ``code``") == "`inline` ``code``"

    def test_plain_log_line_unchanged(self):
        line = "[12:34:56] [Server thread/INFO]: Steve joined the game"
        assert _sanitize_console_text(line) == line


class TestFormatConsoleChunk:
    def test_wraps_in_code_fence(self):
        assert _format_console_chunk("hello") == "```\nhello\n```"

    def test_truncates_overlimit_payload(self):
        payload = _format_console_chunk("x" * 5000)
        assert len(payload) <= 2000
        assert payload.startswith("```\n") and payload.endswith("\n```")

    def test_backticks_survive_truncation_without_breaking_fence(self):
        line = "a```" * 600  # 2400 chars, muitos fences
        payload = _format_console_chunk(line)
        assert len(payload) <= 2000
        # Exatamente as duas cercas do payload — nenhuma ``` crua no conteúdo.
        assert payload.count("```") == 2

    def test_mentions_are_not_the_sanitizers_job(self):
        """@everyone permanece no texto (log fiel); quem desativa o ping é o
        allowed_mentions no envio (ver TestSendConsoleBuffer)."""
        payload = _format_console_chunk("@everyone hello")
        assert "@everyone" in payload


class TestSendConsoleBuffer:
    async def test_sanitizes_and_disables_mentions(self):
        """EXP-61: chunk com ``` e @everyone — sem ``` crua fora das cercas e
        allowed_mentions desativado no send."""
        channel = _make_channel()
        buffer = [
            "Steve said: ```drop table```",
            "@everyone join my server",
            "mods: @here",
        ]

        status = await _send_console_buffer(channel, buffer)

        assert status == _FLUSH_OK
        channel.send.assert_awaited_once()
        call = channel.send.call_args
        content = call.args[0]
        # As cercas do payload são as ÚNICAS ocorrências de ```.
        assert content.count("```") == 2
        assert content.startswith("```\n") and content.endswith("\n```")
        # Menções ficam no texto (log fiel), mas sem poder de ping.
        assert "@everyone" in content
        am = call.kwargs["allowed_mentions"]
        assert isinstance(am, discord.AllowedMentions)
        assert am.everyone is False
        assert not am.users and not am.roles and am.replied_user is False
        # Dentro do limite do Discord.
        assert len(content) <= 2000

    async def test_buffer_not_modified_on_success(self):
        channel = _make_channel()
        buffer = ["line1", "line2"]
        await _send_console_buffer(channel, buffer)
        assert buffer == ["line1", "line2"]

    async def test_retry_on_http_exception(self):
        channel = _make_channel()
        channel.send = AsyncMock(side_effect=discord.HTTPException(MagicMock(status=500), "boom"))
        assert await _send_console_buffer(channel, ["line"]) == _FLUSH_RETRY

    async def test_stop_on_not_found(self):
        channel = _make_channel()
        channel.send = AsyncMock(side_effect=discord.NotFound(MagicMock(status=404), "gone"))
        assert await _send_console_buffer(channel, ["line"]) == _FLUSH_STOP

    async def test_empty_buffer_is_noop(self):
        channel = _make_channel()
        assert await _send_console_buffer(channel, []) == _FLUSH_OK
        channel.send.assert_not_awaited()


# ---------------------------------------------------------------------------
# EXP-47: reopen com backoff no _console_stream_loop.
# ---------------------------------------------------------------------------


class TestConsoleStreamLoop:
    async def test_reconnects_after_deadline_marker(self, monkeypatch):
        """Deadline do agente (marker) → reopen transparente, sem replay do
        histórico de 50 linhas e sem vazar o marker no output."""
        _fast_sleep(monkeypatch)
        agent = FakeAgent(
            [
                ["line1", _CONSOLE_DEADLINE_MARKER],  # stream 1: EOF no deadline
                ["line2"],  # stream 2 (reopen)
                # tentativa 3: None → stream eterna (cancelamos depois)
            ]
        )
        bot = _make_bot(agent)
        cog = MinecraftCog(bot)
        channel = _make_channel()

        task = asyncio.create_task(cog._console_stream_loop(channel))
        bot._console_task = task

        # Espera a 3ª tentativa (reopen pós-stream-2) começar.
        real_sleep = asyncio.sleep
        deadline = time.monotonic() + 5
        while len(agent.calls) < 3 and time.monotonic() < deadline:
            await real_sleep(0.01)
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

        # Primeira stream: tail 50; reopens: tail 1 (sem replay do histórico).
        assert agent.calls[0] == 50
        assert agent.calls[1] == 1
        assert agent.calls[2] == 1
        # line1 e line2 foram postadas (flush entre tentativas); marker nunca.
        sent = [c.args[0] for c in channel.send.call_args_list]
        assert sent == ["```\nline1\n```", "```\nline2\n```"]
        # EXP-61: envios com menções desativadas.
        for c in channel.send.call_args_list:
            assert c.kwargs["allowed_mentions"].everyone is False
        # Estado limpo após cancelamento.
        assert bot._console_stream_active is False
        assert bot._console_task is None

    async def test_gives_up_after_consecutive_reconnect_failures(self, monkeypatch):
        """Agente sempre offline → 5 tentativas com backoff 1,2,4,8 → aviso
        visível de fim de sessão."""
        delays = _fast_sleep(monkeypatch)
        agent = FakeAgent([AgentClientError("agent down")] * 10)
        bot = _make_bot(agent)
        cog = MinecraftCog(bot)
        bot._console_task = asyncio.current_task()
        channel = _make_channel()

        await cog._console_stream_loop(channel)  # termina sozinho (desiste)

        # 5 tentativas = _CONSOLE_MAX_RECONNECT_FAILURES.
        assert len(agent.calls) == 5
        # Backoff exponencial entre tentativas (a 5ª desiste sem dormir).
        assert delays == [1.0, 2.0, 4.0, 8.0]
        # Aviso visível no canal de console.
        channel.send.assert_awaited_once()
        embed = channel.send.call_args.kwargs["embed"]
        assert "Stream de console parou" in embed.title
        # Estado limpo.
        assert bot._console_stream_active is False
        assert bot._console_task is None

    async def test_healthy_reopen_resets_backoff_and_failures(self, monkeypatch):
        """Um reopen saudável (marker) zera o contador de falhas e o backoff:
        a falha seguinte dorme 1.0s (não continua o backoff dobrado) e são
        necessárias 5 falhas CONSECUTIVAS para desistir."""
        delays = _fast_sleep(monkeypatch)
        agent = FakeAgent(
            [
                AgentClientError("boom"),  # falha 1 → sleep 1.0, delay vira 2.0
                [_CONSOLE_DEADLINE_MARKER],  # saudável → reset (delay=1.0, falhas=0)
                AgentClientError("boom"),  # falha 1 (de novo) → sleep 1.0 ← prova o reset
                AgentClientError("boom"),  # falha 2 → sleep 2.0
                AgentClientError("boom"),  # falha 3 → sleep 4.0
                AgentClientError("boom"),  # falha 4 → sleep 8.0
                AgentClientError("boom"),  # falha 5 → desiste (sem sleep)
            ]
        )
        bot = _make_bot(agent)
        cog = MinecraftCog(bot)
        bot._console_task = asyncio.current_task()
        channel = _make_channel()

        await cog._console_stream_loop(channel)

        # 7 tentativas: 1 falha + 1 saudável + 5 falhas consecutivas.
        assert len(agent.calls) == 7
        # Delays: falha(1.0) | saudável(1.0) | falhas: 1.0, 2.0, 4.0, 8.0.
        assert delays == [1.0, 1.0, 1.0, 2.0, 4.0, 8.0]
        assert bot._console_stream_active is False

    async def test_stops_when_session_disabled_mid_stream(self, monkeypatch):
        """Usuário roda /mc console (stop) durante o stream → sem reopen."""
        agent = FakeAgent(
            [
                [
                    "line1",
                    lambda: setattr(bot, "_console_stream_active", False),
                ]
            ]
        )
        bot = _make_bot(agent)
        cog = MinecraftCog(bot)
        channel = _make_channel()

        task = asyncio.create_task(cog._console_stream_loop(channel))
        bot._console_task = task
        await task  # termina sozinho após o EOF da tentativa 1

        # Uma única tentativa — não houve reopen.
        assert agent.calls == [50]
        # Buffer pendente não é postado após o stop (mesma semântica do cancel).
        channel.send.assert_not_awaited()
        assert bot._console_stream_active is False
        assert bot._console_task is None

    async def test_stops_after_consecutive_send_failures(self):
        """Falhas de envio ao Discord (canal vivo mas HTTP 5xx) → 5 tentativas
        e parada com notificação (comportamento preservado do código antigo)."""
        agent = FakeAgent([["x" * 2000] * 10])  # linhas longas forçam flush
        bot = _make_bot(agent)
        cog = MinecraftCog(bot)
        bot._console_task = asyncio.current_task()
        channel = _make_channel()
        channel.send = AsyncMock(side_effect=discord.HTTPException(MagicMock(status=500), "boom"))

        await cog._console_stream_loop(channel)

        assert channel.send.await_count == 5  # _CONSOLE_MAX_SEND_FAILURES
        assert bot._console_stream_active is False
        assert bot._console_task is None
