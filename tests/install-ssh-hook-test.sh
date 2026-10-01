#!/usr/bin/env bash
# tests/install-ssh-hook-test.sh
#
# Valida a função install_ssh_if_enabled() do install.sh (v1.2.0, revisada em F7).
#
# Como essa função faz useradd, chpasswd, systemctl (start sshd), não podemos
# rodá-la em CI sem Arch real. Em vez disso, fazemos asserções STATIC:
#   1. A função existe e é chamada em main()
#   2. INSTALL_SSH é tratada em config-parser.sh (overridable vars)
#   3. O usuário criado é 'crias' (não-hardcoded como login user do host,
#      mas hardcoded como o user do SSH — intencional, documentado)
#   4. sudoers drop-in em /etc/sudoers.d/crias-wheel com %wheel ALL=(ALL) ALL
#   5. sshd drop-in em /etc/ssh/sshd_config.d/10-crias.conf com PermitRootLogin no
#   6. Hardening: systemctl enable + restart sshd
#   7. DRY_RUN pula a função
#   8. NON_INTERACTIVE com INSTALL_SSH vazio -> false (não pergunga)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

# 1. Função existe e é chamada em main()
assert_grep '^install_ssh_if_enabled\(\)' "$ROOT_DIR/install.sh"
assert_grep 'install_ssh_if_enabled' "$ROOT_DIR/install.sh"

# 2. INSTALL_SSH declarada em config.env e tratada em config-parser.sh
assert_grep '^INSTALL_SSH=' "$ROOT_DIR/config.env"
assert_grep 'INSTALL_SSH' "$ROOT_DIR/shared/lib/config-parser.sh"

# 3. Usuário 'crias' hardcoded como ssh_user (intencional: é o usuário de
# acesso SSH, NÃO o login user do host que vem do archinstall)
assert_grep 'local ssh_user="crias"' "$ROOT_DIR/install.sh"

# 4. sudoers drop-in em /etc/sudoers.d/crias-wheel com %wheel ALL=(ALL) ALL
assert_grep '/etc/sudoers.d/crias-wheel' "$ROOT_DIR/install.sh"
# Literal match: printf '%%wheel ALL=(ALL) ALL' (%% é escape printf para %)
assert_grep_fixed '%%wheel ALL=(ALL) ALL' "$ROOT_DIR/install.sh"
# visudo -cf valida o sudoers antes de instalar
assert_grep 'visudo -cf' "$ROOT_DIR/install.sh"

# 5. sshd drop-in em /etc/ssh/sshd_config.d/10-crias.conf
assert_grep '/etc/ssh/sshd_config.d/10-crias.conf' "$ROOT_DIR/install.sh"
assert_grep 'PermitRootLogin no' "$ROOT_DIR/install.sh"
assert_grep 'PasswordAuthentication yes' "$ROOT_DIR/install.sh"
assert_grep 'PubkeyAuthentication yes' "$ROOT_DIR/install.sh"

# 6. useradd -m -s /bin/bash (cria home + bash shell) + chpasswd (set password) + usermod -aG wheel
assert_grep 'useradd -m -s /bin/bash' "$ROOT_DIR/install.sh"
assert_grep 'chpasswd' "$ROOT_DIR/install.sh"
assert_grep 'usermod -aG wheel' "$ROOT_DIR/install.sh"

# 7. systemctl enable + restart sshd
assert_grep 'systemctl enable sshd' "$ROOT_DIR/install.sh"
assert_grep 'systemctl restart sshd' "$ROOT_DIR/install.sh"

# 8. DRY_RUN pula a função (não faz useradd/systemctl) — literal match
assert_grep_fixed '[DRY_RUN] Pulando configuracao de SSH' "$ROOT_DIR/install.sh"

# 9. NON_INTERACTIVE com INSTALL_SSH vazio -> false (não fica travando em prompt)
#    A função tem: if is_true "$NON_INTERACTIVE"; then INSTALL_SSH="false"
assert_grep 'is_true.*NON_INTERACTIVE' "$ROOT_DIR/install.sh"

# 10. Senha pedida interativamente com read -s (sem echo) + confirmação
assert_grep 'read.*-r.*-s' "$ROOT_DIR/install.sh"

# 11. Suporte a override via INSTALL_SSH=true documentado no README
assert_grep 'INSTALL_SSH=true' "$ROOT_DIR/README.md"

echo "OK: install-ssh-hook-test"
