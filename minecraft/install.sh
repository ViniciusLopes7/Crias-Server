#!/bin/bash

set -eo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$MODULE_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/hardware-profile.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/system-tuning.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/minecraft-tuning.sh"

MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_SERVER_DIR="${MINECRAFT_SERVER_DIR:-/opt/minecraft-server}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"
MINECRAFT_ONLINE_MODE="${MINECRAFT_ONLINE_MODE:-false}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
MINECRAFT_INSTALL_MODPACK="${MINECRAFT_INSTALL_MODPACK:-true}"
MINECRAFT_ADRENALINE_VERSION="${MINECRAFT_ADRENALINE_VERSION:-}"
MINECRAFT_INSTALL_QOL_MODS="${MINECRAFT_INSTALL_QOL_MODS:-true}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
DRY_RUN="${DRY_RUN:-false}"

install_minecraft_dependencies() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao de dependencias do Minecraft."
        return 0
    fi

    print_step "Atualizando sistema..."
    pacman -Syu --noconfirm

    print_step "Instalando dependencias do Minecraft..."
    pacman -S --needed --noconfirm \
        jdk21-openjdk \
        screen \
        htop \
        iotop \
        nano \
        curl \
        wget \
        tar \
        gzip \
        unzip \
        base-devel \
        zram-generator \
        cpupower \
        lm_sensors \
        openssh \
        jq

    systemctl enable --now sshd >/dev/null 2>&1 || true
}

create_minecraft_user_and_dirs() {
    print_step "Garantindo usuario e diretorio do Minecraft..."

    if is_true "$DRY_RUN"; then
        mkdir -p "$MINECRAFT_SERVER_DIR"
        return 0
    fi

    if ! id "$MINECRAFT_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$MINECRAFT_USER"
    fi

    mkdir -p "$MINECRAFT_SERVER_DIR"
    chown -R "${MINECRAFT_USER}:${MINECRAFT_USER}" "$MINECRAFT_SERVER_DIR"
}

install_mrpack_install() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do mrpack-install."
        return 0
    fi

    print_step "Instalando mrpack-install..."

    local mrpack_url
    mrpack_url=$(curl -s https://api.github.com/repos/nothub/mrpack-install/releases/latest | jq -r '.assets[] | select(.name=="mrpack-install-linux") | .browser_download_url')

    if [ -z "$mrpack_url" ] || [ "$mrpack_url" = "null" ]; then
        mrpack_url="https://github.com/nothub/mrpack-install/releases/latest/download/mrpack-install-linux"
    fi

    curl -fsSL -o /tmp/mrpack-install "$mrpack_url"
    install -m 755 /tmp/mrpack-install /usr/local/bin/mrpack-install
}

install_minecraft_base() {
    print_step "Instalando base do servidor Minecraft..."

    if is_true "$DRY_RUN"; then
        mkdir -p "$MINECRAFT_SERVER_DIR"
        touch "$MINECRAFT_SERVER_DIR/server.jar"
        echo "eula=true" > "$MINECRAFT_SERVER_DIR/eula.txt"
        return 0
    fi

    cd "$MINECRAFT_SERVER_DIR" || exit 1

    if is_true "$MINECRAFT_INSTALL_MODPACK"; then
        if [ -n "$MINECRAFT_ADRENALINE_VERSION" ]; then
            mrpack-install adrenaline "$MINECRAFT_ADRENALINE_VERSION" --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
        else
            mrpack-install adrenaline --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
        fi
    else
        mrpack-install "$MINECRAFT_LOADER" "$MINECRAFT_VERSION" --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
    fi

    echo "eula=true" > "$MINECRAFT_SERVER_DIR/eula.txt"
}

