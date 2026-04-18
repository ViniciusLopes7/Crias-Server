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
source "$ROOT_DIR/shared/lib/terraria-tuning.sh"

TERRARIA_USER="${TERRARIA_USER:-terraria}"
TERRARIA_SERVER_DIR="${TERRARIA_SERVER_DIR:-/opt/terraria-server}"
TERRARIA_PORT="${TERRARIA_PORT:-7777}"
TERRARIA_WORLD_NAME="${TERRARIA_WORLD_NAME:-world}"
TERRARIA_MOTD="${TERRARIA_MOTD:-Servidor Terraria gerenciado por Crias-Server}"
TERRARIA_DOWNLOAD_URL="${TERRARIA_DOWNLOAD_URL:-https://terraria.org/api/download/pc-dedicated-server/terraria-server-1449.zip}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
DRY_RUN="${DRY_RUN:-false}"

install_terraria_dependencies() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao de dependencias do Terraria."
        return 0
    fi

    print_step "Atualizando sistema..."
    pacman -Syu --noconfirm

    print_step "Instalando dependencias do Terraria..."
    pacman -S --needed --noconfirm \
        screen \
        htop \
        iotop \
        nano \
        curl \
        wget \
        tar \
        gzip \
        unzip \
        zram-generator \
        cpupower \
        lm_sensors \
        openssh

    systemctl enable --now sshd >/dev/null 2>&1 || true
}

create_terraria_user_and_dirs() {
    print_step "Garantindo usuario e diretorio do Terraria..."

    if is_true "$DRY_RUN"; then
        mkdir -p "$TERRARIA_SERVER_DIR" "$TERRARIA_SERVER_DIR/config" "$TERRARIA_SERVER_DIR/worlds"
        return 0
    fi

    if ! id "$TERRARIA_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$TERRARIA_USER"
    fi

    mkdir -p "$TERRARIA_SERVER_DIR" "$TERRARIA_SERVER_DIR/config" "$TERRARIA_SERVER_DIR/worlds"
    chown -R "${TERRARIA_USER}:${TERRARIA_USER}" "$TERRARIA_SERVER_DIR"
}

download_and_extract_terraria() {
    local tmp_zip
    local tmp_dir
    local binary_path
    local linux_dir

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Gerando binario dummy do Terraria."
        mkdir -p "$TERRARIA_SERVER_DIR"
        cat > "$TERRARIA_SERVER_DIR/TerrariaServer.bin.x86_64" << 'EOF'
#!/bin/bash
echo "Terraria dry-run binary"
EOF
        chmod +x "$TERRARIA_SERVER_DIR/TerrariaServer.bin.x86_64"
        return 0
    fi

    print_step "Baixando servidor Terraria Vanilla..."
    tmp_zip=$(mktemp /tmp/terraria-server-XXXXXX.zip)
    tmp_dir=$(mktemp -d)

    if ! curl -fL "$TERRARIA_DOWNLOAD_URL" -o "$tmp_zip"; then
        print_error "Falha ao baixar o servidor Terraria."
        print_error "Defina TERRARIA_DOWNLOAD_URL em config.env com um link valido."
        rm -f "$tmp_zip"
        rm -rf "$tmp_dir"
        exit 1
    fi

    print_step "Extraindo servidor Terraria..."
    unzip -q -o "$tmp_zip" -d "$tmp_dir"

    binary_path=$(find "$tmp_dir" -type f -name "TerrariaServer.bin.x86_64" | head -n 1)
    if [ -z "$binary_path" ]; then
        print_error "Nao foi possivel localizar TerrariaServer.bin.x86_64 no pacote baixado."
        rm -f "$tmp_zip"
        rm -rf "$tmp_dir"
        exit 1
    fi

    linux_dir=$(dirname "$binary_path")
    cp -r "$linux_dir"/. "$TERRARIA_SERVER_DIR"/

    chmod +x "$TERRARIA_SERVER_DIR/TerrariaServer.bin.x86_64"

    rm -f "$tmp_zip"
    rm -rf "$tmp_dir"
}

configure_terraria_runtime() {
    print_step "Aplicando tuning automatico para Terraria..."

    detect_hardware_profile "$TERRARIA_SERVER_DIR" "$FORCE_HARDWARE_TIER"
    compute_terraria_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_terraria_runtime_env "$TERRARIA_SERVER_DIR/runtime.env"
    write_terraria_server_config \
        "$TERRARIA_SERVER_DIR/config/serverconfig.txt" \
        "$TERRARIA_SERVER_DIR/worlds" \
        "$TERRARIA_PORT" \
        "$TERRARIA_MOTD" \
        "$TERRARIA_WORLD_NAME"
    write_terraria_tuning_state "$TERRARIA_SERVER_DIR/hardware-profile.env"

    print_success "Tier detectado: $HW_DETECTED_TIER | Tier aplicado: $HW_TIER"
    print_success "Max players aplicado: $TT_MAX_PLAYERS"
}

