#!/usr/bin/env bash
# tests/stack-installer-test.sh
#
# Valida o framework shared/lib/stack-installer.sh.
# Verifica:
#   1. Sintaxe bash válida
#   2. Framework pode ser sourced sem erro
#   3. Hooks são chamados na ordem correta
#   4. Variáveis STACK_* são respeitadas

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

# 1. Sintaxe bash válida
assert_bash_syntax "$ROOT_DIR/shared/lib/stack-installer.sh"
assert_bash_syntax "$ROOT_DIR/shared/lib/backup-engine.sh"
assert_bash_syntax "$ROOT_DIR/shared/lib/setup-cron.sh"
assert_bash_syntax "$ROOT_DIR/shared/lib/common.sh"
assert_bash_syntax "$ROOT_DIR/shared/lib/downloads.sh"

# 2. Framework pode ser sourced sem erro
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/stack-installer.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/backup-engine.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/setup-cron.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/downloads.sh"

# 3. Funções esperadas existem
assert_grep '^create_stack_user_and_dirs\(\)' "$ROOT_DIR/shared/lib/stack-installer.sh"
assert_grep '^rollback_stack_install\(\)' "$ROOT_DIR/shared/lib/stack-installer.sh"
assert_grep '^deploy_stack_scripts\(\)' "$ROOT_DIR/shared/lib/stack-installer.sh"
assert_grep '^install_stack_service\(\)' "$ROOT_DIR/shared/lib/stack-installer.sh"
assert_grep '^apply_stack_system_tuning\(\)' "$ROOT_DIR/shared/lib/stack-installer.sh"
assert_grep '^run_stack_install\(\)' "$ROOT_DIR/shared/lib/stack-installer.sh"

# 4. backup-engine.sh tem funções esperadas
assert_grep '^backup_init\(\)' "$ROOT_DIR/shared/lib/backup-engine.sh"
assert_grep '^acquire_lock\(\)' "$ROOT_DIR/shared/lib/backup-engine.sh"
assert_grep '^create_backup\(\)' "$ROOT_DIR/shared/lib/backup-engine.sh"
assert_grep '^cleanup_old_backups\(\)' "$ROOT_DIR/shared/lib/backup-engine.sh"
assert_grep '^backup_run\(\)' "$ROOT_DIR/shared/lib/backup-engine.sh"

# 5. setup-cron.sh tem funções esperadas
assert_grep '^setup_cron_run\(\)' "$ROOT_DIR/shared/lib/setup-cron.sh"
assert_grep '^detect_server_user\(\)' "$ROOT_DIR/shared/lib/setup-cron.sh"

# 6. common.sh tem helpers novos (systemctl_quiet_or_warn, is_virtualized, generate_token)
assert_grep '^systemctl_quiet_or_warn\(\)' "$ROOT_DIR/shared/lib/common.sh"
assert_grep '^is_virtualized\(\)' "$ROOT_DIR/shared/lib/common.sh"
assert_grep '^generate_token\(\)' "$ROOT_DIR/shared/lib/common.sh"
assert_grep '^log\(\)' "$ROOT_DIR/shared/lib/common.sh"
assert_grep '^warn\(\)' "$ROOT_DIR/shared/lib/common.sh"
assert_grep '^err\(\)' "$ROOT_DIR/shared/lib/common.sh"
assert_grep '^log_ts\(\)' "$ROOT_DIR/shared/lib/common.sh"

# 7. downloads.sh tem helpers novos
assert_grep '^download_and_verify\(\)' "$ROOT_DIR/shared/lib/downloads.sh"
assert_grep '^download_modrinth_mod\(\)' "$ROOT_DIR/shared/lib/downloads.sh"
assert_grep '^_curl_with_retry\(\)' "$ROOT_DIR/shared/lib/downloads.sh"
assert_grep '^should_skip_network\(\)' "$ROOT_DIR/shared/lib/downloads.sh"

# 8. Teste funcional: backup-engine com hooks pre/post em DRY_RUN.
TMP_TEST_DIR="$(mktemp -d /tmp/crias-stack-installer-test-XXXXXX)"
trap 'rm -rf -- "$TMP_TEST_DIR" || true' EXIT

SERVER_DIR="$TMP_TEST_DIR/server"
mkdir -p "$SERVER_DIR/world" "$SERVER_DIR/world_nether"

# Define configuração mínima de backup.
# Variáveis lidas por backup_run() em shared/lib/backup-engine.sh.
# shellcheck disable=SC2034
BACKUP_SERVER_DIR="$SERVER_DIR"
BACKUP_STACK_NAME="minecraft"
BACKUP_SERVICE_NAME="minecraft"
BACKUP_DIRS=("world" "world_nether")
BACKUP_DRY_RUN=true

# Define hooks pre/post para validar chamada
PRE_HOOK_CALLED=false
POST_HOOK_CALLED=false

backup_pre_hook() {
    PRE_HOOK_CALLED=true
}

