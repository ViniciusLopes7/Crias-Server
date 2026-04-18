#!/bin/bash

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared/lib/common.sh"

OVERRIDABLE_VARS=(
    SERVER_TYPE
    FORCE_HARDWARE_TIER
    INSTALL_TAILSCALE
    APPLY_SYSTEM_TUNING
    CLEANUP_OTHER_STACK
    DRY_RUN
    NON_INTERACTIVE
    MINECRAFT_USER
    MINECRAFT_SERVER_DIR
    MINECRAFT_PORT
    MINECRAFT_ONLINE_MODE
    MINECRAFT_VERSION
    MINECRAFT_LOADER
    MINECRAFT_INSTALL_MODPACK
    MINECRAFT_ADRENALINE_VERSION
    MINECRAFT_INSTALL_QOL_MODS
    TERRARIA_USER
    TERRARIA_SERVER_DIR
    TERRARIA_PORT
    TERRARIA_WORLD_NAME
    TERRARIA_MOTD
    TERRARIA_DOWNLOAD_URL
)

capture_env_overrides() {
    local var_name
    local has_name
    local value_name

    for var_name in "${OVERRIDABLE_VARS[@]}"; do
        has_name="ENV_HAS_${var_name}"
        value_name="ENV_VALUE_${var_name}"

        if [[ -v $var_name ]]; then
            printf -v "$has_name" '%s' "true"
            printf -v "$value_name" '%s' "${!var_name}"
        else
            printf -v "$has_name" '%s' "false"
        fi
    done
}

restore_env_overrides() {
    local var_name
    local has_name
    local value_name

    for var_name in "${OVERRIDABLE_VARS[@]}"; do
        has_name="ENV_HAS_${var_name}"
        value_name="ENV_VALUE_${var_name}"

        if [ "${!has_name}" = "true" ]; then
            printf -v "$var_name" '%s' "${!value_name}"
        fi
    done
}

capture_env_overrides

# Defaults (precedencia: defaults < config.env < variaveis de ambiente).
SERVER_TYPE="${SERVER_TYPE:-}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-true}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
CLEANUP_OTHER_STACK="${CLEANUP_OTHER_STACK:-true}"
DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_SERVER_DIR="${MINECRAFT_SERVER_DIR:-/opt/minecraft-server}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"
MINECRAFT_ONLINE_MODE="${MINECRAFT_ONLINE_MODE:-false}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
MINECRAFT_INSTALL_MODPACK="${MINECRAFT_INSTALL_MODPACK:-true}"
MINECRAFT_ADRENALINE_VERSION="${MINECRAFT_ADRENALINE_VERSION:-}"
MINECRAFT_INSTALL_QOL_MODS="${MINECRAFT_INSTALL_QOL_MODS:-true}"

TERRARIA_USER="${TERRARIA_USER:-terraria}"
TERRARIA_SERVER_DIR="${TERRARIA_SERVER_DIR:-/opt/terraria-server}"
TERRARIA_PORT="${TERRARIA_PORT:-7777}"
TERRARIA_WORLD_NAME="${TERRARIA_WORLD_NAME:-world}"
TERRARIA_MOTD="${TERRARIA_MOTD:-Servidor Terraria gerenciado por Crias-Server}"
TERRARIA_DOWNLOAD_URL="${TERRARIA_DOWNLOAD_URL:-https://terraria.org/api/download/pc-dedicated-server/terraria-server-1449.zip}"

load_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

select_server_type() {
    if [ "$SERVER_TYPE" = "minecraft" ] || [ "$SERVER_TYPE" = "terraria" ]; then
        return 0
    fi

    if is_true "$NON_INTERACTIVE"; then
        print_error "SERVER_TYPE precisa ser definido como minecraft ou terraria quando NON_INTERACTIVE=true."
        exit 1
    fi

    echo "Selecione qual servidor deseja instalar:"
    echo ""
    echo "1) Minecraft"
    echo "2) Terraria"
    echo ""

    while true; do
        read -r -p "Opcao (1-2): " selected
        case "$selected" in
            1)
                SERVER_TYPE="minecraft"
                return 0
                ;;
            2)
                SERVER_TYPE="terraria"
                return 0
                ;;
            *)
                print_warning "Opcao invalida. Escolha 1 ou 2."
                ;;
        esac
    done
}

