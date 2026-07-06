#!/bin/bash
# minecraft/install.sh
#
# Minecraft stack installer using shared/lib/stack-installer.sh framework.

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
source "$ROOT_DIR/shared/lib/minecraft-tuning.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/downloads.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/stack-installer.sh"

# ---------------------------------------------------------------------------
# Stack config (env variables with defaults).
# ---------------------------------------------------------------------------
MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_SERVER_DIR="${MINECRAFT_SERVER_DIR:-/opt/minecraft-server}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"
MINECRAFT_ONLINE_MODE="${MINECRAFT_ONLINE_MODE:-false}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
MINECRAFT_INSTALL_MODPACK="${MINECRAFT_INSTALL_MODPACK:-true}"
MINECRAFT_ADRENALINE_VERSION="${MINECRAFT_ADRENALINE_VERSION:-}"
MINECRAFT_INSTALL_QOL_MODS="${MINECRAFT_INSTALL_QOL_MODS:-true}"
MINECRAFT_MOTD="${MINECRAFT_MOTD:-§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r}"
# QoL mods and modpack source config.
# CSV of Modrinth slugs as "file_name:slug,file_name:slug,...".
# E.g.: "chunky:chunky,essential-commands:essential-commands"
MINECRAFT_QOL_MODS="${MINECRAFT_QOL_MODS:-chunky:chunky,essential-commands:essential-commands,universal-graves:universal-graves,tabtps:tabtps,styled-chat:styled-chat,polymer:polymer,placeholder-api:placeholder-api}"
# Modpack source: "adrenaline" (default) or "modrinth" (generic).
MINECRAFT_MODPACK_SOURCE="${MINECRAFT_MODPACK_SOURCE:-adrenaline}"
MINECRAFT_MODPACK_SLUG="${MINECRAFT_MODPACK_SLUG:-adrenaline}"
# Pinned mrpack-install version + checksum.
# MRPACK_INSTALL_SHA256 is required for non-DRY_RUN installs; empty default
# forces download_and_verify to fail with code 3 (missing checksum).
MRPACK_INSTALL_VERSION="${MRPACK_INSTALL_VERSION:-v0.21.0-beta}"
MRPACK_INSTALL_SHA256="${MRPACK_INSTALL_SHA256:-}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
DRY_RUN="${DRY_RUN:-false}"
MINECRAFT_SERVER_DIR_PREEXISTED="${MINECRAFT_SERVER_DIR_PREEXISTED:-false}"
MINECRAFT_INSTALL_SUCCEEDED="${MINECRAFT_INSTALL_SUCCEEDED:-false}"

# ---------------------------------------------------------------------------
# stack-installer framework config. Variables read by shared/lib/stack-installer.sh.
# shellcheck disable=SC2034  # variables used by stack-installer.sh
# ---------------------------------------------------------------------------
STACK_NAME="minecraft"
STACK_USER="$MINECRAFT_USER"
STACK_SERVER_DIR="$MINECRAFT_SERVER_DIR"
STACK_SERVICE_TEMPLATE="$MODULE_DIR/minecraft.service"
STACK_RUNTIME_SCRIPTS=(
    "$MODULE_DIR/start-server.sh"
    "$MODULE_DIR/mc-manager.sh"
    "$MODULE_DIR/backup-cron.sh"
    "$MODULE_DIR/setup-cron.sh"
)
STACK_SHARED_LIBS=(
    "$ROOT_DIR/shared/lib/common.sh"
    "$ROOT_DIR/shared/lib/manager-common.sh"
    "$ROOT_DIR/shared/lib/hardware-profile.sh"
    "$ROOT_DIR/shared/lib/minecraft-tuning.sh"
    "$ROOT_DIR/shared/lib/downloads.sh"
    "$ROOT_DIR/shared/lib/backup-engine.sh"
    "$ROOT_DIR/shared/lib/setup-cron.sh"
)

# ---------------------------------------------------------------------------
# Framework hooks.
# ---------------------------------------------------------------------------

