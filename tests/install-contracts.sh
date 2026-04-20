#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_TEST_DIR="$(mktemp -d /tmp/crias-ci-install-contracts-XXXXXX)"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

assert_expected_failure() {
    local config_file="$1"
    local log_file="$2"
    local scenario="$3"

    set +e
    CONFIG_FILE="$config_file" bash ./install.sh > "$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "[install-contracts] Falha esperada nao ocorreu: $scenario" >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q 'SERVER_TYPE precisa ser definido como minecraft ou terraria' "$log_file"; then
        echo "[install-contracts] Mensagem esperada nao encontrada para: $scenario" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

run_missing_server_type_contract() {
    local cfg_file="$TMP_TEST_DIR/missing-server-type.env"
    local log_file="$TMP_TEST_DIR/missing-server-type.log"

    cat > "$cfg_file" << 'EOF'
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
EOF

    assert_expected_failure "$cfg_file" "$log_file" "SERVER_TYPE ausente em NON_INTERACTIVE"
}

run_invalid_server_type_contract() {
    local cfg_file="$TMP_TEST_DIR/invalid-server-type.env"
    local log_file="$TMP_TEST_DIR/invalid-server-type.log"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="invalido"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
EOF

    assert_expected_failure "$cfg_file" "$log_file" "SERVER_TYPE invalido em NON_INTERACTIVE"
}

run_env_override_precedence_contract() {
    local cfg_file="$TMP_TEST_DIR/env-precedence.env"
    local log_file="$TMP_TEST_DIR/env-precedence.log"
    local mc_dir="$TMP_TEST_DIR/minecraft-from-config"
    local tt_dir="$TMP_TEST_DIR/terraria-from-env"

    cat > "$cfg_file" << EOF
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_USER="minecraft-ci"
MINECRAFT_SERVER_DIR="$mc_dir"
MINECRAFT_PORT=25565
MINECRAFT_ONLINE_MODE="false"
MINECRAFT_VERSION="1.21.11"
MINECRAFT_LOADER="fabric"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_INSTALL_QOL_MODS="false"
TERRARIA_USER="terraria-ci"
TERRARIA_SERVER_DIR="$tt_dir"
TERRARIA_PORT=7777
TERRARIA_WORLD_NAME="world"
TERRARIA_MOTD="Contrato CI"
TERRARIA_DOWNLOAD_URL="https://example.invalid/terraria.zip"
EOF

    SERVER_TYPE="terraria" CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1

    if [ ! -f "$tt_dir/TerrariaServer.bin.x86_64" ]; then
        echo "[install-contracts] Override de ambiente para SERVER_TYPE nao foi respeitado." >&2
        cat "$log_file" >&2
        exit 1
    fi

    if [ -d "$mc_dir" ]; then
        echo "[install-contracts] Diretorio Minecraft nao deveria ser criado no teste de precedencia." >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q 'Stack selecionado: terraria' "$log_file"; then
        echo "[install-contracts] Log nao confirma stack terraria no teste de precedencia." >&2
        cat "$log_file" >&2
        exit 1
    fi
}

echo "[install-contracts] Validando falha rapida para configuracoes invalidas..."
run_missing_server_type_contract
run_invalid_server_type_contract

echo "[install-contracts] Validando precedencia de variaveis de ambiente..."
run_env_override_precedence_contract

echo "[install-contracts] OK"