prompt_global_options() {
    if is_true "$NON_INTERACTIVE"; then
        return 0
    fi

    echo ""
    if ask_confirm "Deseja revisar opcoes globais?" "N"; then
        ask_value "Forcar tier de hardware (LOW/MID/HIGH ou vazio para auto)" "$FORCE_HARDWARE_TIER" FORCE_HARDWARE_TIER

        if ask_confirm "Instalar/configurar Tailscale?" "Y"; then
            INSTALL_TAILSCALE="true"
        else
            INSTALL_TAILSCALE="false"
        fi

        if ask_confirm "Aplicar tuning de sistema (zram/scheduler/cpupower)?" "Y"; then
            APPLY_SYSTEM_TUNING="true"
        else
            APPLY_SYSTEM_TUNING="false"
        fi

        if ask_confirm "Limpar stack nao selecionado apos instalar?" "Y"; then
            CLEANUP_OTHER_STACK="true"
        else
            CLEANUP_OTHER_STACK="false"
        fi
    fi
}

prompt_minecraft_options() {
    if is_true "$NON_INTERACTIVE"; then
        return 0
    fi

    echo ""
    if ask_confirm "Deseja revisar configuracoes do Minecraft?" "Y"; then
        ask_value "Usuario do Minecraft" "$MINECRAFT_USER" MINECRAFT_USER
        ask_value "Diretorio do Minecraft" "$MINECRAFT_SERVER_DIR" MINECRAFT_SERVER_DIR
        ask_value "Porta do Minecraft" "$MINECRAFT_PORT" MINECRAFT_PORT
        ask_value "Versao do Minecraft" "$MINECRAFT_VERSION" MINECRAFT_VERSION
        ask_value "Loader (fabric/quilt/paper/vanilla/forge/neoforge)" "$MINECRAFT_LOADER" MINECRAFT_LOADER

        if ask_confirm "Ativar online-mode=true (premium)?" "N"; then
            MINECRAFT_ONLINE_MODE="true"
        else
            MINECRAFT_ONLINE_MODE="false"
        fi

        if ask_confirm "Instalar Modpack Adrenaline?" "Y"; then
            MINECRAFT_INSTALL_MODPACK="true"
        else
            MINECRAFT_INSTALL_MODPACK="false"
        fi

        if ask_confirm "Instalar mods QoL adicionais?" "Y"; then
            MINECRAFT_INSTALL_QOL_MODS="true"
        else
            MINECRAFT_INSTALL_QOL_MODS="false"
        fi
    fi
}

prompt_terraria_options() {
    if is_true "$NON_INTERACTIVE"; then
        return 0
    fi

    echo ""
    if ask_confirm "Deseja revisar configuracoes do Terraria?" "Y"; then
        ask_value "Usuario do Terraria" "$TERRARIA_USER" TERRARIA_USER
        ask_value "Diretorio do Terraria" "$TERRARIA_SERVER_DIR" TERRARIA_SERVER_DIR
        ask_value "Porta do Terraria" "$TERRARIA_PORT" TERRARIA_PORT
        ask_value "Nome do mundo" "$TERRARIA_WORLD_NAME" TERRARIA_WORLD_NAME
        ask_value "MOTD" "$TERRARIA_MOTD" TERRARIA_MOTD
        ask_value "URL de download do pacote Terraria" "$TERRARIA_DOWNLOAD_URL" TERRARIA_DOWNLOAD_URL
    fi
}

install_tailscale_if_enabled() {
    if ! is_true "$INSTALL_TAILSCALE"; then
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do Tailscale."
        return 0
    fi

    print_step "Instalando Tailscale..."
    if ! command_exists tailscale; then
        pacman -S --needed --noconfirm tailscale
    fi

    systemctl enable tailscaled >/dev/null 2>&1 || true
    systemctl start tailscaled >/dev/null 2>&1 || true
    print_success "Tailscale pronto. Execute 'sudo tailscale up' para autenticar."
}

