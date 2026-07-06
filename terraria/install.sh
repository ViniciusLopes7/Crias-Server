#!/bin/bash
# terraria/install.sh
#
# Terraria stack installer using shared/lib/stack-installer.sh framework.

set -euo pipefail

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
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/stack-installer.sh"

# ---------------------------------------------------------------------------
# Stack config.
# ---------------------------------------------------------------------------
TERRARIA_USER="${TERRARIA_USER:-terraria}"
TERRARIA_SERVER_DIR="${TERRARIA_SERVER_DIR:-/opt/terraria-server}"
TERRARIA_PORT="${TERRARIA_PORT:-7777}"
TERRARIA_WORLD_NAME="${TERRARIA_WORLD_NAME:-world}"
TERRARIA_MOTD="${TERRARIA_MOTD:-Servidor Terraria gerenciado por Crias-Server}"
TERRARIA_DOWNLOAD_URL="${TERRARIA_DOWNLOAD_URL:-https://terraria.org/api/download/pc-dedicated-server/terraria-server-1456.zip}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
DRY_RUN="${DRY_RUN:-false}"
TERRARIA_SERVER_DIR_PREEXISTED="${TERRARIA_SERVER_DIR_PREEXISTED:-false}"
TERRARIA_INSTALL_SUCCEEDED="${TERRARIA_INSTALL_SUCCEEDED:-false}"

# ---------------------------------------------------------------------------
# stack-installer framework config. Variables read by shared/lib/stack-installer.sh.
# shellcheck disable=SC2034  # variables used by stack-installer.sh
# ---------------------------------------------------------------------------
STACK_NAME="terraria"
STACK_USER="$TERRARIA_USER"
STACK_SERVER_DIR="$TERRARIA_SERVER_DIR"
STACK_SERVICE_TEMPLATE="$MODULE_DIR/terraria.service"
STACK_RUNTIME_SCRIPTS=(
    "$MODULE_DIR/start-terraria.sh"
    "$MODULE_DIR/tt-manager.sh"
    "$MODULE_DIR/backup-cron.sh"
    "$MODULE_DIR/setup-cron.sh"
)
STACK_SHARED_LIBS=(
    "$ROOT_DIR/shared/lib/common.sh"
    "$ROOT_DIR/shared/lib/manager-common.sh"
    "$ROOT_DIR/shared/lib/hardware-profile.sh"
    "$ROOT_DIR/shared/lib/terraria-tuning.sh"
    "$ROOT_DIR/shared/lib/downloads.sh"
    "$ROOT_DIR/shared/lib/backup-engine.sh"
    "$ROOT_DIR/shared/lib/setup-cron.sh"
)

# ---------------------------------------------------------------------------
# Framework hooks.
# ---------------------------------------------------------------------------

stack_validate_inputs() {
    validate_terraria_inputs
}

validate_terraria_inputs() {
    if ! validate_port_number "TERRARIA_PORT" "$TERRARIA_PORT"; then
        exit 1
    fi
}

stack_install_dependencies() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao de dependencias do Terraria."
        return 0
    fi

    print_step "Instalando dependencias do Terraria..."
    pacman -S --needed --noconfirm \
        htop \
        iotop-c \
        nano \
        curl \
        wget \
        tar \
        gzip \
        unzip \
        gettext \
        zram-generator \
        cpupower \
        lm_sensors
}

stack_create_extra_dirs() {
    mkdir -p "$TERRARIA_SERVER_DIR/config" "$TERRARIA_SERVER_DIR/worlds"
}

stack_download_and_install() {
    download_and_extract_terraria
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
    # Use mktemp with namespace and .zip suffix for recognizable temp files.
    # trap RETURN ensures cleanup on early exit.
    tmp_zip="$(mktemp --suffix=.zip -t crias-terraria-XXXXXX)"
    tmp_dir="$(mktemp -d -t crias-terraria-XXXXXX)"
    # shellcheck disable=SC2064
    trap 'rm -f -- "$tmp_zip"; rm -rf -- "$tmp_dir"' RETURN

    # SHA256 required by default (TERRARIA_SHA256 in config.env).
    if ! download_and_verify "$TERRARIA_DOWNLOAD_URL" "$tmp_zip" TERRARIA_SHA256; then
        print_error "Falha ao baixar/validar o servidor Terraria."
        print_error "Defina TERRARIA_DOWNLOAD_URL em config.env com um link valido e TERRARIA_SHA256 (64 hex) com o checksum oficial."
        rm -f "$tmp_zip"
        safe_remove_dir "$tmp_dir" || true
        exit 1
    fi

    print_step "Extraindo servidor Terraria..."
    unzip -q -o "$tmp_zip" -d "$tmp_dir"

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

stack_configure_runtime() {
    print_step "Aplicando tuning automatico para Terraria..."

    detect_hardware_profile "$TERRARIA_SERVER_DIR" "$FORCE_HARDWARE_TIER"
    compute_terraria_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    # STACK_SERVICE_MEMORY_MAX_MB read by install_stack_service (stack-installer.sh).
    # shellcheck disable=SC2034
    STACK_SERVICE_MEMORY_MAX_MB="$TT_SERVICE_MEMORY_MAX_MB"

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

stack_generate_aliases() {
    cat << EOF
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
}

stack_rollback_extra_files() {
    cat << EOF
$TERRARIA_SERVER_DIR/start-terraria.sh
$TERRARIA_SERVER_DIR/tt-manager.sh
$TERRARIA_SERVER_DIR/backup-cron.sh
$TERRARIA_SERVER_DIR/setup-cron.sh
$TERRARIA_SERVER_DIR/comandos.sh
$TERRARIA_SERVER_DIR/runtime.env
$TERRARIA_SERVER_DIR/hardware-profile.env
EOF
}

# Alias preserving name used by root install.sh.
run_terraria_install() {
    run_stack_install
}

# Aliases for backward compat with legacy test functions
# (tests/arch-dry-install.sh calls deploy_terraria_scripts directly).
deploy_terraria_scripts() {
    deploy_stack_scripts
}

rollback_terraria_install() {
    rollback_stack_install
}

install_terraria_service() {
    install_stack_service
}

apply_terraria_system_tuning() {
    apply_stack_system_tuning
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_terraria_install
fi
