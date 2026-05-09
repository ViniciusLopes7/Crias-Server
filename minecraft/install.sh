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
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/downloads.sh"

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

    print_step "Instalando dependencias do Minecraft..."
    pacman -S --needed --noconfirm \
        jdk21-openjdk \
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
        jq
}

create_minecraft_user_and_dirs() {
    print_step "Garantindo usuario e diretorio do Minecraft..."

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando criacao do usuario e diretorio do Minecraft."
        return 0
    fi

    if ! id "$MINECRAFT_USER" >/dev/null 2>&1; then
        useradd -r -M -s /usr/bin/nologin -d "$MINECRAFT_SERVER_DIR" "$MINECRAFT_USER"
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
    mrpack_url=$(curl -fsSL --connect-timeout 10 --max-time 60 https://api.github.com/repos/nothub/mrpack-install/releases/latest | jq -r '.assets[] | select(.name=="mrpack-install-linux") | .browser_download_url')

    if [ -z "$mrpack_url" ] || [ "$mrpack_url" = "null" ]; then
        mrpack_url="https://github.com/nothub/mrpack-install/releases/latest/download/mrpack-install-linux"
    fi

    # Require explicit checksum for downloads outside the package manager to
    # reduce supply-chain risk. If MRPACK_SHA256 is not provided, abort in
    # non-interactive mode; otherwise ask the operator to confirm.
    if [ -z "${MRPACK_SHA256:-}" ]; then
        if is_true "$NON_INTERACTIVE"; then
            print_error "MRPACK_SHA256 nao definido. Em modo nao-interativo, cancela por seguranca. Defina MRPACK_SHA256 em config.env ou use AUR." 
            exit 1
        else
            print_warning "MRPACK_SHA256 nao definido. Isso aumenta o risco de supply-chain ao baixar binarios diretamente." 
            if ! ask_confirm "Continuar sem checagem de checksum para mrpack-install?" "N"; then
                print_error "Instalacao do mrpack-install cancelada pelo usuario por falta de checksum." 
                exit 1
            fi
        fi
    fi

    if ! download_and_verify "$mrpack_url" /tmp/mrpack-install MRPACK_SHA256; then
        print_error "Falha ao baixar/validar mrpack-install"
        exit 1
    fi
    install -m 755 /tmp/mrpack-install /usr/local/bin/mrpack-install
}

install_minecraft_base() {
    print_step "Instalando base do servidor Minecraft..."

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao base do Minecraft."
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

    # Write EULA file.
    echo "eula=true" > "$MINECRAFT_SERVER_DIR/eula.txt"
}

download_qol_mod() {
    local file_name="$1"
    local slug="$2"
    local api_url
    local mod_url

    api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$MINECRAFT_LOADER%22%5D&game_versions=%5B%22$MINECRAFT_VERSION%22%5D"
    mod_url=$(curl -fsSL --connect-timeout 10 --max-time 30 "$api_url" | jq -r '.[0].files[0].url // empty')

    if [ -z "$mod_url" ]; then
        mod_url=$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$MINECRAFT_LOADER%22%5D" | jq -r '.[0].files[0].url // empty')
    fi

    if [ -n "$mod_url" ]; then
        # Allow per-mod SHA env var like MOD_CHUNKY_SHA256
        local mod_sha_var
        # Normalize mod name: replace hyphens with underscores so the derived
        # env var is a valid shell identifier (hyphens are not allowed).
        local file_name_norm
        file_name_norm="${file_name//-/_}"
        mod_sha_var="MOD_${file_name_norm^^}_SHA256"
        if ! download_and_verify "$mod_url" "$MINECRAFT_SERVER_DIR/mods/${file_name}.jar" "$mod_sha_var"; then
            print_warning "Falha ao baixar/validar mod: ${file_name}, pulando."
        else
            print_success "Mod instalado: ${file_name}.jar"
        fi
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

    download_qol_mod "chunky" "chunky"
    download_qol_mod "essential-commands" "essential-commands"
    download_qol_mod "universal-graves" "universal-graves"
    download_qol_mod "tabtps" "tabtps"
    download_qol_mod "styled-chat" "styled-chat"
    download_qol_mod "polymer" "polymer"
    download_qol_mod "placeholder-api" "placeholder-api"
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

configure_minecraft_runtime() {
    print_step "Aplicando tuning automatico para Minecraft..."

    detect_hardware_profile "$MINECRAFT_SERVER_DIR" "$FORCE_HARDWARE_TIER"
    compute_minecraft_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_minecraft_runtime_env "$MINECRAFT_SERVER_DIR/runtime.env"
    write_minecraft_server_properties "$MINECRAFT_SERVER_DIR/server.properties" "$MINECRAFT_PORT" "$MINECRAFT_ONLINE_MODE" "$MINECRAFT_MOTD"
    write_minecraft_tuning_state "$MINECRAFT_SERVER_DIR/hardware-profile.env"

    write_minecraft_extra_configs

    print_success "Tier detectado: $HW_DETECTED_TIER | Tier aplicado: $HW_TIER"
    print_success "Heap aplicado: $MC_MIN_RAM -> $MC_MAX_RAM"
}

deploy_minecraft_scripts() {
    print_step "Copiando scripts do modulo Minecraft..."

    run_or_dry_run "Copiando start-server.sh do Minecraft" cp "$MODULE_DIR/start-server.sh" "$MINECRAFT_SERVER_DIR/start-server.sh"
    run_or_dry_run "Copiando mc-manager.sh do Minecraft" cp "$MODULE_DIR/mc-manager.sh" "$MINECRAFT_SERVER_DIR/mc-manager.sh"
    run_or_dry_run "Copiando backup-cron.sh do Minecraft" cp "$MODULE_DIR/backup-cron.sh" "$MINECRAFT_SERVER_DIR/backup-cron.sh"
    run_or_dry_run "Copiando setup-cron.sh do Minecraft" cp "$MODULE_DIR/setup-cron.sh" "$MINECRAFT_SERVER_DIR/setup-cron.sh"

    run_or_dry_run "Criando diretorio compartilhado do Minecraft" mkdir -p "$MINECRAFT_SERVER_DIR/.shared"
    run_or_dry_run "Copiando common.sh compartilhado do Minecraft" cp "$ROOT_DIR/shared/lib/common.sh" "$MINECRAFT_SERVER_DIR/.shared/common.sh"
    run_or_dry_run "Copiando manager-common.sh compartilhado do Minecraft" cp "$ROOT_DIR/shared/lib/manager-common.sh" "$MINECRAFT_SERVER_DIR/.shared/manager-common.sh"
    run_or_dry_run "Copiando hardware-profile.sh compartilhado do Minecraft" cp "$ROOT_DIR/shared/lib/hardware-profile.sh" "$MINECRAFT_SERVER_DIR/.shared/hardware-profile.sh"
    run_or_dry_run "Copiando minecraft-tuning.sh compartilhado do Minecraft" cp "$ROOT_DIR/shared/lib/minecraft-tuning.sh" "$MINECRAFT_SERVER_DIR/.shared/minecraft-tuning.sh"

    run_or_dry_run "Marcando scripts do Minecraft como executaveis" chmod +x "$MINECRAFT_SERVER_DIR/start-server.sh" "$MINECRAFT_SERVER_DIR/mc-manager.sh" "$MINECRAFT_SERVER_DIR/backup-cron.sh" "$MINECRAFT_SERVER_DIR/setup-cron.sh"

    # Deploy server icon if available
    if [ -f "$ROOT_DIR/assets/images/branding/server-icon.png" ]; then
        run_or_dry_run "Copiando server icon para $MINECRAFT_SERVER_DIR/server-icon.png" cp "$ROOT_DIR/assets/images/branding/server-icon.png" "$MINECRAFT_SERVER_DIR/server-icon.png"
        if ! dry_run_enabled; then
            print_success "Server icon deploiement: $MINECRAFT_SERVER_DIR/server-icon.png"
        fi
    fi

    write_file_or_dry_run "Gerando comandos do Minecraft em $MINECRAFT_SERVER_DIR/comandos.sh" "$MINECRAFT_SERVER_DIR/comandos.sh" << EOF
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

    run_or_dry_run "Marcando comandos do Minecraft como executavel" chmod +x "$MINECRAFT_SERVER_DIR/comandos.sh"

    if ! dry_run_enabled; then
        chown -R "${MINECRAFT_USER}:${MINECRAFT_USER}" "$MINECRAFT_SERVER_DIR"
    fi
}

install_minecraft_service() {
    print_step "Instalando servico systemd do Minecraft..."

    sed_escape_replacement() {
        printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
    }

    local escaped_user
    local escaped_dir
    local escaped_memory
    escaped_user="$(sed_escape_replacement "$MINECRAFT_USER")"
    escaped_dir="$(sed_escape_replacement "$MINECRAFT_SERVER_DIR")"
    escaped_memory="$(sed_escape_replacement "$MC_SERVICE_MEMORY_MAX_MB")"

    sed \
        -e "s|__SERVER_USER__|$escaped_user|g" \
        -e "s|__SERVER_DIR__|$escaped_dir|g" \
        -e "s|__MEMORY_MAX_MB__|$escaped_memory|g" \
        "$MODULE_DIR/minecraft.service" | write_file_or_dry_run "Gerando unidade systemd do Minecraft em /etc/systemd/system/minecraft.service" "/etc/systemd/system/minecraft.service"

    if dry_run_enabled; then
        return 0
    fi

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

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Instalacao do Minecraft encerrada sem aplicar alteracoes."
        return 0
    fi

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
    # EULA acceptance validation: must run before anything else, even in DRY_RUN mode.
    # This is a policy gate, not a destructive action.
    if is_true "${NON_INTERACTIVE:-false}"; then
        if ! is_true "${ACCEPT_EULA:-false}"; then
            print_error "ACCEPT_EULA must be set to true in non-interactive mode to accept Mojang EULA. Aborting."
            exit 1
        fi
    else
        # In interactive mode, ask user to confirm EULA acceptance.
        if ! ask_confirm "Aceitar EULA da Mojang?" "N"; then
            print_error "EULA nao aceita. Instalacao abortada."
            exit 1
        fi
    fi

    run_minecraft_install
fi