# Validate inputs.
stack_validate_inputs() {
    validate_minecraft_inputs
    validate_minecraft_eula
}

validate_minecraft_inputs() {
    case "$MINECRAFT_LOADER" in
        fabric|quilt|paper|vanilla|forge|neoforge)
            ;;
        *)
            print_error "MINECRAFT_LOADER invalido: $MINECRAFT_LOADER"
            print_error "Use: fabric, quilt, paper, vanilla, forge ou neoforge."
            exit 1
            ;;
    esac

    if ! [[ "$MINECRAFT_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        print_error "MINECRAFT_VERSION invalido: $MINECRAFT_VERSION"
        print_error "Use formato semantico (ex.: 1.21.11)."
        exit 1
    fi

    if ! validate_port_number "MINECRAFT_PORT" "$MINECRAFT_PORT"; then
        exit 1
    fi

    if is_true "$MINECRAFT_INSTALL_MODPACK" && [ "$MINECRAFT_LOADER" != "fabric" ]; then
        print_warning "Adrenaline e otimizado para Fabric. Loader atual: $MINECRAFT_LOADER"
        if is_true "${NON_INTERACTIVE:-false}"; then
            print_warning "Mantendo loader informado por estar em modo non-interactive."
        else
            if ask_confirm "Trocar loader para fabric para maximizar compatibilidade do modpack?" "Y"; then
                MINECRAFT_LOADER="fabric"
            fi
        fi
    fi
}

validate_minecraft_eula() {
    # Require explicit EULA acceptance even in DRY_RUN.
    if is_true "${NON_INTERACTIVE:-false}"; then
        if ! is_true "${ACCEPT_EULA:-false}"; then
            print_error "ACCEPT_EULA must be set to true in non-interactive mode to accept Mojang EULA. Aborting."
            exit 1
        fi
        return 0
    fi

    echo "Para mais informacoes sobre a EULA da Mojang, visite:"
    echo "https://account.mojang.com/documents/minecraft_eula"
    echo ""
    if ! ask_confirm "Aceitar EULA da Mojang?" "N"; then
        print_error "EULA nao aceita. Instalacao abortada."
        exit 1
    fi
}

stack_install_dependencies() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao de dependencias do Minecraft."
        return 0
    fi

    print_step "Instalando dependencias do Minecraft..."
    pacman -S --needed --noconfirm \
        jdk21-openjdk \
        htop \
        iotop-c \
        nano \
        curl \
        wget \
        tar \
        gzip \
        unzip \
        gettext \
        logrotate \
        zram-generator \
        cpupower \
        lm_sensors \
        jq
}

