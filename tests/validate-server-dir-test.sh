#!/usr/bin/env bash
# tests/validate-server-dir-test.sh
#
# Contraprova do EXP-35: a validação de diretório de servidor usa ALLOWLIST.
# Raízes amplas (/home, /opt, /srv, /var, /tmp, /run, /mnt, /media, /) e
# caminhos de sistema NUNCA podem ser aceitos como alvo de chown -R/rm -rf;
# apenas subdiretórios dedicados passam. Também cobre bypass por symlink.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"

fail_count=0

expect_reject() {
    local dir="$1"
    if validate_server_dir "$dir" >/dev/null 2>&1; then
        echo "FAIL: '$dir' deveria ser REJEITADO (EXP-35)"
        fail_count=$((fail_count + 1))
    else
        echo "OK: rejeitado '$dir'"
    fi
}

expect_accept() {
    local dir="$1"
    if validate_server_dir "$dir" >/dev/null 2>&1; then
        echo "OK: aceito '$dir'"
    else
        echo "FAIL: '$dir' deveria ser ACEITO (destino dedicado válido)"
        fail_count=$((fail_count + 1))
    fi
}

# --- Raízes amplas e caminhos inválidos: sempre rejeitados ---
expect_reject ""
expect_reject "/"
expect_reject "relative/dir"
expect_reject "/home"
expect_reject "/opt"
expect_reject "/srv"
expect_reject "/var"
expect_reject "/tmp"
expect_reject "/run"
expect_reject "/mnt"
expect_reject "/media"
expect_reject "/home/usuario"          # home INTEIRO do usuario
expect_reject "/tmp/direto"            # filho direto de area world-writable
expect_reject "/mnt/servidor"          # /mnt nunca e allowlistado
expect_reject "/var/tmp/x"

# --- Áreas de sistema: sempre rejeitadas ---
expect_reject "/usr"
expect_reject "/usr/share/server"
expect_reject "/etc/server"
expect_reject "/root/server"
expect_reject "/boot/server"
expect_reject "/var/lib/server"
expect_reject "/var/log/server"
expect_reject "/opt/crias-agent"
expect_reject "/opt/crias-agent/dados"

# --- Destinos dedicados: aceitos ---
expect_accept "/opt/minecraft-server"
expect_accept "/opt/terraria-server"
expect_accept "/srv/crias/minecraft"
expect_accept "/srv/meu-servidor"
expect_accept "/home/usuario/servidor"
expect_accept "/home/usuario/mc/servidor"
expect_accept "/var/opt/minecraft"
expect_accept "/tmp/crias-ci-abc123/minecraft"  # subdiretório dedicado aninhado

# --- Bypass por symlink: symlink para raiz ampla é rejeitado pelo resolved ---
SYMLINK_TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$SYMLINK_TEST_DIR" || true' EXIT
ln -s /home "$SYMLINK_TEST_DIR/link-home"
if validate_server_dir "$SYMLINK_TEST_DIR/link-home" >/dev/null 2>&1; then
    echo "FAIL: symlink para /home foi ACEITO (bypass do EXP-35)"
    fail_count=$((fail_count + 1))
else
    echo "OK: rejeitado symlink para /home"
fi

# Symlink para destino dedicado válido: aceito (resolved e um destino próprio)
ln -s /opt/minecraft-server "$SYMLINK_TEST_DIR/link-ok"
if validate_server_dir "$SYMLINK_TEST_DIR/link-ok" >/dev/null 2>&1; then
    echo "OK: aceito symlink para /opt/minecraft-server"
else
    echo "FAIL: symlink para destino dedicado válido foi rejeitado"
    fail_count=$((fail_count + 1))
fi

if [ "$fail_count" -ne 0 ]; then
    echo "FAIL: $fail_count caso(s) divergente(s) da política EXP-35"
    exit 1
fi

echo "OK: validate-server-dir-test (allowlist EXP-35)"