resolve_operator_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
    else
        id -un
    fi
}

resolve_operator_home() {
    local user_name="$1"
    local home_dir

    home_dir=$(getent passwd "$user_name" | cut -d: -f6)

    if [ -n "$home_dir" ]; then
        echo "$home_dir"
    else
        echo "$HOME"
    fi
}

stack_alias_script() {
    local stack_type="$1"

    if [ "$stack_type" = "minecraft" ]; then
        echo "$MINECRAFT_SERVER_DIR/comandos.sh"
    else
        echo "$TERRARIA_SERVER_DIR/comandos.sh"
    fi
}

ensure_alias_autoload_entry() {
    local alias_script="$1"
    local operator_user
    local operator_home
    local bashrc_path
    local source_line

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao automatica de aliases no shell."
        return 0
    fi

    operator_user="$(resolve_operator_user)"
    operator_home="$(resolve_operator_home "$operator_user")"

    if [ -z "$operator_home" ] || [ ! -d "$operator_home" ]; then
        print_warning "Nao foi possivel localizar home de $operator_user para configurar aliases automaticamente."
        return 0
    fi

    bashrc_path="$operator_home/.bashrc"
    touch "$bashrc_path"
    chown "${operator_user}:${operator_user}" "$bashrc_path" >/dev/null 2>&1 || true

    if awk -v script="$alias_script" '
        $0 ~ /^[[:space:]]*#/ { next }
        index($0, script) && $0 ~ /(^|[[:space:]])(source|\.)[[:space:]]+/ { found=1 }
        END { exit found ? 0 : 1 }
    ' "$bashrc_path"; then
        print_step "Aliases ja configurados em $bashrc_path"
        return 0
    fi

    source_line="[ -f \"$alias_script\" ] && source \"$alias_script\""
    printf "\n%s\n" "$source_line" >> "$bashrc_path"
    chown "${operator_user}:${operator_user}" "$bashrc_path" >/dev/null 2>&1 || true

    print_success "Aliases configurados automaticamente em $bashrc_path"
    print_step "Abra um novo shell ou rode: source $bashrc_path"
}

remove_alias_autoload_entry() {
    local alias_script="$1"
    local operator_user
    local operator_home
    local bashrc_path
    local tmp_file

    if is_true "$DRY_RUN"; then
        return 0
    fi

    operator_user="$(resolve_operator_user)"
    operator_home="$(resolve_operator_home "$operator_user")"
    bashrc_path="$operator_home/.bashrc"

    if [ ! -f "$bashrc_path" ]; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk -v script="$alias_script" '
        {
            if ($0 !~ /^[[:space:]]*#/ && index($0, script) && $0 ~ /(^|[[:space:]])(source|\.)[[:space:]]+/) {
                next
            }
            print
        }
    ' "$bashrc_path" > "$tmp_file"

    mv "$tmp_file" "$bashrc_path"
    chown "${operator_user}:${operator_user}" "$bashrc_path" >/dev/null 2>&1 || true
}

configure_alias_autoload_for_selected_stack() {
    local alias_script

    alias_script="$(stack_alias_script "$SERVER_TYPE")"
    if [ ! -f "$alias_script" ]; then
        print_warning "Arquivo de aliases nao encontrado para autoload: $alias_script"
        return 0
    fi

    ensure_alias_autoload_entry "$alias_script"
}

run_selected_stack_installer() {
    if [ "$SERVER_TYPE" = "minecraft" ]; then
        export MINECRAFT_USER
        export MINECRAFT_SERVER_DIR
        export MINECRAFT_PORT
        export MINECRAFT_ONLINE_MODE
        export MINECRAFT_VERSION
        export MINECRAFT_LOADER
        export MINECRAFT_INSTALL_MODPACK
        export MINECRAFT_ADRENALINE_VERSION
        export MINECRAFT_INSTALL_QOL_MODS
        export FORCE_HARDWARE_TIER
        export APPLY_SYSTEM_TUNING
        export DRY_RUN
        export NON_INTERACTIVE

        bash "$SCRIPT_DIR/minecraft/install.sh"
        return 0
    fi

    export TERRARIA_USER
    export TERRARIA_SERVER_DIR
    export TERRARIA_PORT
    export TERRARIA_WORLD_NAME
    export TERRARIA_MOTD
    export TERRARIA_DOWNLOAD_URL
    export FORCE_HARDWARE_TIER
    export APPLY_SYSTEM_TUNING
    export DRY_RUN
    export NON_INTERACTIVE

    bash "$SCRIPT_DIR/terraria/install.sh"
}