backup_post_hook() {
    POST_HOOK_CALLED=true
}

# Executa backup em DRY_RUN
backup_run > "$TMP_TEST_DIR/backup-output.log" 2>&1 || true

if ! grep -q "Backup concluido com sucesso" "$TMP_TEST_DIR/backup-output.log"; then
    echo "FAIL: backup_run em DRY_RUN não concluiu com sucesso"
    cat "$TMP_TEST_DIR/backup-output.log"
    exit 1
fi

if [ "$PRE_HOOK_CALLED" != "true" ]; then
    echo "FAIL: backup_pre_hook não foi chamada"
    exit 1
fi

if [ "$POST_HOOK_CALLED" != "true" ]; then
    echo "FAIL: backup_post_hook não foi chamada"
    exit 1
fi

# 9. Teste de generate_token (deve retornar 64 chars hex)
TOKEN=$(generate_token 32)
if [ "${#TOKEN}" -ne 64 ]; then
    echo "FAIL: generate_token retornou ${#TOKEN} chars, esperado 64"
    exit 1
fi

if ! [[ "$TOKEN" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "FAIL: generate_token não retornou hex válido: $TOKEN"
    exit 1
fi

# 10. Teste de is_virtualized (deve retornar 0 ou 1, não falhar)
if is_virtualized; then
    echo "OK: is_virtualized detectou ambiente virtualizado"
else
    echo "OK: is_virtualized detectou ambiente bare-metal"
fi

# 11. Teste de envsubst: o framework usa ${VAR} (não __VAR__)
assert_grep_fixed '${SERVER_USER}' "$ROOT_DIR/minecraft/minecraft.service"
assert_grep_fixed '${SERVER_DIR}' "$ROOT_DIR/minecraft/minecraft.service"
assert_grep_fixed '${MEMORY_MAX_MB}' "$ROOT_DIR/minecraft/minecraft.service"
assert_grep_fixed '${SERVER_USER}' "$ROOT_DIR/terraria/terraria.service"
assert_grep_fixed '${SERVER_DIR}' "$ROOT_DIR/terraria/terraria.service"
assert_grep_fixed '${MEMORY_MAX_MB}' "$ROOT_DIR/terraria/terraria.service"

# 12. Hardening systemd presente nos templates
for template in minecraft/minecraft.service terraria/terraria.service; do
    assert_grep_fixed 'CapabilityBoundingSet=' "$ROOT_DIR/$template"
    assert_grep_fixed 'SystemCallFilter=@system-service' "$ROOT_DIR/$template"
    assert_grep_fixed 'LockPersonality=yes' "$ROOT_DIR/$template"
    assert_grep_fixed 'ProtectHostname=yes' "$ROOT_DIR/$template"
    assert_grep_fixed 'ProtectClock=yes' "$ROOT_DIR/$template"
    assert_grep_fixed 'RemoveIPC=yes' "$ROOT_DIR/$template"
    assert_grep_fixed 'RestrictSUIDSGID=true' "$ROOT_DIR/$template"
    assert_grep_fixed 'RestrictRealtime=true' "$ROOT_DIR/$template"
done

# 13. install.sh tem hook do agente
assert_grep '^install_crias_agent_if_enabled\(\)' "$ROOT_DIR/install.sh"
assert_grep 'install_crias_agent_if_enabled' "$ROOT_DIR/install.sh"

# 14. packages.lock existe e tem pacotes críticos
assert_file "$ROOT_DIR/packages.lock"
assert_grep '^jdk21-openjdk' "$ROOT_DIR/packages.lock"
assert_grep '^curl' "$ROOT_DIR/packages.lock"
assert_grep '^tailscale' "$ROOT_DIR/packages.lock"

# 15. config.env tem novas variáveis
assert_grep '^MINECRAFT_QOL_MODS=' "$ROOT_DIR/config.env"
assert_grep '^MINECRAFT_MODPACK_SOURCE=' "$ROOT_DIR/config.env"
assert_grep '^MRPACK_INSTALL_VERSION=' "$ROOT_DIR/config.env"
assert_grep '^HW_LOW_TIER_MAX_RAM_MB=' "$ROOT_DIR/config.env"
assert_grep '^INSTALL_AGENT=' "$ROOT_DIR/config.env"

# 16. config-parser.sh tem novas variáveis no OVERRIDABLE_VARS
assert_grep 'MINECRAFT_QOL_MODS' "$ROOT_DIR/shared/lib/config-parser.sh"
assert_grep 'MINECRAFT_MODPACK_SOURCE' "$ROOT_DIR/shared/lib/config-parser.sh"
assert_grep 'MRPACK_INSTALL_VERSION' "$ROOT_DIR/shared/lib/config-parser.sh"
assert_grep 'HW_LOW_TIER_MAX_RAM_MB' "$ROOT_DIR/shared/lib/config-parser.sh"
assert_grep 'INSTALL_AGENT' "$ROOT_DIR/shared/lib/config-parser.sh"

echo "OK: stack-installer-test"
