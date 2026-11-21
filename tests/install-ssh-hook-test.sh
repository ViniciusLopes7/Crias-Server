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
#   4. sudoers individual apenas para conta criada; politicas existentes preservadas
#   5. sshd drop-in em /etc/ssh/sshd_config.d/10-crias.conf com PermitRootLogin no
#   6. Hardening: systemctl enable + restart sshd
#   7. DRY_RUN pula a função
#   8. NON_INTERACTIVE com INSTALL_SSH vazio -> false (nao pergunta)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

# 1. Função existe e é chamada em main()
assert_grep '^install_ssh_if_enabled\(\)' "$ROOT_DIR/install.sh"
assert_grep 'install_ssh_if_enabled' "$ROOT_DIR/install.sh"
# Acesso remoto deve ficar disponivel ANTES do instalador do jogo.
line_ssh="$(grep -n '^    install_ssh_if_enabled$' "$ROOT_DIR/install.sh" | cut -d: -f1)"
line_stack="$(grep -n '^    run_selected_stack_installer$' "$ROOT_DIR/install.sh" | cut -d: -f1)"
[ -n "$line_ssh" ] && [ "$line_ssh" -lt "$line_stack" ] || { echo 'FAIL: SSH executado depois do jogo' >&2; exit 1; }
assert_grep 'configure_tailscale_login_if_enabled' "$ROOT_DIR/install.sh"
# O OpenSSH precisa ser instalado antes de iniciar a etapa de Tailscale.
line_tailscale="$(grep -n '^    install_tailscale_if_enabled

# 2. INSTALL_SSH declarada em config.env e tratada em config-parser.sh
assert_grep '^INSTALL_SSH=' "$ROOT_DIR/config.env"
assert_grep 'INSTALL_SSH' "$ROOT_DIR/shared/lib/config-parser.sh"

# 3. SSH username configurável (SSH_USER em config.env, default "crias")
# acesso SSH, NÃO o login user do host que vem do archinstall)
assert_grep 'SSH_USER:-crias' "$ROOT_DIR/install.sh"

# 4. Conta SSH ja existente nao pode perder NOPASSWD por regra global
assert_grep_fixed '/etc/sudoers.d/90-crias-${ssh_user}' "$ROOT_DIR/install.sh"
assert_grep_fixed 'ssh_user_created' "$ROOT_DIR/install.sh"
assert_grep_fixed 'Usuario '\''$ssh_user'\'' existente: nenhuma regra sudo alterada' "$ROOT_DIR/install.sh"
assert_grep 'visudo -cf' "$ROOT_DIR/install.sh"
# A politica legada pode ser detectada para alertas, mas NUNCA recriada.
if grep -Fq "printf '%%wheel ALL=(ALL) ALL" "$ROOT_DIR/install.sh"; then
    echo "FAIL: regra sudo global wheel reintroduzida" >&2
    exit 1
fi

# 5. sshd drop-in em /etc/ssh/sshd_config.d/10-crias.conf
assert_grep '/etc/ssh/sshd_config.d/10-crias.conf' "$ROOT_DIR/install.sh"
assert_grep 'PermitRootLogin no' "$ROOT_DIR/install.sh"
# (EXP-65) O drop-in agora PRESERVA a politica de senha do host: a linha
# usa a variavel $password_auth (yes quando o host permite, no quando o
# admin desativou senha). O contrato e a logica, nao o literal.
assert_grep 'PasswordAuthentication \$password_auth' "$ROOT_DIR/install.sh"
assert_grep 'sshd -T' "$ROOT_DIR/install.sh"
assert_grep 'sshd -t' "$ROOT_DIR/install.sh"
assert_grep 'ssh-keygen -A' "$ROOT_DIR/install.sh"
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

# 11. SSH documentado no tutorial
assert_grep 'SSH_USER' "$ROOT_DIR/docs/tutorial.md"

echo "OK: install-ssh-hook-test"
 "$ROOT_DIR/install.sh" | cut -d: -f1)"
[ -n "$line_tailscale" ] && [ "$line_ssh" -lt "$line_tailscale" ] || {
    echo 'FAIL: OpenSSH instalado depois do Tailscale' >&2; exit 1;
}
assert_grep "systemctl is-active --quiet sshd.service" "$ROOT_DIR/install.sh"
assert_grep "sport = :22" "$ROOT_DIR/install.sh"
assert_grep 'SSH_USER invalido ou reservado' "$ROOT_DIR/install.sh"

# 2. INSTALL_SSH declarada em config.env e tratada em config-parser.sh
assert_grep '^INSTALL_SSH=' "$ROOT_DIR/config.env"
assert_grep 'INSTALL_SSH' "$ROOT_DIR/shared/lib/config-parser.sh"

# 3. SSH username configurável (SSH_USER em config.env, default "crias")
# acesso SSH, NÃO o login user do host que vem do archinstall)
assert_grep 'SSH_USER:-crias' "$ROOT_DIR/install.sh"

# 4. Conta SSH ja existente nao pode perder NOPASSWD por regra global
assert_grep_fixed '/etc/sudoers.d/90-crias-${ssh_user}' "$ROOT_DIR/install.sh"
assert_grep_fixed 'ssh_user_created' "$ROOT_DIR/install.sh"
assert_grep_fixed 'Usuario '\''$ssh_user'\'' existente: nenhuma regra sudo alterada' "$ROOT_DIR/install.sh"
assert_grep 'visudo -cf' "$ROOT_DIR/install.sh"
# A politica legada pode ser detectada para alertas, mas NUNCA recriada.
if grep -Fq "printf '%%wheel ALL=(ALL) ALL" "$ROOT_DIR/install.sh"; then
    echo "FAIL: regra sudo global wheel reintroduzida" >&2
    exit 1
fi

# 5. sshd drop-in em /etc/ssh/sshd_config.d/10-crias.conf
assert_grep '/etc/ssh/sshd_config.d/10-crias.conf' "$ROOT_DIR/install.sh"
assert_grep 'PermitRootLogin no' "$ROOT_DIR/install.sh"
# (EXP-65) O drop-in agora PRESERVA a politica de senha do host: a linha
# usa a variavel $password_auth (yes quando o host permite, no quando o
# admin desativou senha). O contrato e a logica, nao o literal.
assert_grep 'PasswordAuthentication \$password_auth' "$ROOT_DIR/install.sh"
assert_grep 'sshd -T' "$ROOT_DIR/install.sh"
assert_grep 'sshd -t' "$ROOT_DIR/install.sh"
assert_grep 'ssh-keygen -A' "$ROOT_DIR/install.sh"
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

# 11. SSH documentado no tutorial
assert_grep 'SSH_USER' "$ROOT_DIR/docs/tutorial.md"

echo "OK: install-ssh-hook-test"
