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
# tModLoader (WIP — v1.2.0). Nao implementado completamente; mantido como
# flag reservado para futura instalacao de mods no Terraria.
TERRARIA_USE_TMODLOADER="${TERRARIA_USE_TMODLOADER:-false}"
# Versão do tModLoader (tag do GitHub, ex.: v2026.06.3.6). Vazio = busca dinâmica.
TERRARIA_TMODLOADER_VERSION="${TERRARIA_TMODLOADER_VERSION:-}"
# Mods do tModLoader (CSV de Workshop IDs do Steam). Vazio = sem mods.
# O install.sh oferece um seletor TUI com catálogo curado (Calamity, Thorium, etc.).
TERRARIA_TMODLOADER_MODS="${TERRARIA_TMODLOADER_MODS:-}"
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
    "$ROOT_DIR/shared/lib/config-parser.sh"
    "$ROOT_DIR/shared/lib/hardware-profile.sh"
    "$ROOT_DIR/shared/lib/terraria-tuning.sh"
    "$ROOT_DIR/shared/lib/downloads.sh"
    "$ROOT_DIR/shared/lib/backup-engine.sh"
    "$ROOT_DIR/shared/lib/setup-cron.sh"
    "$ROOT_DIR/shared/lib/tmodloader.sh"
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
        zstd \
        gettext \
        zram-generator \
        cpupower \
        lm_sensors \
        jq
}

stack_create_extra_dirs() {
    mkdir -p "$TERRARIA_SERVER_DIR/config" "$TERRARIA_SERVER_DIR/worlds"
    # tModLoader usa Mods/ (capital M) e Worlds/ (capital W) sob o save dir.
    if is_true "$TERRARIA_USE_TMODLOADER"; then
        mkdir -p "$TERRARIA_SERVER_DIR/Mods" "$TERRARIA_SERVER_DIR/Worlds"
    fi
}

stack_download_and_install() {
    if is_true "$TERRARIA_USE_TMODLOADER"; then
        download_and_install_tmodloader
    else
        download_and_extract_terraria
    fi
}

# ---------------------------------------------------------------------------
# tModLoader: baixa release do GitHub, extrai em <server_dir>/server/, e
# cria Mods/ e Worlds/ (diretórios esperados pelo tModLoader).
# Substitui o binário vanilla: start-terraria.sh detecta qual rodar.
# ---------------------------------------------------------------------------
download_and_install_tmodloader() {
    local tml_version="${TERRARIA_TMODLOADER_VERSION:-}"
    local tml_zip
    local tmp_dir

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando download e instalacao do tModLoader."
        return 0
    fi

    print_step "Instalando tModLoader (Terraria com mods)..."

    if ! command -v unzip >/dev/null 2>&1; then
        print_error "unzip nao encontrado. Instale (pacman -S unzip)."
        exit 1
    fi

    # Busca versões dinamicamente se não especificada.
    if [ -z "$tml_version" ]; then
        print_step "Buscando versões do tModLoader (GitHub Releases)..."
        if ! has_internet; then
            print_error "Sem internet para buscar versões do tModLoader."
            print_error "Defina TERRARIA_TMODLOADER_VERSION em config.env ou conecte-se."
            exit 1
        fi

        # Source da lib tmodloader (pode não estar carregada se install.sh terraria roda standalone).
        if ! declare -F tml_get_versions >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            source "$ROOT_DIR/shared/lib/tmodloader.sh"
        fi

        local versions
        if ! versions=$(tml_get_versions 0) || [ -z "$versions" ]; then
            print_error "Falha ao buscar versões do tModLoader."
            exit 1
        fi

        # Em NON_INTERACTIVE, pega a primeira (mais recente).
        if is_true "${NON_INTERACTIVE:-false}"; then
            tml_version=$(printf '%s\n' "$versions" | head -1)
        else
            # Em modo interativo, o install.sh já perguntou via TUI.
            # Se ainda vazio (TUI não rodou ou cancelou), usa mais recente.
            if [ -z "$tml_version" ]; then
                tml_version=$(printf '%s\n' "$versions" | head -1)
            fi
        fi
        print_step "Versão tModLoader selecionada: $tml_version"
    fi

    TERRARIA_TMODLOADER_VERSION="$tml_version"

    # Busca a URL de download do asset tModLoader.zip para essa versão.
    local releases_json
    releases_json=$(tml_fetch_releases) || true
    if [ -z "$releases_json" ]; then
        print_error "Falha ao buscar releases do tModLoader do GitHub."
        exit 1
    fi

    local tml_url
    tml_url=$(tml_extract_download_url "$releases_json" "$tml_version")
    if [ -z "$tml_url" ]; then
        print_error "Asset tModLoader.zip não encontrado para versão $tml_version."
        print_error "URL tentada: $tml_url"
        exit 1
    fi

    print_step "Baixando tModLoader de: $tml_url"
    tml_zip="$(mktemp_crias_file)"
    tmp_dir="$(mktemp_crias_dir)"

    if ! _curl_with_retry "$tml_url" "$tml_zip"; then
        print_error "Falha ao baixar tModLoader de $tml_url"
        exit 1
    fi

    print_step "Extraindo tModLoader em $TERRARIA_SERVER_DIR/server/..."
    mkdir -p "$TERRARIA_SERVER_DIR/server"
    unzip -q -o "$tml_zip" -d "$TERRARIA_SERVER_DIR/server/"

    # Cria diretórios esperados pelo tModLoader (-tmlsavedirectory aponta para $TERRARIA_SERVER_DIR).
    mkdir -p "$TERRARIA_SERVER_DIR/Mods" "$TERRARIA_SERVER_DIR/Worlds"

    # Instala dependências do .NET (tModLoader é self-contained, mas precisa de libs do sistema).
    print_step "Instalando dependências do .NET 8 para tModLoader..."
    pacman -S --needed --noconfirm icu krb5 zlib 2>/dev/null || \
        print_warning "Algumas deps do .NET podem não ter instalado; verifique manualmente."

    rm -f "$tml_zip"
    safe_remove_dir "$tmp_dir" || true

    print_success "tModLoader $tml_version instalado em $TERRARIA_SERVER_DIR/server/"
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
    tmp_zip="$(mktemp_crias_file)"
    tmp_dir="$(mktemp_crias_dir)"

    if ! _curl_with_retry "$TERRARIA_DOWNLOAD_URL" "$tmp_zip"; then
        print_error "Falha ao baixar o servidor Terraria de $TERRARIA_DOWNLOAD_URL"
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
$TERRARIA_SERVER_DIR/server
$TERRARIA_SERVER_DIR/Mods
$TERRARIA_SERVER_DIR/Worlds
$TERRARIA_SERVER_DIR/steamapps
EOF
}

