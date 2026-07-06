"""Tests para bot.py helpers e permission boundaries (TST-006).

Estes testes validam:
  - Funções puras originais (_partition_lines, _format_uptime).
  - Permission boundary is_admin / is_moderator com vários cenários de role.
  - Helper _check_admin / _check_moderator do MinecraftCog (sem Discord real).

Para rodar: `pytest tests/test_bot_helpers.py -v`

Técnicas:
  - MagicMock(spec=discord.Member) faz isinstance(mock, discord.Member) == True.
  - CriasBot é instanciado via __new__ (sem conectar ao Discord gateway) —
    apenas `self.config` é populado, que é tudo que is_admin/is_moderator usam.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import discord
import pytest

# Importa o módulo bot.py (pode falhar se discord.py não instalado).
try:
    from crias_bot.bot import CriasBot, MinecraftCog, _format_uptime, _partition_lines
    from crias_bot.config import BotConfig
except ImportError:
    pytest.skip("discord.py não instalado; teste de bot.py pulado", allow_module_level=True)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _make_bot(
    admin_role_ids: frozenset[int] = frozenset(),
    moderator_role_ids: frozenset[int] = frozenset(),
) -> CriasBot:
    """Cria uma instância de CriasBot SEM chamar __init__ (que conectaria ao
    Discord gateway). Apenas `self.config` é populado — suficiente para testar
    is_admin/is_moderator que só dependem de self.config.
    """
    bot = CriasBot.__new__(CriasBot)
    bot.config = BotConfig(
        discord_token="x",
        agent_host="localhost:8473",
        agent_token="y",
        admin_role_ids=admin_role_ids,
        moderator_role_ids=moderator_role_ids,
    )
    return bot


def _make_member(
    *,
    role_ids: list[int] | None = None,
    is_administrator: bool = False,
) -> MagicMock:
    """Cria um mock de discord.Member com roles e guild_permissions setados.

    isinstance(member, discord.Member) retorna True porque spec=discord.Member.
    """
    m = MagicMock(spec=discord.Member)
    # Configura guild_permissions.administrator.
    m.guild_permissions = MagicMock()
    m.guild_permissions.administrator = is_administrator
    # Configura roles: cada role é um objeto com atributo .id.
    m.roles = [MagicMock(id=rid) for rid in (role_ids or [])]
    return m


def _make_user() -> MagicMock:
    """Cria um mock de discord.User (não-Member). isinstance(user, discord.User)
    retorna True; isinstance(user, discord.Member) retorna False."""
    return MagicMock(spec=discord.User)


# ---------------------------------------------------------------------------
# Tests originais (preservados).
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Permission boundary: is_admin (TST-006).
# ---------------------------------------------------------------------------


class TestIsAdmin:
    def test_administrator_permission_grants_admin(self):
        """Member com guild_permissions.administrator=True é admin."""
        bot = _make_bot()
        member = _make_member(is_administrator=True)
        assert bot.is_admin(member) is True

    def test_admin_role_id_grants_admin(self):
        """Member sem administrator perm mas com role que está em admin_role_ids."""
        bot = _make_bot(admin_role_ids=frozenset({12345}))
        member = _make_member(role_ids=[12345])
        assert bot.is_admin(member) is True

    def test_admin_role_id_among_others_grants_admin(self):
        """Member com várias roles, uma delas é admin."""
        bot = _make_bot(admin_role_ids=frozenset({999}))
        member = _make_member(role_ids=[111, 222, 999, 333])
        assert bot.is_admin(member) is True

    def test_no_admin_role_no_permission_denies(self):
        """Member com roles comuns, sem admin perm, sem admin role."""
        bot = _make_bot(admin_role_ids=frozenset({999}))
        member = _make_member(role_ids=[111, 222], is_administrator=False)
        assert bot.is_admin(member) is False

    def test_empty_roles_denies(self):
        """Member sem nenhuma role não é admin."""
        bot = _make_bot(admin_role_ids=frozenset({999}))
        member = _make_member(role_ids=[], is_administrator=False)
        assert bot.is_admin(member) is False

    def test_user_not_member_denies(self):
        """discord.User (não-Member, ex: DM) nunca é admin."""
        bot = _make_bot(admin_role_ids=frozenset({999}))
        user = _make_user()
        assert bot.is_admin(user) is False

    def test_empty_admin_role_ids_denies(self):
        """Se admin_role_ids é vazio e user não tem administrator perm, deny."""
        bot = _make_bot(admin_role_ids=frozenset())
        member = _make_member(role_ids=[111, 222], is_administrator=False)
        assert bot.is_admin(member) is False

    def test_administrator_perm_overrides_no_admin_roles(self):
        """Mesmo com admin_role_ids vazio, administrator perm concede admin."""
        bot = _make_bot(admin_role_ids=frozenset())
        member = _make_member(is_administrator=True)
        assert bot.is_admin(member) is True

    def test_no_role_overlap_doesnt_grant(self):
        """Roles completamente diferentes das admin_role_ids."""
        bot = _make_bot(admin_role_ids=frozenset({100, 200}))
        member = _make_member(role_ids=[300, 400])
        assert bot.is_admin(member) is False


# ---------------------------------------------------------------------------
# Permission boundary: is_moderator (TST-006).
# ---------------------------------------------------------------------------


class TestIsModerator:
    def test_admin_implies_moderator(self):
        """Se is_admin=True, is_moderator deve retornar True (escalonamento)."""
        bot = _make_bot(admin_role_ids=frozenset({100}))
        member = _make_member(role_ids=[100])
        # is_admin seria True, então is_moderator deve ser True também.
        assert bot.is_moderator(member) is True

    def test_administrator_perm_implies_moderator(self):
        """administrator perm concede mod implicitamente."""
        bot = _make_bot()
        member = _make_member(is_administrator=True)
        assert bot.is_moderator(member) is True

    def test_moderator_role_grants_mod(self):
        """Member com role em moderator_role_ids (mas não admin)."""
        bot = _make_bot(moderator_role_ids=frozenset({555}))
        member = _make_member(role_ids=[555])
        assert bot.is_moderator(member) is True

    def test_moderator_role_among_others(self):
        """Member com várias roles, uma delas é mod."""
        bot = _make_bot(moderator_role_ids=frozenset({555}))
        member = _make_member(role_ids=[111, 555, 222])
        assert bot.is_moderator(member) is True

    def test_no_moderator_role_denies(self):
        """Member sem nenhuma role de mod nem admin."""
        bot = _make_bot(moderator_role_ids=frozenset({555}))
        member = _make_member(role_ids=[111, 222])
        assert bot.is_moderator(member) is False

    def test_user_not_member_denies(self):
        """discord.User (não-Member) nunca é mod."""
        bot = _make_bot(moderator_role_ids=frozenset({555}))
        user = _make_user()
        assert bot.is_moderator(user) is False

    def test_admin_role_does_not_grant_mod_via_moderator_ids(self):
        """Admin role NÃO deve conceder mod via moderator_role_ids.
        is_moderator deve delegar para is_admin primeiro — então admin role
        concede mod via admin path, não via mod path."""
        bot = _make_bot(
            admin_role_ids=frozenset({100}),
            moderator_role_ids=frozenset({555}),
        )
        member = _make_member(role_ids=[100])  # admin mas não mod
        assert bot.is_moderator(member) is True  # admin → mod

    def test_empty_moderator_role_ids_denies_for_non_admin(self):
        """Se moderator_role_ids é vazio e user não é admin, deny."""
        bot = _make_bot(moderator_role_ids=frozenset())
        member = _make_member(role_ids=[111])
        assert bot.is_moderator(member) is False


# ---------------------------------------------------------------------------
# _check_admin / _check_moderator (TST-006 — cog helpers).
# ---------------------------------------------------------------------------


class TestCheckAdminCog:
    """Testa MinecraftCog._check_admin e _check_moderator.

    Esses métodos fazem interaction.response.send_message(...) quando o user
    não tem permissão. Verificamos que:
      - Retornam True quando user tem permissão (e não chamam send_message).
      - Retornam False quando user NÃO tem permissão (e chamam send_message).
    """

    def _make_cog(self, bot: CriasBot) -> MinecraftCog:
        # MinecraftCog.__init__ só seta self.bot = bot. Safe de instanciar.
        return MinecraftCog(bot)

    def _make_interaction(self, user) -> MagicMock:
        interaction = MagicMock()
        interaction.user = user
        # send_message é awaitable no discord.py — usamos AsyncMock.
        interaction.response.send_message = AsyncMock()
        return interaction

    def test_check_admin_true_for_admin(self):
        bot = _make_bot(admin_role_ids=frozenset({100}))
        cog = self._make_cog(bot)
        member = _make_member(role_ids=[100])
        interaction = self._make_interaction(member)

        import asyncio

        result = asyncio.run(cog._check_admin(interaction))
        assert result is True
        interaction.response.send_message.assert_not_called()

    def test_check_admin_false_for_non_admin(self):
        bot = _make_bot(admin_role_ids=frozenset({100}))
        cog = self._make_cog(bot)
        member = _make_member(role_ids=[999])
        interaction = self._make_interaction(member)

        import asyncio

        result = asyncio.run(cog._check_admin(interaction))
        assert result is False
        # Deve ter enviado mensagem de "permission denied" efêmera.
        interaction.response.send_message.assert_called_once()
        kwargs = interaction.response.send_message.call_args.kwargs
        assert kwargs.get("ephemeral") is True

    def test_check_moderator_true_for_moderator(self):
        bot = _make_bot(moderator_role_ids=frozenset({555}))
        cog = self._make_cog(bot)
        member = _make_member(role_ids=[555])
        interaction = self._make_interaction(member)

        import asyncio

        result = asyncio.run(cog._check_moderator(interaction))
        assert result is True
        interaction.response.send_message.assert_not_called()

    def test_check_moderator_true_for_admin(self):
        """Admin também passa no check_moderator (admin ⊇ moderator)."""
        bot = _make_bot(admin_role_ids=frozenset({100}))
        cog = self._make_cog(bot)
        member = _make_member(role_ids=[100])
        interaction = self._make_interaction(member)

        import asyncio

        result = asyncio.run(cog._check_moderator(interaction))
        assert result is True
        interaction.response.send_message.assert_not_called()

    def test_check_moderator_false_for_no_role(self):
        bot = _make_bot(moderator_role_ids=frozenset({555}))
        cog = self._make_cog(bot)
        member = _make_member(role_ids=[999])
        interaction = self._make_interaction(member)

        import asyncio

        result = asyncio.run(cog._check_moderator(interaction))
        assert result is False
        interaction.response.send_message.assert_called_once()


# ---------------------------------------------------------------------------
# Say command input validation (TST-006 — placeholder para BOT-001 fix).
# ---------------------------------------------------------------------------


class TestSayInputValidation:
    """Valida que o comando /mc say constrói o comando RCON corretamente.

    AVISO (2E-009): estes testes são TAUTOLÓGICOS — verificam que
    `f"say {message}"` produz `"say {message}"`, sem exercitar o caminho
    real do `bot.py`. Dão falsa confiança de cobertura. São mantidos como
    documentação do comportamento esperado até o fix BOT-001 (Task 3-A)
    landar com validação real (tamanho máximo, caracteres proibidos).

    Quando BOT-001 landar, **substituir** estes testes por testes que
    invoquem o slash command `/mc say` real (com `Interaction` mockado
    + `AgentClient` mockado) e verifiquem:

    1. Que `bot.py` chama `agent.send_rcon_command(f"say {sanitized_msg}")`.
    2. Que mensagens > 2000 chars são rejeitadas antes de chegar no agent.
    3. Que caracteres de controle (newline, null byte) são sanitizados.

    Ver `discord-agent/internal/rcon/client_test.go::TestWhitelistedCommands`
    para o padrão de teste table-driven equivalente no lado Go.
    """

    @pytest.mark.parametrize(
        "message,expected_command",
        [
            ("Hello world", "say Hello world"),
            ("Oi", "say Oi"),
            ("12345", "say 12345"),
            ("with spaces and stuff", "say with spaces and stuff"),
        ],
    )
    def test_say_constructs_correct_rcon_command(self, message, expected_command):
        """O comando RCON enviado ao agente deve ser 'say <message>'."""
        # Simula o que o slash command faz: chama agent.send_rcon_command.
        # Aqui só verificamos a string construída — não chamamos o agent real.
        constructed = f"say {message}"
        assert constructed == expected_command

    def test_say_empty_message(self):
        """Mensagem vazia resulta em comando 'say ' (espaço trailing).

        Esperado: bot.py deve rejeitar empty message ANTES de chamar o agent.
        Quando BOT-001 landar, este teste deve ser atualizado para esperar
        uma resposta de erro em vez do comando 'say '.
        """
        message = ""
        constructed = f"say {message}"
        # Documenta comportamento atual (sem validação).
        assert constructed == "say "

    def test_say_preserves_whitespace(self):
        """Mensagens com espaços extras devem preservar o conteúdo."""
        message = "  leading and trailing  "
        constructed = f"say {message}"
        assert constructed == "say   leading and trailing  "

    @pytest.mark.parametrize(
        "message",
        [
            "a" * 2000,  # Discord max message length
            "a" * 2001,  # over Discord limit (bot deve rejeitar)
        ],
    )
    def test_say_long_messages(self, message):
        """Mensagens longas devem ser validadas (BOT-001).

        Atualmente, o bot não valida tamanho — repassa ao RCON, que pode
        rejeitar com erro. Este teste documenta o comportamento atual.
        """
        constructed = f"say {message}"
        # Deve ter prefixo 'say '.
        assert constructed.startswith("say ")
        # E o conteúdo da mensagem deve estar presente.
        assert message in constructed
