"""Tests para bot.py helpers (_partition_lines, _format_uptime).

Estes testes validam apenas funções puras (sem side-effects Discord/gRPC).
Para rodar: `pytest tests/test_bot_helpers.py -v`
"""

from __future__ import annotations

# Importa o módulo bot.py (pode falhar se discord.py não instalado).
# Esses testes validam apenas funções puras, não precisam do discord.py real.
try:
    from crias_bot.bot import _format_uptime, _partition_lines
except ImportError:
    import pytest

    pytest.skip("discord.py não instalado; teste de bot.py pulado", allow_module_level=True)


class TestPartitionLines:
    def test_empty(self):
        assert _partition_lines([], 100) == []

    def test_single_line_fits(self):
        result = _partition_lines(["hello"], 100)
        assert result == ["hello"]

    def test_multiple_lines_fit(self):
        result = _partition_lines(["a", "b", "c"], 100)
        assert result == ["a\nb\nc"]

    def test_split_when_exceeds_max(self):
        # 3 linhas de 50 chars cada = 153 chars total; max 100 = deve quebrar
        lines = ["x" * 50, "y" * 50, "z" * 50]
        result = _partition_lines(lines, 100)
        assert len(result) >= 2
        # Cada chunk deve ter <= 100 chars
        for chunk in result:
            assert len(chunk) <= 100

    def test_line_larger_than_max(self):
        # Uma linha maior que max_chars deve ir sozinha no chunk (não pode ser dividida)
        big_line = "x" * 200
        result = _partition_lines([big_line, "short"], 100)
        # primeiro chunk é a linha grande (sozinha), segundo é "short"
        assert len(result) == 2
        assert result[0] == big_line
        assert result[1] == "short"

    def test_discord_safe_size(self):
        # Simula buffer de 50 linhas de log (média 80 chars cada = 4000 chars total)
        # com max_chars=1800 (limite seguro do Discord com codeblock).
        lines = [
            f"[12:34:56] [Server thread/INFO]: log line {i:03d} with some padding"
            for i in range(50)
        ]
        result = _partition_lines(lines, 1800)
        # Deve ter particionado em pelo menos 2 chunks
        assert len(result) >= 2
        # E cada chunk deve caber em mensagem do Discord (2000 chars - 7 para ```\n...\n```)
        for chunk in result:
            assert len(chunk) <= 1800

    def test_preserves_order(self):
        lines = ["line1", "line2", "line3", "line4"]
        result = _partition_lines(lines, 100)
        full = "\n".join(result)
        # Todas as linhas devem aparecer na ordem original
        assert "line1" in full
        assert "line2" in full
        assert "line3" in full
        assert "line4" in full
        assert full.index("line1") < full.index("line2") < full.index("line3") < full.index("line4")


class TestFormatUptime:
    def test_seconds(self):
        assert _format_uptime(30) == "30s"

    def test_minutes(self):
        assert _format_uptime(120) == "2m"

    def test_hours(self):
        assert _format_uptime(3600) == "1h 0m"
        assert _format_uptime(5400) == "1h 30m"

    def test_days(self):
        assert _format_uptime(86400) == "1d 0h"
        assert _format_uptime(90000) == "1d 1h"

    def test_zero(self):
        assert _format_uptime(0) == "0s"
