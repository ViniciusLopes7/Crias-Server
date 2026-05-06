#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_TEST_DIR="$(mktemp -d /tmp/crias-ci-install-contracts-XXXXXX)"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

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
    local resolved_server_type=""

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

    (
        SERVER_TYPE="terraria"
        CONFIG_FILE="$cfg_file"

        # shellcheck source=/dev/null
        source ./install.sh

        capture_env_overrides
        load_config_file
        restore_env_overrides

        resolved_server_type="$SERVER_TYPE"

        if [ "$resolved_server_type" != "terraria" ]; then
            echo "[install-contracts] SERVER_TYPE nao preservou precedencia do ambiente." >&2
            exit 1
        fi

        if [ "$MINECRAFT_USER" != "minecraft-ci" ]; then
            echo "[install-contracts] Config do Minecraft nao foi carregada corretamente." >&2
            exit 1
        fi

        if [ "$TERRARIA_USER" != "terraria-ci" ]; then
            echo "[install-contracts] Config do Terraria nao foi carregada corretamente." >&2
            exit 1
        fi
    )
}

run_config_parsing_contract() {
    local cfg_file="$TMP_TEST_DIR/config-parsing.env"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_MOTD="Servidor Crias com espacos"
TERRARIA_MOTD='Terraria com aspas simples e espacos'
TERRARIA_WORLD_NAME="Mundo do Crias"
EOF

    (
        # shellcheck source=/dev/null
        source ./install.sh
        MINECRAFT_MOTD=""
        TERRARIA_MOTD=""
        TERRARIA_WORLD_NAME=""

        CONFIG_FILE="$cfg_file" load_config_file

        if [ "$MINECRAFT_MOTD" != "Servidor Crias com espacos" ]; then
            echo "[install-contracts] MOTD do Minecraft nao preservou espacos/aspas." >&2
            exit 1
        fi

        if [ "$TERRARIA_MOTD" != "Terraria com aspas simples e espacos" ]; then
            echo "[install-contracts] MOTD do Terraria nao preservou aspas simples." >&2
            exit 1
        fi

        if [ "$TERRARIA_WORLD_NAME" != "Mundo do Crias" ]; then
            echo "[install-contracts] Nome do mundo do Terraria nao preservou espacos." >&2
            exit 1
        fi
    )
}

echo "[install-contracts] Validando falha rapida para configuracoes invalidas..."
run_missing_server_type_contract
run_invalid_server_type_contract

echo "[install-contracts] Validando precedencia de variaveis de ambiente..."
run_env_override_precedence_contract

echo "[install-contracts] Validando parse de valores com espacos e aspas..."
run_config_parsing_contract

echo "[install-contracts] OK"