# Pinned mrpack-install version + checksum.
# Releases provide .pkg.tar.zst, .tar.gz, .deb, .rpm, .apk assets.
# We download the .tar.gz linux amd64 and extract the binary.
install_mrpack_install() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do mrpack-install."
        return 0
    fi

    print_step "Instalando mrpack-install (versao pinada: $MRPACK_INSTALL_VERSION)..."

    # Preference 1: native Arch package (.pkg.tar.zst) from repo.
    if pacman -Si mrpack-install >/dev/null 2>&1; then
        print_step "Pacote mrpack-install encontrado no repositorio. Instalando via pacman..."
        pacman -S --needed --noconfirm mrpack-install
        return 0
    fi

    # Preference 2: .pkg.tar.zst from GitHub release (idiomatic on Arch).
    local arch_pkg_url="https://github.com/nothub/mrpack-install/releases/download/${MRPACK_INSTALL_VERSION}/mrpack-install_${MRPACK_INSTALL_VERSION#v}_linux_amd64.pkg.tar.zst"

    # Fallback: linux amd64 tarball with loose binary inside.
    local tarball_url="https://github.com/nothub/mrpack-install/releases/download/${MRPACK_INSTALL_VERSION}/mrpack-install_${MRPACK_INSTALL_VERSION#v}_linux_amd64.tar.gz"

    # Use mktemp -d for private temp dir; trap RETURN ensures cleanup.
    local mrpack_tmp_dir
    mrpack_tmp_dir="$(mktemp -d -t crias-mrpack-XXXXXX)"
    # shellcheck disable=SC2064
    trap 'rm -rf -- "$mrpack_tmp_dir"' RETURN

    local arch_pkg_local="${mrpack_tmp_dir}/mrpack-install.pkg"
    local tarball_local="${mrpack_tmp_dir}/mrpack-install-bin.tgz"

    # Try .pkg.tar.zst first (clean install via pacman -U).
    # pacman validates .pkg.tar.zst integrity.
    if curl -fsSL --connect-timeout 10 --max-time 60 -o "$arch_pkg_local.zst" "$arch_pkg_url" 2>/dev/null; then
        if pacman -U --noconfirm "$arch_pkg_local.zst"; then
            print_success "mrpack-install instalado via pacman -U (.pkg.tar.zst)"
            return 0
        fi
        print_warning "pacman -U falhou para .pkg.tar.zst; tentando tarball com binario solto."
        rm -f "$arch_pkg_local.zst"
    fi

    # Fallback: download linux amd64 tarball, verify SHA256, extract binary.
    if ! download_and_verify "$tarball_url" "$tarball_local" MRPACK_INSTALL_SHA256; then
        print_error "Falha ao baixar/validar mrpack-install $MRPACK_INSTALL_VERSION"
        print_error "URL tentada: $tarball_url"
        print_error "Verifique MRPACK_INSTALL_VERSION e MRPACK_INSTALL_SHA256 em config.env."
        print_error "Para obter o SHA256 oficial:"
        print_error "  curl -fsSL $tarball_url | sha256sum"
        exit 1
    fi

    # Extract only the 'mrpack-install' binary from the tarball.
    local tmp_extract_dir="${mrpack_tmp_dir}/extract"
    mkdir -p "$tmp_extract_dir"
    if ! tar -xzf "$tarball_local" -C "$tmp_extract_dir"; then
        print_error "Falha ao extrair mrpack-install tarball"
        exit 1
    fi

    if [ ! -f "$tmp_extract_dir/mrpack-install" ]; then
        print_error "Binario 'mrpack-install' nao encontrado no tarball extraido."
        print_error "Conteudo do tarball:"
        ls -la "$tmp_extract_dir" >&2
        exit 1
    fi

    install -m 755 "$tmp_extract_dir/mrpack-install" /usr/local/bin/mrpack-install
    print_success "mrpack-install instalado em /usr/local/bin/mrpack-install"
}

stack_download_and_install() {
    print_step "Instalando base do servidor Minecraft..."

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao base do Minecraft."
        return 0
    fi

    install_mrpack_install

    cd "$MINECRAFT_SERVER_DIR" || exit 1

    # Modpack source selectable via config.
    case "$MINECRAFT_MODPACK_SOURCE" in
        adrenaline)
            if [ -n "$MINECRAFT_ADRENALINE_VERSION" ]; then
                timeout 300 mrpack-install adrenaline "$MINECRAFT_ADRENALINE_VERSION" --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
            else
                timeout 300 mrpack-install adrenaline --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
            fi
            ;;
        modrinth)
            # Generic modpack via Modrinth slug.
            local slug="${MINECRAFT_MODPACK_SLUG:-adrenaline}"
            timeout 300 mrpack-install "$slug" --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
            ;;
        vanilla)
            timeout 300 mrpack-install "$MINECRAFT_LOADER" "$MINECRAFT_VERSION" --server-dir "$MINECRAFT_SERVER_DIR" --server-file server.jar
            ;;
        *)
            print_error "MINECRAFT_MODPACK_SOURCE invalido: $MINECRAFT_MODPACK_SOURCE (use: adrenaline, modrinth, vanilla)"
            exit 1
            ;;
    esac

    echo "eula=true" > "$MINECRAFT_SERVER_DIR/eula.txt"
}

