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
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/downloads.sh"

TERRARIA_USER="${TERRARIA_USER:-terraria}"
TERRARIA_SERVER_DIR="${TERRARIA_SERVER_DIR:-/opt/terraria-server}"
TERRARIA_PORT="${TERRARIA_PORT:-7777}"
TERRARIA_WORLD_NAME="${TERRARIA_WORLD_NAME:-world}"
TERRARIA_MOTD="${TERRARIA_MOTD:-Servidor Terraria gerenciado por Crias-Server}"
TERRARIA_DOWNLOAD_URL="${TERRARIA_DOWNLOAD_URL:-https://terraria.org/api/download/pc-dedicated-server/terraria-server-1456.zip}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
DRY_RUN="${DRY_RUN:-false}"

install_terraria_dependencies() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao de dependencias do Terraria."
        return 0
    fi

    print_step "Instalando dependencias do Terraria..."
    pacman -S --needed --noconfirm \
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
        lm_sensors
}

create_terraria_user_and_dirs() {
    print_step "Garantindo usuario e diretorio do Terraria..."

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando criacao do usuario e diretorio do Terraria."
        return 0
    fi

    if ! id "$TERRARIA_USER" >/dev/null 2>&1; then
        useradd -r -M -s /usr/bin/nologin -d "$TERRARIA_SERVER_DIR" "$TERRARIA_USER"
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
        print_step "[DRY_RUN] Pulando download e extracao do servidor Terraria."
        return 0
    fi

    print_step "Baixando servidor Terraria Vanilla..."
    tmp_zip=$(mktemp /tmp/terraria-server-XXXXXX.zip)
    tmp_dir=$(mktemp -d)

    if ! download_and_verify "$TERRARIA_DOWNLOAD_URL" "$tmp_zip" TERRARIA_SHA256; then
        print_error "Falha ao baixar/validar o servidor Terraria."
        print_error "Defina TERRARIA_DOWNLOAD_URL em config.env com um link valido e/ou TERRARIA_SHA256 para verificação."
        rm -f "$tmp_zip"
        safe_remove_dir "$tmp_dir" || true
        exit 1
    fi

    print_step "Extraindo servidor Terraria..."
    unzip -q -o -j "$tmp_zip" -d "$tmp_dir"

    binary_path=$(find "$tmp_dir" -type f -name "TerrariaServer.bin.x86_64" -print -quit)
    if [ -z "$binary_path" ]; then
        print_error "Nao foi possivel localizar TerrariaServer.bin.x86_64 no pacote baixado."
        rm -f "$tmp_zip"
        safe_remove_dir "$tmp_dir" || true
        exit 1
    fi

    if ! file "$binary_path" | grep -q 'ELF'; then
        print_error "O binario encontrado nao parece ser um executavel ELF valido."
        rm -f "$tmp_zip"
        safe_remove_dir "$tmp_dir" || true
        exit 1
    fi

    linux_dir=$(dirname "$binary_path")
    cp -r "$linux_dir"/. "$TERRARIA_SERVER_DIR"/

    chmod +x "$TERRARIA_SERVER_DIR/TerrariaServer.bin.x86_64"

    rm -f "$tmp_zip"
    safe_remove_dir "$tmp_dir" || true
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

    run_or_dry_run "Copiando start-terraria.sh do Terraria" cp "$MODULE_DIR/start-terraria.sh" "$TERRARIA_SERVER_DIR/start-terraria.sh"
    run_or_dry_run "Copiando tt-manager.sh do Terraria" cp "$MODULE_DIR/tt-manager.sh" "$TERRARIA_SERVER_DIR/tt-manager.sh"
    run_or_dry_run "Copiando backup-cron.sh do Terraria" cp "$MODULE_DIR/backup-cron.sh" "$TERRARIA_SERVER_DIR/backup-cron.sh"
    run_or_dry_run "Copiando setup-cron.sh do Terraria" cp "$MODULE_DIR/setup-cron.sh" "$TERRARIA_SERVER_DIR/setup-cron.sh"

    run_or_dry_run "Criando diretorio compartilhado do Terraria" mkdir -p "$TERRARIA_SERVER_DIR/.shared"
    run_or_dry_run "Copiando common.sh compartilhado do Terraria" cp "$ROOT_DIR/shared/lib/common.sh" "$TERRARIA_SERVER_DIR/.shared/common.sh"
    run_or_dry_run "Copiando manager-common.sh compartilhado do Terraria" cp "$ROOT_DIR/shared/lib/manager-common.sh" "$TERRARIA_SERVER_DIR/.shared/manager-common.sh"
    run_or_dry_run "Copiando hardware-profile.sh compartilhado do Terraria" cp "$ROOT_DIR/shared/lib/hardware-profile.sh" "$TERRARIA_SERVER_DIR/.shared/hardware-profile.sh"
    run_or_dry_run "Copiando terraria-tuning.sh compartilhado do Terraria" cp "$ROOT_DIR/shared/lib/terraria-tuning.sh" "$TERRARIA_SERVER_DIR/.shared/terraria-tuning.sh"

    run_or_dry_run "Marcando scripts do Terraria como executaveis" chmod +x "$TERRARIA_SERVER_DIR/start-terraria.sh" "$TERRARIA_SERVER_DIR/tt-manager.sh" "$TERRARIA_SERVER_DIR/backup-cron.sh" "$TERRARIA_SERVER_DIR/setup-cron.sh"

    write_file_or_dry_run "Gerando comandos do Terraria em $TERRARIA_SERVER_DIR/comandos.sh" "$TERRARIA_SERVER_DIR/comandos.sh" << EOF
#!/bin/bash
# Generated by Crias-Server installer - do not edit manually
## Generated aliases for Terraria
alias ttstart='sudo systemctl start terraria'
alias ttstop='sudo systemctl stop terraria'
alias ttrestart='sudo systemctl restart terraria'
# Use manager status for concise view
alias ttstatus='sudo $TERRARIA_SERVER_DIR/tt-manager.sh status'
alias ttlogs='sudo journalctl -u terraria -f'
alias ttconsole='sudo $TERRARIA_SERVER_DIR/tt-manager.sh console'
alias ttbackup='sudo $TERRARIA_SERVER_DIR/tt-manager.sh backup'
alias ttsetupcron='sudo $TERRARIA_SERVER_DIR/tt-manager.sh setup-cron'
alias ttdir='cd $TERRARIA_SERVER_DIR'
alias tthw='sudo $TERRARIA_SERVER_DIR/tt-manager.sh hardware-report'
alias ttreconfig='sudo $TERRARIA_SERVER_DIR/tt-manager.sh reconfigure-hardware'
EOF

    run_or_dry_run "Marcando comandos do Terraria como executavel" chmod +x "$TERRARIA_SERVER_DIR/comandos.sh"

    if ! dry_run_enabled; then
        chown -R "${TERRARIA_USER}:${TERRARIA_USER}" "$TERRARIA_SERVER_DIR"
    fi
}

install_terraria_service() {
    print_step "Instalando servico systemd do Terraria..."

    sed_escape_replacement() {
        printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
    }

    local escaped_user
    local escaped_dir
    local escaped_memory
    escaped_user="$(sed_escape_replacement "$TERRARIA_USER")"
    escaped_dir="$(sed_escape_replacement "$TERRARIA_SERVER_DIR")"
    escaped_memory="$(sed_escape_replacement "$TT_SERVICE_MEMORY_MAX_MB")"

    sed \
        -e "s|__SERVER_USER__|$escaped_user|g" \
        -e "s|__SERVER_DIR__|$escaped_dir|g" \
        -e "s|__MEMORY_MAX_MB__|$escaped_memory|g" \
        "$MODULE_DIR/terraria.service" | write_file_or_dry_run "Gerando unidade systemd do Terraria em /etc/systemd/system/terraria.service" "/etc/systemd/system/terraria.service"

    if dry_run_enabled; then
        return 0
    fi

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

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Instalacao do Terraria encerrada sem aplicar alteracoes."
        return 0
    fi

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