deploy_terraria_scripts() {
    print_step "Copiando scripts do modulo Terraria..."

    cp "$MODULE_DIR/start-terraria.sh" "$TERRARIA_SERVER_DIR/start-terraria.sh"
    cp "$MODULE_DIR/tt-manager.sh" "$TERRARIA_SERVER_DIR/tt-manager.sh"
    cp "$MODULE_DIR/backup-cron.sh" "$TERRARIA_SERVER_DIR/backup-cron.sh"
    cp "$MODULE_DIR/setup-cron.sh" "$TERRARIA_SERVER_DIR/setup-cron.sh"

    mkdir -p "$TERRARIA_SERVER_DIR/.shared"
    cp "$ROOT_DIR/shared/lib/hardware-profile.sh" "$TERRARIA_SERVER_DIR/.shared/hardware-profile.sh"
    cp "$ROOT_DIR/shared/lib/terraria-tuning.sh" "$TERRARIA_SERVER_DIR/.shared/terraria-tuning.sh"

    chmod +x "$TERRARIA_SERVER_DIR/start-terraria.sh" "$TERRARIA_SERVER_DIR/tt-manager.sh" "$TERRARIA_SERVER_DIR/backup-cron.sh" "$TERRARIA_SERVER_DIR/setup-cron.sh"

    cat > "$TERRARIA_SERVER_DIR/comandos.sh" << EOF
#!/bin/bash
alias ttstart='sudo systemctl start terraria'
alias ttstop='sudo systemctl stop terraria'
alias ttrestart='sudo systemctl restart terraria'
alias ttstatus='sudo systemctl status terraria'
alias ttlogs='sudo journalctl -u terraria -f'
alias ttconsole='sudo $TERRARIA_SERVER_DIR/tt-manager.sh console'
alias ttbackup='sudo $TERRARIA_SERVER_DIR/tt-manager.sh backup'
alias ttdir='cd $TERRARIA_SERVER_DIR'
alias tthw='sudo $TERRARIA_SERVER_DIR/tt-manager.sh hardware-report'
alias ttreconfig='sudo $TERRARIA_SERVER_DIR/tt-manager.sh reconfigure-hardware'
EOF

    chmod +x "$TERRARIA_SERVER_DIR/comandos.sh"

    if ! is_true "$DRY_RUN"; then
        chown -R "${TERRARIA_USER}:${TERRARIA_USER}" "$TERRARIA_SERVER_DIR"
    fi
}

install_terraria_service() {
    print_step "Instalando servico systemd do Terraria..."

    if is_true "$DRY_RUN"; then
        sed \
            -e "s|__SERVER_USER__|$TERRARIA_USER|g" \
            -e "s|__SERVER_DIR__|$TERRARIA_SERVER_DIR|g" \
            -e "s|__MEMORY_MAX_MB__|$TT_SERVICE_MEMORY_MAX_MB|g" \
            "$MODULE_DIR/terraria.service" > "$TERRARIA_SERVER_DIR/terraria.service.rendered"
        print_step "[DRY_RUN] Unidade gerada em $TERRARIA_SERVER_DIR/terraria.service.rendered"
        return 0
    fi

    sed \
        -e "s|__SERVER_USER__|$TERRARIA_USER|g" \
        -e "s|__SERVER_DIR__|$TERRARIA_SERVER_DIR|g" \
        -e "s|__MEMORY_MAX_MB__|$TT_SERVICE_MEMORY_MAX_MB|g" \
        "$MODULE_DIR/terraria.service" > /etc/systemd/system/terraria.service

    systemctl daemon-reload
    systemctl enable terraria >/dev/null 2>&1 || true
}

apply_terraria_system_tuning() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando tuning de sistema compartilhado."
        return 0
    fi

    if is_true "$APPLY_SYSTEM_TUNING"; then
        print_step "Aplicando tuning de sistema compartilhado..."
        apply_common_system_tuning "$TERRARIA_USER" "$HW_TIER" "$HW_TOTAL_RAM_MB"
    fi
}

run_terraria_install() {
    print_step "Iniciando instalacao do stack Terraria..."
    install_terraria_dependencies
    create_terraria_user_and_dirs
    download_and_extract_terraria
    configure_terraria_runtime
    deploy_terraria_scripts
    install_terraria_service
    apply_terraria_system_tuning

    print_success "Terraria instalado com sucesso em $TERRARIA_SERVER_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_terraria_install
fi