# QoL mods via CSV in config.env (MINECRAFT_QOL_MODS).
stack_install_qol_mods() {
    install_minecraft_qol_mods
}

# Legacy name kept for tests/quick-script-tests.sh compatibility.
install_minecraft_qol_mods() {
    if ! is_true "$MINECRAFT_INSTALL_QOL_MODS"; then
        return 0
    fi

    if [ "$MINECRAFT_LOADER" != "fabric" ] && [ "$MINECRAFT_LOADER" != "quilt" ]; then
        print_warning "Mods QoL pulados para loader $MINECRAFT_LOADER"
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao dos mods QoL do Minecraft."
        return 0
    fi

    if [ -d "$MINECRAFT_SERVER_DIR/mods" ] && [ -n "$(ls -A "$MINECRAFT_SERVER_DIR/mods" 2>/dev/null || true)" ]; then
        print_warning "Diretorio mods/ ja existe e contem arquivos. Pulando QoL para evitar conflitos."
        print_warning "Se quiser reinstalar QoL, limpe os .jar manualmente antes de rodar novamente."
        return 0
    fi

    print_step "Instalando mods QoL..."
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"

    # Parse CSV "file_name:slug,file_name:slug,...".
    # set -f prevents glob expansion (defensive).
    local entry file_name slug
    local IFS=','
    set -f
    for entry in $MINECRAFT_QOL_MODS; do
        file_name="${entry%%:*}"
        slug="${entry#*:}"
        # Fallback: if no ":", file_name == slug.
        if [ -z "$slug" ] || [ "$slug" = "$entry" ]; then
            slug="$file_name"
        fi

        # Validate file_name and slug against path traversal.
        local _bad_part=""
        if [[ "$file_name" == *..* ]] || [[ "$file_name" == */* ]] || [[ "$file_name" == *$'\0'* ]]; then
            _bad_part="file_name='$file_name'"
        elif [[ "$slug" == *..* ]] || [[ "$slug" == */* ]] || [[ "$slug" == *$'\0'* ]]; then
            _bad_part="slug='$slug'"
        fi
        if [ -n "$_bad_part" ]; then
            print_error "Mod QoL rejeitado (possível path traversal): $_bad_part"
            continue
        fi

        download_qol_mod "$file_name" "$slug"
    done
    set +f
}

# Legacy name kept for tests/quick-script-tests.sh compatibility.
download_qol_mod() {
    local file_name="$1"
    local slug="$2"
    local mod_sha_var
    # Normalize mod name: hyphens -> underscores to derive valid env var.
    local file_name_norm
    file_name_norm="${file_name//-/_}"
    mod_sha_var="MOD_${file_name_norm^^}_SHA256"

    if ! download_modrinth_mod "$slug" "$MINECRAFT_LOADER" "$MINECRAFT_VERSION" "$MINECRAFT_SERVER_DIR/mods" "$file_name" "$mod_sha_var"; then
        return 0  # warning already emitted inside helper
    fi
}

stack_configure_runtime() {
    print_step "Aplicando tuning automatico para Minecraft..."

    detect_hardware_profile "$MINECRAFT_SERVER_DIR" "$FORCE_HARDWARE_TIER"
    compute_minecraft_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    # STACK_SERVICE_MEMORY_MAX_MB read by install_stack_service (stack-installer.sh).
    # shellcheck disable=SC2034
    STACK_SERVICE_MEMORY_MAX_MB="$MC_SERVICE_MEMORY_MAX_MB"

    write_minecraft_runtime_env "$MINECRAFT_SERVER_DIR/runtime.env"
    write_minecraft_server_properties "$MINECRAFT_SERVER_DIR/server.properties" "$MINECRAFT_PORT" "$MINECRAFT_ONLINE_MODE" "$MINECRAFT_MOTD"
    write_minecraft_tuning_state "$MINECRAFT_SERVER_DIR/hardware-profile.env"

    write_minecraft_extra_configs

    print_success "Tier detectado: $HW_DETECTED_TIER | Tier aplicado: $HW_TIER"
    print_success "Heap aplicado: $MC_MIN_RAM -> $MC_MAX_RAM"
}