download_qol_mod() {
    local file_name="$1"
    local slug="$2"
    local api_url
    local mod_url

    api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$MINECRAFT_LOADER%22%5D&game_versions=%5B%22$MINECRAFT_VERSION%22%5D"
    mod_url=$(curl -s "$api_url" | jq -r '.[0].files[0].url // empty')

    if [ -z "$mod_url" ]; then
        mod_url=$(curl -s "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$MINECRAFT_LOADER%22%5D" | jq -r '.[0].files[0].url // empty')
    fi

    if [ -n "$mod_url" ]; then
        curl -fsSL -o "$MINECRAFT_SERVER_DIR/mods/${file_name}.jar" "$mod_url"
        print_success "Mod instalado: ${file_name}.jar"
    else
        print_warning "Nao foi possivel baixar o mod: $file_name"
    fi
}

install_minecraft_qol_mods() {
    if ! is_true "$MINECRAFT_INSTALL_QOL_MODS"; then
        return 0
    fi

    if [ "$MINECRAFT_LOADER" != "fabric" ] && [ "$MINECRAFT_LOADER" != "quilt" ]; then
        print_warning "Mods QoL pulados para loader $MINECRAFT_LOADER"
        return 0
    fi

    print_step "Instalando mods QoL..."
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"

    if is_true "$DRY_RUN"; then
        touch "$MINECRAFT_SERVER_DIR/mods/qol-dry-run.txt"
        return 0
    fi

    download_qol_mod "chunky" "chunky"
    download_qol_mod "essential-commands" "essential-commands"
    download_qol_mod "universal-graves" "universal-graves"
    download_qol_mod "tabtps" "tabtps"
    download_qol_mod "styled-chat" "styled-chat"
    download_qol_mod "polymer" "polymer"
    download_qol_mod "placeholder-api" "placeholder-api"
}

write_minecraft_extra_configs() {
    mkdir -p "$MINECRAFT_SERVER_DIR/config/essentialcommands" "$MINECRAFT_SERVER_DIR/config/universal_graves"

    if [ ! -f "$MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" ]; then
        cat > "$MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" << 'EOF'
[teleportation]
allow_teleport_between_dimensions = true
teleport_request_timeout_seconds = 120
teleport_cost = 0

[home]
max_homes = 3
allow_home_in_any_dimension = true

[spawn]
allow_spawn_in_any_dimension = true

[back]
enable_back = true
save_back_on_death = true

[rtp]
enable_rtp = true
rtp_radius = 10000
rtp_min_radius = 1000

[nicknames]
enable_nicknames = true
nickname_prefix = "~"
EOF
    fi

    if [ ! -f "$MINECRAFT_SERVER_DIR/config/universal_graves/config.json" ]; then
        cat > "$MINECRAFT_SERVER_DIR/config/universal_graves/config.json" << 'EOF'
{
  "protection_time": 300,
  "breaking_time": 1800,
  "drop_items_on_expiration": true,
  "message_on_grave_break": true,
  "message_on_grave_expire": true,
  "hologram": true,
  "title": true,
  "gui": true
}
EOF
    fi
}

configure_minecraft_runtime() {
    print_step "Aplicando tuning automatico para Minecraft..."

    detect_hardware_profile "$MINECRAFT_SERVER_DIR" "$FORCE_HARDWARE_TIER"
    compute_minecraft_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_minecraft_runtime_env "$MINECRAFT_SERVER_DIR/runtime.env"
    write_minecraft_server_properties "$MINECRAFT_SERVER_DIR/server.properties" "$MINECRAFT_PORT" "$MINECRAFT_ONLINE_MODE"
    write_minecraft_tuning_state "$MINECRAFT_SERVER_DIR/hardware-profile.env"

    write_minecraft_extra_configs

    print_success "Tier detectado: $HW_DETECTED_TIER | Tier aplicado: $HW_TIER"
    print_success "Heap aplicado: $MC_MIN_RAM -> $MC_MAX_RAM"
}

