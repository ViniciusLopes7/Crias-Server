#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

assert_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "[arch-dry-install] Arquivo esperado nao encontrado: $path" >&2
        exit 1
    fi
}

run_minecraft_dry_install() {
    local server_dir="/tmp/crias-ci-minecraft"
    local cfg_file="/tmp/crias-ci-minecraft.env"

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
EOF

    CONFIG_FILE="$cfg_file" bash ./install.sh

    assert_file "$server_dir/server.jar"
    assert_file "$server_dir/eula.txt"
    assert_file "$server_dir/server.properties"
    assert_file "$server_dir/runtime.env"
    assert_file "$server_dir/hardware-profile.env"
    assert_file "$server_dir/start-server.sh"
    assert_file "$server_dir/mc-manager.sh"
    assert_file "$server_dir/backup-cron.sh"
    assert_file "$server_dir/setup-cron.sh"
    assert_file "$server_dir/.shared/minecraft-tuning.sh"
    assert_file "$server_dir/minecraft.service.rendered"

    grep -q "User=minecraft-ci" "$server_dir/minecraft.service.rendered"
    grep -q "MemoryMax=" "$server_dir/minecraft.service.rendered"
}

run_terraria_dry_install() {
    local server_dir="/tmp/crias-ci-terraria"
    local cfg_file="/tmp/crias-ci-terraria.env"

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

    CONFIG_FILE="$cfg_file" bash ./install.sh

    assert_file "$server_dir/TerrariaServer.bin.x86_64"
    assert_file "$server_dir/config/serverconfig.txt"
    assert_file "$server_dir/runtime.env"
    assert_file "$server_dir/hardware-profile.env"
    assert_file "$server_dir/start-terraria.sh"
    assert_file "$server_dir/tt-manager.sh"
    assert_file "$server_dir/backup-cron.sh"
    assert_file "$server_dir/setup-cron.sh"
    assert_file "$server_dir/.shared/terraria-tuning.sh"
    assert_file "$server_dir/terraria.service.rendered"

    grep -q "User=terraria-ci" "$server_dir/terraria.service.rendered"
    grep -q "MemoryMax=" "$server_dir/terraria.service.rendered"
    grep -q "maxplayers=" "$server_dir/config/serverconfig.txt"
}

echo "[arch-dry-install] Iniciando dry-run de instalacao Minecraft..."
run_minecraft_dry_install

echo "[arch-dry-install] Iniciando dry-run de instalacao Terraria..."
run_terraria_dry_install

echo "[arch-dry-install] OK"