cleanup_stack_by_type() {
    local stack_type="$1"
    local service_name
    local stack_user
    local stack_dir

    if [ "$stack_type" = "minecraft" ]; then
        service_name="minecraft"
        stack_user="$MINECRAFT_USER"
        stack_dir="$MINECRAFT_SERVER_DIR"
    else
        service_name="terraria"
        stack_user="$TERRARIA_USER"
        stack_dir="$TERRARIA_SERVER_DIR"
    fi

    print_step "Removendo stack $stack_type..."

    if is_true "$DRY_RUN"; then
        print_warning "[DRY_RUN] Cleanup real pulado para stack $stack_type."
        return 0
    fi

    if systemctl list-unit-files | grep -q "^${service_name}.service"; then
        systemctl stop "$service_name" >/dev/null 2>&1 || true
        systemctl disable "$service_name" >/dev/null 2>&1 || true
    fi

    rm -f "/etc/systemd/system/${service_name}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true

    if [ -d "$stack_dir" ]; then
        rm -rf "$stack_dir"
    fi

    if id "$stack_user" >/dev/null 2>&1; then
        userdel -r "$stack_user" >/dev/null 2>&1 || userdel "$stack_user" >/dev/null 2>&1 || true
    fi

    if crontab -l >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "$stack_dir/backup-cron.sh") | crontab - || true
    fi

    remove_alias_autoload_entry "$stack_dir/comandos.sh"

    print_success "Stack $stack_type removido."
}

cleanup_other_stack_if_needed() {
    local other_stack
    local other_user
    local other_dir
    local has_existing_data=false

    if ! is_true "$CLEANUP_OTHER_STACK"; then
        print_warning "Cleanup do stack oposto desativado."
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_warning "[DRY_RUN] Cleanup do stack oposto pulado."
        return 0
    fi

    if [ "$SERVER_TYPE" = "minecraft" ]; then
        other_stack="terraria"
        other_user="$TERRARIA_USER"
        other_dir="$TERRARIA_SERVER_DIR"
    else
        other_stack="minecraft"
        other_user="$MINECRAFT_USER"
        other_dir="$MINECRAFT_SERVER_DIR"
    fi

    if [ -d "$other_dir" ]; then
        has_existing_data=true
    fi

    if id "$other_user" >/dev/null 2>&1; then
        has_existing_data=true
    fi

    if systemctl list-unit-files | grep -q "^${other_stack}.service"; then
        has_existing_data=true
    fi

    if [ "$has_existing_data" = true ]; then
        print_warning "Foi detectado stack existente de $other_stack no host."
        print_warning "Essa limpeza remove servico, usuario e diretorio: $other_dir"

        if ! ask_confirm "CONFIRMAR REMOCAO COMPLETA DO STACK $other_stack?" "N"; then
            print_warning "Cleanup do stack oposto foi cancelado pelo usuario."
            return 0
        fi

        cleanup_stack_by_type "$other_stack"
    fi
}

main() {
    print_header
    check_root
    check_arch
    load_config_file
    restore_env_overrides

    if is_true "$DRY_RUN"; then
        print_warning "Modo DRY_RUN ativo: nenhuma alteracao destrutiva no host sera aplicada."
    fi

    select_server_type

    print_step "Stack selecionado: $SERVER_TYPE"

    prompt_global_options

    if [ "$SERVER_TYPE" = "minecraft" ]; then
        prompt_minecraft_options
    else
        prompt_terraria_options
    fi

    install_tailscale_if_enabled
    run_selected_stack_installer
    configure_alias_autoload_for_selected_stack
    cleanup_other_stack_if_needed

    print_success "Instalacao concluida para stack: $SERVER_TYPE"
}

main