write_minecraft_extra_configs() {
    run_or_dry_run "Criando diretorios de configuracao do Minecraft" mkdir -p "$MINECRAFT_SERVER_DIR/config/essentialcommands" "$MINECRAFT_SERVER_DIR/config/universal_graves"

    if [ ! -f "$MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" ]; then
        write_file_or_dry_run "Gerando config do Essential Commands em $MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" "$MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" << 'EOF'
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
        write_file_or_dry_run "Gerando config do Universal Graves em $MINECRAFT_SERVER_DIR/config/universal_graves/config.json" "$MINECRAFT_SERVER_DIR/config/universal_graves/config.json" << 'EOF'
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

# Legacy name kept for tests/quick-script-tests.sh compatibility.
install_minecraft_logrotate_config() {
    stack_install_logrotate
}

stack_install_logrotate() {
    local logrotate_conf="/etc/logrotate.d/crias-minecraft"

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao de logrotate do Minecraft."
        return 0
    fi

    print_step "Configurando logrotate do Minecraft..."
    mkdir -p "$(dirname "$logrotate_conf")"

    cat > "$logrotate_conf" << EOF
$MINECRAFT_SERVER_DIR/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

stack_create_extra_dirs() {
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"
}

stack_deploy_extra_assets() {
    # Deploy server icon if available.
    if [ -f "$ROOT_DIR/assets/images/branding/server-icon.png" ]; then
        run_or_dry_run "Copiando server icon para $MINECRAFT_SERVER_DIR/server-icon.png" cp "$ROOT_DIR/assets/images/branding/server-icon.png" "$MINECRAFT_SERVER_DIR/server-icon.png"
        if ! dry_run_enabled; then
            print_success "Server icon deploiement: $MINECRAFT_SERVER_DIR/server-icon.png"
        fi
    fi
}

stack_generate_aliases() {
    cat << EOF
#!/bin/bash
# Generated by Crias-Server installer - do not edit manually
## Generated aliases for Minecraft
alias mcstart='sudo systemctl start minecraft'
alias mcstop='sudo systemctl stop minecraft'
alias mcrestart='sudo systemctl restart minecraft'
# Prefer concise status via manager for clarity
alias mcstatus='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh status'
alias mclogs='sudo journalctl -u minecraft -f'
# Run manager commands directly as the server user
alias mcconsole='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh console'
alias mcbackup='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh backup'
alias mcsetupcron='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh setup-cron'
alias mcdir='cd $MINECRAFT_SERVER_DIR'
alias mcprops='sudo nano $MINECRAFT_SERVER_DIR/server.properties'
alias mchw='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh hardware-report'
alias mcreconfig='sudo $MINECRAFT_SERVER_DIR/mc-manager.sh reconfigure-hardware'
EOF
}

stack_rollback_extra_files() {
    cat << EOF
$MINECRAFT_SERVER_DIR/start-server.sh
$MINECRAFT_SERVER_DIR/mc-manager.sh
$MINECRAFT_SERVER_DIR/backup-cron.sh
$MINECRAFT_SERVER_DIR/setup-cron.sh
$MINECRAFT_SERVER_DIR/server-icon.png
$MINECRAFT_SERVER_DIR/eula.txt
EOF
}

# Alias preserving name used by root install.sh.
run_minecraft_install() {
    run_stack_install
}

# Aliases for backward compat with legacy test functions
# (tests/arch-dry-install.sh calls deploy_minecraft_scripts directly).
deploy_minecraft_scripts() {
    deploy_stack_scripts
}

rollback_minecraft_install() {
    rollback_stack_install
}

install_minecraft_service() {
    install_stack_service
}

apply_minecraft_system_tuning() {
    apply_stack_system_tuning
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_minecraft_install
fi
