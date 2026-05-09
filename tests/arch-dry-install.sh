#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_TEST_DIR="$(mktemp -d /tmp/crias-ci-dry-install-XXXXXX)"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

run_minecraft_dry_install() {
    local server_dir="$TMP_TEST_DIR/minecraft"
    local cfg_file="$TMP_TEST_DIR/minecraft.env"
    local log_file="$TMP_TEST_DIR/minecraft-dry.log"

    rm -rf "$server_dir"

    cat > "$cfg_file" << EOF
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
FORCE_HARDWARE_TIER="MID"
MINECRAFT_USER="minecraft-ci"
MINECRAFT_SERVER_DIR="$server_dir"
MINECRAFT_PORT=25565
MINECRAFT_ONLINE_MODE="false"
MINECRAFT_VERSION="1.21.11"
MINECRAFT_LOADER="fabric"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_INSTALL_QOL_MODS="true"
ACCEPT_EULA="true"
EOF

    if ! CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1; then
        echo "[arch-dry-install] install.sh retornou erro. Conteudo de $log_file:" >&2
        sed -n '1,2000p' "$log_file" >&2 || true
        return 1
    fi

    assert_grep 'Modo DRY_RUN ativo: nenhuma alteracao destrutiva no host sera aplicada\.' "$log_file"
    assert_grep 'Stack selecionado: minecraft' "$log_file"

    if [ -e "$server_dir" ]; then
        echo "[arch-dry-install] DRY_RUN nao deveria criar o diretorio do Minecraft." >&2
        cat "$log_file" >&2
        exit 1
    fi

    assert_bash_syntax "$ROOT_DIR/minecraft/install.sh"
    assert_bash_syntax "$ROOT_DIR/minecraft/start-server.sh"
    assert_bash_syntax "$ROOT_DIR/minecraft/mc-manager.sh"
    assert_bash_syntax "$ROOT_DIR/minecraft/backup-cron.sh"
    assert_bash_syntax "$ROOT_DIR/minecraft/setup-cron.sh"

    assert_grep '^alias mcstart=' "$ROOT_DIR/minecraft/install.sh"
    assert_grep '^alias mcreconfig=' "$ROOT_DIR/minecraft/install.sh"
    assert_grep "stat -c '%U'" "$ROOT_DIR/minecraft/mc-manager.sh"
}

run_terraria_dry_install() {
    local server_dir="$TMP_TEST_DIR/terraria"
    local cfg_file="$TMP_TEST_DIR/terraria.env"
    local log_file="$TMP_TEST_DIR/terraria-dry.log"

    rm -rf "$server_dir"

    cat > "$cfg_file" << EOF
SERVER_TYPE="terraria"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
FORCE_HARDWARE_TIER="HIGH"
TERRARIA_USER="terraria-ci"
TERRARIA_SERVER_DIR="$server_dir"
TERRARIA_PORT=7777
TERRARIA_WORLD_NAME="world"
TERRARIA_MOTD="Servidor Terraria CI"
TERRARIA_DOWNLOAD_URL="https://example.invalid/terraria.zip"
EOF

    if ! CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1; then
        echo "[arch-dry-install] install.sh retornou erro. Conteudo de $log_file:" >&2
        sed -n '1,2000p' "$log_file" >&2 || true
        return 1
    fi

    assert_grep 'Modo DRY_RUN ativo: nenhuma alteracao destrutiva no host sera aplicada\.' "$log_file"
    assert_grep 'Stack selecionado: terraria' "$log_file"

    if [ -e "$server_dir" ]; then
        echo "[arch-dry-install] DRY_RUN nao deveria criar o diretorio do Terraria." >&2
        cat "$log_file" >&2
        exit 1
    fi

    assert_bash_syntax "$ROOT_DIR/terraria/install.sh"
    assert_bash_syntax "$ROOT_DIR/terraria/start-terraria.sh"
    assert_bash_syntax "$ROOT_DIR/terraria/tt-manager.sh"
    assert_bash_syntax "$ROOT_DIR/terraria/backup-cron.sh"
    assert_bash_syntax "$ROOT_DIR/terraria/setup-cron.sh"

    assert_grep '^alias ttstart=' "$ROOT_DIR/terraria/install.sh"
    assert_grep '^alias ttreconfig=' "$ROOT_DIR/terraria/install.sh"
    assert_grep "stat -c '%U'" "$ROOT_DIR/terraria/tt-manager.sh"
}

echo "[arch-dry-install] Iniciando dry-run de instalacao Minecraft..."
run_minecraft_dry_install

echo "[arch-dry-install] Iniciando dry-run de instalacao Terraria..."
run_terraria_dry_install

echo "[arch-dry-install] OK"