deploy_minecraft_scripts() {
    print_step "Copiando scripts do modulo Minecraft..."

    cp "$MODULE_DIR/start-server.sh" "$MINECRAFT_SERVER_DIR/start-server.sh"
    cp "$MODULE_DIR/mc-manager.sh" "$MINECRAFT_SERVER_DIR/mc-manager.sh"
    cp "$MODULE_DIR/backup-cron.sh" "$MINECRAFT_SERVER_DIR/backup-cron.sh"
    cp "$MODULE_DIR/setup-cron.sh" "$MINECRAFT_SERVER_DIR/setup-cron.sh"

    mkdir -p "$MINECRAFT_SERVER_DIR/.shared"
    cp "$ROOT_DIR/shared/lib/hardware-profile.sh" "$MINECRAFT_SERVER_DIR/.shared/hardware-profile.sh"
    cp "$ROOT_DIR/shared/lib/minecraft-tuning.sh" "$MINECRAFT_SERVER_DIR/.shared/minecraft-tuning.sh"

    chmod +x "$MINECRAFT_SERVER_DIR/start-server.sh" "$MINECRAFT_SERVER_DIR/mc-manager.sh" "$MINECRAFT_SERVER_DIR/backup-cron.sh" "$MINECRAFT_SERVER_DIR/setup-cron.sh"

    cat > "$MINECRAFT_SERVER_DIR/comandos.sh" << EOF
#!/bin/bash
alias mcstart='sudo systemctl start minecraft'
alias mcstop='sudo systemctl stop minecraft'
alias mcrestart='sudo systemctl restart minecraft'
alias mcstatus='sudo systemctl status minecraft'
alias mclogs='sudo journalctl -u minecraft -f'
alias mcconsole='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh console'
alias mcbackup='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh backup'
alias mcdir='cd $MINECRAFT_SERVER_DIR'
alias mcprops='sudo nano $MINECRAFT_SERVER_DIR/server.properties'
alias mchw='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh hardware-report'
alias mcreconfig='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh reconfigure-hardware'
EOF

    chmod +x "$MINECRAFT_SERVER_DIR/comandos.sh"

    if ! is_true "$DRY_RUN"; then
        chown -R "${MINECRAFT_USER}:${MINECRAFT_USER}" "$MINECRAFT_SERVER_DIR"
    fi
}

install_minecraft_service() {
    print_step "Instalando servico systemd do Minecraft..."

    if is_true "$DRY_RUN"; then
        sed \
            -e "s|__SERVER_USER__|$MINECRAFT_USER|g" \
            -e "s|__SERVER_DIR__|$MINECRAFT_SERVER_DIR|g" \
            -e "s|__MEMORY_MAX_MB__|$MC_SERVICE_MEMORY_MAX_MB|g" \
            "$MODULE_DIR/minecraft.service" > "$MINECRAFT_SERVER_DIR/minecraft.service.rendered"
        print_step "[DRY_RUN] Unidade gerada em $MINECRAFT_SERVER_DIR/minecraft.service.rendered"
        return 0
    fi

    sed \
        -e "s|__SERVER_USER__|$MINECRAFT_USER|g" \
        -e "s|__SERVER_DIR__|$MINECRAFT_SERVER_DIR|g" \
        -e "s|__MEMORY_MAX_MB__|$MC_SERVICE_MEMORY_MAX_MB|g" \
        "$MODULE_DIR/minecraft.service" > /etc/systemd/system/minecraft.service

    systemctl daemon-reload
    systemctl enable minecraft >/dev/null 2>&1 || true
}

apply_minecraft_system_tuning() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando tuning de sistema compartilhado."
        return 0
    fi

    if is_true "$APPLY_SYSTEM_TUNING"; then
        print_step "Aplicando tuning de sistema compartilhado..."
        apply_common_system_tuning "$MINECRAFT_USER" "$HW_TIER" "$HW_TOTAL_RAM_MB"
    fi
}

run_minecraft_install() {
    print_step "Iniciando instalacao do stack Minecraft..."
    install_minecraft_dependencies
    create_minecraft_user_and_dirs
    install_mrpack_install
    install_minecraft_base
    install_minecraft_qol_mods
    configure_minecraft_runtime
    deploy_minecraft_scripts
    install_minecraft_service
    apply_minecraft_system_tuning

    print_success "Minecraft instalado com sucesso em $MINECRAFT_SERVER_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_minecraft_install
fi
