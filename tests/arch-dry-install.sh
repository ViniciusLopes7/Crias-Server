#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_TEST_DIR="$(mktemp -d /tmp/crias-ci-dry-install-XXXXXX)"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

assert_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "[arch-dry-install] Arquivo esperado nao encontrado: $path" >&2
        exit 1
    fi
}

assert_executable() {
    local path="$1"
    if [ ! -x "$path" ]; then
        echo "[arch-dry-install] Arquivo esperado nao esta executavel: $path" >&2
        exit 1
    fi
}

assert_grep() {
    local pattern="$1"
    local path="$2"

    if ! grep -Eq "$pattern" "$path"; then
        echo "[arch-dry-install] Padrao nao encontrado em $path: $pattern" >&2
        exit 1
    fi
}

assert_not_grep() {
    local pattern="$1"
    local path="$2"

    if grep -Eq "$pattern" "$path"; then
        echo "[arch-dry-install] Padrao inesperado encontrado em $path: $pattern" >&2
        exit 1
    fi
}

assert_bash_syntax() {
    local path="$1"
    bash -n "$path"
}

run_minecraft_dry_install() {
    local server_dir="$TMP_TEST_DIR/minecraft"
    local cfg_file="$TMP_TEST_DIR/minecraft.env"

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
    assert_grep 'screen -S "' "$server_dir/backup-cron.sh"
    assert_file "$server_dir/minecraft.service.rendered"
    assert_file "$server_dir/comandos.sh"

    assert_executable "$server_dir/start-server.sh"
    assert_executable "$server_dir/mc-manager.sh"
    assert_executable "$server_dir/backup-cron.sh"
    assert_executable "$server_dir/setup-cron.sh"
    assert_executable "$server_dir/comandos.sh"

    assert_grep "stat -c '%U'" "$server_dir/mc-manager.sh"

    assert_bash_syntax "$server_dir/start-server.sh"
    assert_bash_syntax "$server_dir/mc-manager.sh"
    assert_bash_syntax "$server_dir/backup-cron.sh"
    assert_bash_syntax "$server_dir/setup-cron.sh"
    assert_bash_syntax "$server_dir/comandos.sh"

    assert_grep 'User=minecraft-ci' "$server_dir/minecraft.service.rendered"
    assert_grep 'MemoryMax=' "$server_dir/minecraft.service.rendered"
    assert_not_grep '__SERVER_USER__|__SERVER_DIR__|__MEMORY_MAX_MB__' "$server_dir/minecraft.service.rendered"

    assert_grep '^MIN_RAM="[0-9]+M"$' "$server_dir/runtime.env"
    assert_grep '^MAX_RAM="[0-9]+M"$' "$server_dir/runtime.env"
    assert_grep '^GC_MAX_PAUSE="[0-9]+"$' "$server_dir/runtime.env"
    assert_grep '^HW_TIER="(LOW|MID|HIGH)"$' "$server_dir/hardware-profile.env"
    assert_grep '^MC_SERVICE_MEMORY_MAX_MB="[0-9]+"$' "$server_dir/hardware-profile.env"
    assert_grep '^MIN_RAM="[0-9]+M"$' "$server_dir/runtime.env"
    assert_grep '^MAX_RAM="[0-9]+M"$' "$server_dir/runtime.env"
    assert_grep '^GC_MAX_PAUSE="[0-9]+"$' "$server_dir/runtime.env"

    assert_grep '^alias mcstart=' "$server_dir/comandos.sh"
    assert_grep '^alias mcreconfig=' "$server_dir/comandos.sh"
}

run_terraria_dry_install() {
    local server_dir="$TMP_TEST_DIR/terraria"
    local cfg_file="$TMP_TEST_DIR/terraria.env"

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
    assert_grep 'screen -S "' "$server_dir/backup-cron.sh"
    assert_file "$server_dir/terraria.service.rendered"
    assert_file "$server_dir/comandos.sh"

    assert_executable "$server_dir/start-terraria.sh"
    assert_executable "$server_dir/tt-manager.sh"
    assert_executable "$server_dir/backup-cron.sh"
    assert_executable "$server_dir/setup-cron.sh"
    assert_executable "$server_dir/comandos.sh"

    assert_bash_syntax "$server_dir/start-terraria.sh"
    assert_bash_syntax "$server_dir/tt-manager.sh"
    assert_bash_syntax "$server_dir/backup-cron.sh"
    assert_bash_syntax "$server_dir/setup-cron.sh"
    assert_bash_syntax "$server_dir/comandos.sh"

    assert_grep "stat -c '%U'" "$server_dir/tt-manager.sh"

    assert_grep 'User=terraria-ci' "$server_dir/terraria.service.rendered"
    assert_grep 'MemoryMax=' "$server_dir/terraria.service.rendered"
    assert_not_grep '__SERVER_USER__|__SERVER_DIR__|__MEMORY_MAX_MB__' "$server_dir/terraria.service.rendered"

    assert_grep '^maxplayers=' "$server_dir/config/serverconfig.txt"
    assert_grep '^port=7777$' "$server_dir/config/serverconfig.txt"

    assert_grep '^BACKUP_RETENTION_DAYS="[0-9]+"$' "$server_dir/runtime.env"
    assert_grep '^BACKUP_ZSTD_LEVEL="-?[0-9]+"$' "$server_dir/runtime.env"
    assert_grep '^HW_TIER="(LOW|MID|HIGH)"$' "$server_dir/hardware-profile.env"
    assert_grep '^TT_SERVICE_MEMORY_MAX_MB="[0-9]+"$' "$server_dir/hardware-profile.env"
    assert_grep '^BACKUP_RETENTION_DAYS="[0-9]+"$' "$server_dir/runtime.env"
    assert_grep '^BACKUP_ZSTD_LEVEL="-?[0-9]+"$' "$server_dir/runtime.env"

    assert_grep '^alias ttstart=' "$server_dir/comandos.sh"
    assert_grep '^alias ttreconfig=' "$server_dir/comandos.sh"
}

echo "[arch-dry-install] Iniciando dry-run de instalacao Minecraft..."
run_minecraft_dry_install

echo "[arch-dry-install] Iniciando dry-run de instalacao Terraria..."
run_terraria_dry_install

echo "[arch-dry-install] OK"