# ---------------------------------------------------------------------------
# tModLoader: instala mods via SteamCMD (hook chamado pelo stack-installer
# entre stack_download_and_install e stack_configure_runtime).
# ---------------------------------------------------------------------------
stack_install_mods() {
    if ! is_true "$TERRARIA_USE_TMODLOADER"; then
        return 0
    fi

    if [ -z "${TERRARIA_TMODLOADER_MODS:-}" ]; then
        print_step "Nenhum mod do tModLoader selecionado (TERRARIA_TMODLOADER_MODS vazio)."
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando download de mods do tModLoader."
        return 0
    fi

    # Source da lib tmodloader se não carregada.
    if ! declare -F tml_download_mods >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$ROOT_DIR/shared/lib/tmodloader.sh"
    fi

    if ! tml_steamcmd_available; then
        print_warning "steamcmd nao encontrado. Mods do tModLoader NAO serao baixados."
        print_warning "Instale steamcmd (AUR: steamcmd) para usar mods automaticamente."
        print_warning "Voce pode baixar mods manualmente e colocar em $TERRARIA_SERVER_DIR/Mods/"
        # Mesmo sem steamcmd, gera enabled.json/install.txt para auditoria.
        _tml_write_mod_files "$TERRARIA_SERVER_DIR/Mods" "$TERRARIA_TMODLOADER_MODS"
        return 0
    fi

    print_step "Baixando mods do tModLoader via SteamCMD..."
    if ! tml_download_mods "$TERRARIA_SERVER_DIR" "$TERRARIA_TMODLOADER_MODS"; then
        print_warning "Algum mod pode ter falhado ao baixar. Verifique os logs do steamcmd."
    fi

    # Gera enabled.json e install.txt com os mods selecionados.
    _tml_write_mod_files "$TERRARIA_SERVER_DIR/Mods" "$TERRARIA_TMODLOADER_MODS"
    print_success "Mods instalados em $TERRARIA_SERVER_DIR/Mods/"
}

# Helper: gera enabled.json (internal names) e install.txt (workshop IDs).
# Recebe CSV de Workshop IDs e mapeia para internal_names via catálogo.
_tml_write_mod_files() {
    local mods_dir="$1"
    local workshop_ids_csv="$2"

    if ! declare -F tml_write_enabled_json >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$ROOT_DIR/shared/lib/tmodloader.sh" 2>/dev/null || return 0
    fi

    # Mapeia workshop_id -> internal_name usando o catálogo.
    local internal_names=""
    local first=1
    local IFS=','
    local wid
    for wid in $workshop_ids_csv; do
        [ -z "$wid" ] && continue
        local iname=""
        iname=$(tml_mod_catalog | while IFS='|' read -r w i n d; do
            if [ "$w" = "$wid" ]; then
                printf '%s' "$i"
                return 0
            fi
        done)
        if [ -n "$iname" ]; then
            if [ "$first" -eq 1 ]; then
                internal_names="$iname"
                first=0
            else
                internal_names="$internal_names,$iname"
            fi
        fi
    done
    unset IFS

    tml_write_enabled_json "$mods_dir" "$internal_names"
    tml_write_install_txt "$mods_dir" "$workshop_ids_csv"
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
