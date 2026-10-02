#!/usr/bin/env bash
# tests/install-monitor-hook-test.sh
#
# Valida a função install_monitor_tools_if_enabled() do install.sh (v1.3.0 / F5).
# Adicionada em F7 para cobrir a nova função de integração de ferramentas.
#
# Como a função faz pacman -S (precisa de root + rede), fazemos asserções STATIC:
#   1. A função existe e é chamada em main()
#   2. INSTALL_MONITOR_TOOLS tratada em config-parser.sh (overridable vars)
#   3. pacman -S btop ncdu (os pacotes que instala)
#   4. DRY_RUN pula
#   5. NON_INTERACTIVE sem flag -> skip (não pergunga)
#   6. Subcomando 'monitor' referenciado (integração com managers)
#   8. manager_cmd_monitor existe em manager-common.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

# 1. Função existe e é chamada em main()
assert_grep '^install_monitor_tools_if_enabled\(\)' "$ROOT_DIR/install.sh"
assert_grep 'install_monitor_tools_if_enabled' "$ROOT_DIR/install.sh"

# 2. INSTALL_MONITOR_TOOLS em config.env + config-parser.sh
assert_grep '^INSTALL_MONITOR_TOOLS=' "$ROOT_DIR/config.env"
assert_grep 'INSTALL_MONITOR_TOOLS' "$ROOT_DIR/shared/lib/config-parser.sh"

# 3. pacman -S --needed --noconfirm btop ncdu (instala as ferramentas)
assert_grep 'pacman -S --needed --noconfirm btop ncdu' "$ROOT_DIR/install.sh"

# 4. DRY_RUN pula a função — pattern ESPECÍFICO do monitor (não broad
#    '[DRY_RUN] Pulando' que match em outras 5 funções). Mutation test M61.
assert_grep_fixed '[DRY_RUN] Pulando instalação de ferramentas de monitoramento' "$ROOT_DIR/install.sh"

# 5. NON_INTERACTIVE sem INSTALL_MONITOR_TOOLS=true -> skip (não trava em prompt)
#    A função tem: if is_true "$NON_INTERACTIVE"; then return 0
assert_grep 'is_true.*NON_INTERACTIVE' "$ROOT_DIR/install.sh"

# 6. Subcomando 'monitor' referenciado no install.sh (dica ao usuário)
assert_grep 'monitor \[cpu|disk|net\]' "$ROOT_DIR/install.sh"


# 8. manager_cmd_monitor + cmd_monitor (shared wrapper) em manager-common.sh
assert_grep '^manager_cmd_monitor\(\)' "$ROOT_DIR/shared/lib/manager-common.sh"
assert_grep '^cmd_monitor()' "$ROOT_DIR/shared/lib/manager-common.sh"

# 9. 'monitor' no case dispatch compartilhado (manager_dispatch em manager-common.sh)
assert_grep 'monitor) shift; cmd_monitor' "$ROOT_DIR/shared/lib/manager-common.sh"

# 10. Ambos managers chamam manager_dispatch (que tem o dispatch compartilhado)
assert_grep 'manager_dispatch "\$@"' "$ROOT_DIR/minecraft/mc-manager.sh"
assert_grep 'manager_dispatch "\$@"' "$ROOT_DIR/terraria/tt-manager.sh"

# 11. tui_help "monitor" existe em tui.sh (mini-wiki documenta o subcomando)
assert_grep 'monitor)' "$ROOT_DIR/shared/lib/tui.sh"

# 12. Fallback lógica: btop -> htop (no manager_cmd_monitor) — ORDEM importa:
#     btop DEVE aparecer antes de htop (btop é preferido). Mutation test M40.
assert_grep 'command -v btop' "$ROOT_DIR/shared/lib/manager-common.sh"
assert_grep 'command -v htop' "$ROOT_DIR/shared/lib/manager-common.sh"
assert_grep 'command -v ncdu' "$ROOT_DIR/shared/lib/manager-common.sh"
# Valida ORDEM: btop antes de htop (grep -n pega line numbers, btop < htop).
btop_ln=$(grep -n 'command -v btop' "$ROOT_DIR/shared/lib/manager-common.sh" | head -1 | cut -d: -f1)
htop_ln=$(grep -n 'command -v htop' "$ROOT_DIR/shared/lib/manager-common.sh" | head -1 | cut -d: -f1)
if [ -n "$btop_ln" ] && [ -n "$htop_ln" ] && [ "$btop_ln" -lt "$htop_ln" ]; then
    echo "  OK: btop (linha $btop_ln) antes de htop (linha $htop_ln) — ordem correta"
else
    echo "FAIL: btop deve aparecer antes de htop em manager-common.sh" >&2
    exit 1
fi

echo "OK: install-monitor-hook-test"
