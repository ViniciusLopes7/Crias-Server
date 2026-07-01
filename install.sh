#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared/lib/common.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared/lib/config-parser.sh"

# Apply config with proper precedence: defaults < config.env < environment variables
apply_config_with_env_precedence "$CONFIG_FILE"

# Defaults (precedencia: defaults < config.env < variaveis de ambiente).
# Initialize only variables that are still undefined after config loading.
SERVER_TYPE="${SERVER_TYPE:-}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-true}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
SYSTEM_TUNING_SCOPE="${SYSTEM_TUNING_SCOPE:-host}"
CLEANUP_OTHER_STACK="${CLEANUP_OTHER_STACK:-true}"
DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# R1: thresholds de hardware com defaults sane.
HW_LOW_TIER_MAX_RAM_MB="${HW_LOW_TIER_MAX_RAM_MB:-3072}"
HW_LOW_TIER_MAX_CPU_CORES="${HW_LOW_TIER_MAX_CPU_CORES:-2}"
HW_MID_TIER_MAX_RAM_MB="${HW_MID_TIER_MAX_RAM_MB:-12288}"
HW_MID_TIER_MAX_CPU_CORES="${HW_MID_TIER_MAX_CPU_CORES:-6}"

# S8: detecção de virtualização (auto = skip em container/VPS, force = sempre aplica).
VIRT_TUNING_BEHAVIOR="${VIRT_TUNING_BEHAVIOR:-auto}"

MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_SERVER_DIR="${MINECRAFT_SERVER_DIR:-/opt/minecraft-server}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"
MINECRAFT_ONLINE_MODE="${MINECRAFT_ONLINE_MODE:-false}"
MINECRAFT_MOTD="${MINECRAFT_MOTD:-§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
MINECRAFT_INSTALL_MODPACK="${MINECRAFT_INSTALL_MODPACK:-true}"
MINECRAFT_ADRENALINE_VERSION="${MINECRAFT_ADRENALINE_VERSION:-}"
MINECRAFT_INSTALL_QOL_MODS="${MINECRAFT_INSTALL_QOL_MODS:-true}"
# R2: QoL mods via CSV.
MINECRAFT_QOL_MODS="${MINECRAFT_QOL_MODS:-chunky:chunky,essential-commands:essential-commands,universal-graves:universal-graves,tabtps:tabtps,styled-chat:styled-chat,polymer:polymer,placeholder-api:placeholder-api}"
# R3: modpack source.
MINECRAFT_MODPACK_SOURCE="${MINECRAFT_MODPACK_SOURCE:-adrenaline}"
MINECRAFT_MODPACK_SLUG="${MINECRAFT_MODPACK_SLUG:-adrenaline}"
# S3: versão pinada do mrpack-install.
MRPACK_INSTALL_VERSION="${MRPACK_INSTALL_VERSION:-v0.21.0-beta}"
MRPACK_INSTALL_SHA256="${MRPACK_INSTALL_SHA256:-}"
ACCEPT_EULA="${ACCEPT_EULA:-false}"

TERRARIA_USER="${TERRARIA_USER:-terraria}"
TERRARIA_SERVER_DIR="${TERRARIA_SERVER_DIR:-/opt/terraria-server}"
TERRARIA_PORT="${TERRARIA_PORT:-7777}"
TERRARIA_WORLD_NAME="${TERRARIA_WORLD_NAME:-world}"
TERRARIA_MOTD="${TERRARIA_MOTD:-Servidor Terraria gerenciado por Crias-Server}"
TERRARIA_DOWNLOAD_URL="${TERRARIA_DOWNLOAD_URL:-https://terraria.org/api/download/pc-dedicated-server/terraria-server-1456.zip}"

# Fase 1+: instalação opcional do agente de controle remoto (crias-agent).
INSTALL_AGENT="${INSTALL_AGENT:-}"

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
        ask_value "MOTD (Message of the Day)" "$MINECRAFT_MOTD" MINECRAFT_MOTD
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
    local outdated_packages

    if ! is_true "$INSTALL_TAILSCALE"; then
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do Tailscale."
        return 0
    fi

    print_step "Instalando Tailscale..."

    # Já está instalado? (comum em hosts que deram boot pela ISO Crias, onde
    # Tailscale já vem pré-instalado no airootfs via packages.x86_64).
    if command_exists tailscale; then
        print_step "Tailscale já está instalado — pulando download."
    else
        # Host sem ISO Crias (instalação direta em Arch limpo): baixa via pacman.
        outdated_packages="$(pacman -Qu 2>/dev/null || true)"
        if [ -n "$outdated_packages" ]; then
            print_warning "Foram detectados pacotes desatualizados no sistema."
            print_warning "Recomendado executar 'pacman -Syu' antes para evitar partial-upgrade."
            if ! is_true "$NON_INTERACTIVE"; then
                if ! ask_confirm "Continuar mesmo assim?" "N"; then
                    print_error "Instalacao do Tailscale cancelada pelo usuario."
                    return 1
                fi
            fi
        fi

        # Tentativa 1: pacman (repo Arch oficial).
        if ! pacman -S --needed --noconfirm tailscale; then
            print_warning "pacman -S tailscale falhou. Tentando via repo oficial Tailscale..."
            # Tentativa 2: script oficial (https://pkgs.tailscale.com/stable/#arch).
            # Adiciona repo [tailscale] ao pacman.conf e instala.
            local tmpdir
            tmpdir="$(mktemp -d)"
            if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 \
                    -o "$tmpdir/tailscale.repo" \
                    https://pkgs.tailscale.com/stable/arch/tailscale.repo 2>/dev/null; then
                # Adiciona repo [tailscale] ao pacman.conf temporariamente.
                if ! grep -q '^\[tailscale\]' /etc/pacman.conf 2>/dev/null; then
                    cat >> /etc/pacman.conf <<'EOF'

[tailscale]
Server = https://pkgs.tailscale.com/stable/arch/$arch
EOF
                fi
                # Popula key do repo Tailscale (justin@tailscale.com).
                pacman-key --recv-key 999EAC3D9BD5B7F7 || true
                pacman-key --lsign-key 999EAC3D9BD5B7F7 || true
                if ! pacman -Syy --noconfirm tailscale; then
                    print_error "Falha ao instalar Tailscale via repo oficial."
                    print_error "Instale manualmente depois: sudo pacman -S tailscale"
                    rm -rf "$tmpdir"
                    return 1
                fi
            else
                print_error "Não foi possível baixar repo Tailscale (sem internet?)."
                print_error "Instale manualmente depois: sudo pacman -S tailscale"
                rm -rf "$tmpdir"
                return 1
            fi
            rm -rf "$tmpdir"
        fi
    fi

    systemctl enable tailscaled >/dev/null 2>&1 || true
    systemctl start tailscaled >/dev/null 2>&1 || true
    print_success "Tailscale pronto. Execute 'sudo tailscale up' para autenticar."
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
    local profiled_path
    local source_line

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao automatica de aliases globais."
        return 0
    fi

    profiled_path="/etc/profile.d/crias-server.sh"
    source_line="[ -f \"$alias_script\" ] && . \"$alias_script\""

    if [ -f "$profiled_path" ]; then
        cleanup_stale_alias_autoload_entries "$profiled_path"

        if grep -Fqx "$source_line" "$profiled_path"; then
            print_step "Aliases globais ja configurados em $profiled_path"
            return 0
        fi

        # Append an idempotent source_line while preserving operator customizations.
        printf '# Generated by Crias-Server installer - do not edit manually\n' >> "$profiled_path"
        printf '%s\n' "$source_line" >> "$profiled_path"
    else
        # Create new file with header and source_line
        cat > "$profiled_path" << EOF
# Generated by Crias-Server installer - do not edit manually
$source_line
EOF
        chmod 0644 "$profiled_path"
    fi

    print_success "Aliases configurados automaticamente em $profiled_path"
    print_step "Abra um novo shell de login ou faca logout/login para carregar os atalhos."
    print_step "Opcional: carregue agora com: source $profiled_path"
}

cleanup_stale_alias_autoload_entries() {
    local profiled_path="$1"
    local tmp_file
    local line
    local alias_path

    if [ ! -f "$profiled_path" ]; then
        return 0
    fi

    tmp_file="$(mktemp)"

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^\[\ -f\ \"([^\"]+)\"\ \]\ \&\&\ \.\ \"([^\"]+)\"$ ]]; then
            alias_path="${BASH_REMATCH[1]}"
            if [ ! -f "$alias_path" ]; then
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp_file"
    done < "$profiled_path"

    mv "$tmp_file" "$profiled_path"
    chmod 0644 "$profiled_path"
}

remove_alias_autoload_entry() {
    local alias_script="$1"
    local profiled_path
    local tmp_file

    if is_true "$DRY_RUN"; then
        return 0
    fi

    profiled_path="/etc/profile.d/crias-server.sh"

    if [ ! -f "$profiled_path" ]; then
        return 0
    fi

    tmp_file="$(mktemp)"

    # Remove lines that exactly match the generated source line or the generated header comment.
    local source_line
    source_line="[ -f \"$alias_script\" ] && . \"$alias_script\""

    grep -Fv "$source_line" "$profiled_path" | grep -Fv '# Generated by Crias-Server installer - do not edit manually' > "$tmp_file" || true

    mv "$tmp_file" "$profiled_path"
    chmod 0644 "$profiled_path"
}

write_stack_env_file() {
    local env_file

    env_file="$(mktemp "${TMPDIR:-/tmp}/crias_stack_env.XXXXXX")"
    chmod 600 "$env_file"

    {
        printf 'FORCE_HARDWARE_TIER=%q\n' "$FORCE_HARDWARE_TIER"
        printf 'APPLY_SYSTEM_TUNING=%q\n' "$APPLY_SYSTEM_TUNING"
        printf 'SYSTEM_TUNING_SCOPE=%q\n' "$SYSTEM_TUNING_SCOPE"
        printf 'DRY_RUN=%q\n' "$DRY_RUN"
        printf 'NON_INTERACTIVE=%q\n' "$NON_INTERACTIVE"
        # R1: thresholds propagados para o stack installer.
        printf 'HW_LOW_TIER_MAX_RAM_MB=%q\n' "${HW_LOW_TIER_MAX_RAM_MB:-3072}"
        printf 'HW_LOW_TIER_MAX_CPU_CORES=%q\n' "${HW_LOW_TIER_MAX_CPU_CORES:-2}"
        printf 'HW_MID_TIER_MAX_RAM_MB=%q\n' "${HW_MID_TIER_MAX_RAM_MB:-12288}"
        printf 'HW_MID_TIER_MAX_CPU_CORES=%q\n' "${HW_MID_TIER_MAX_CPU_CORES:-6}"

        if [ "$SERVER_TYPE" = "minecraft" ]; then
            printf 'MINECRAFT_USER=%q\n' "$MINECRAFT_USER"
            printf 'MINECRAFT_SERVER_DIR=%q\n' "$MINECRAFT_SERVER_DIR"
            printf 'MINECRAFT_PORT=%q\n' "$MINECRAFT_PORT"
            printf 'MINECRAFT_ONLINE_MODE=%q\n' "$MINECRAFT_ONLINE_MODE"
            printf 'MINECRAFT_MOTD=%q\n' "$MINECRAFT_MOTD"
            printf 'MINECRAFT_VERSION=%q\n' "$MINECRAFT_VERSION"
            printf 'MINECRAFT_LOADER=%q\n' "$MINECRAFT_LOADER"
            printf 'MINECRAFT_INSTALL_MODPACK=%q\n' "$MINECRAFT_INSTALL_MODPACK"
            printf 'MINECRAFT_ADRENALINE_VERSION=%q\n' "$MINECRAFT_ADRENALINE_VERSION"
            printf 'MINECRAFT_INSTALL_QOL_MODS=%q\n' "$MINECRAFT_INSTALL_QOL_MODS"
            printf 'ACCEPT_EULA=%q\n' "${ACCEPT_EULA:-false}"
            printf 'MRPACK_SHA256=%q\n' "${MRPACK_SHA256:-}"
            # R2/R3: QoL mods e modpack source configuráveis via config.env.
            printf 'MINECRAFT_QOL_MODS=%q\n' "${MINECRAFT_QOL_MODS:-}"
            printf 'MINECRAFT_MODPACK_SOURCE=%q\n' "${MINECRAFT_MODPACK_SOURCE:-adrenaline}"
            printf 'MINECRAFT_MODPACK_SLUG=%q\n' "${MINECRAFT_MODPACK_SLUG:-adrenaline}"
            # S3: versão pinada do mrpack-install.
            printf 'MRPACK_INSTALL_VERSION=%q\n' "${MRPACK_INSTALL_VERSION:-v0.21.0-beta}"
            printf 'MRPACK_INSTALL_SHA256=%q\n' "${MRPACK_INSTALL_SHA256:-}"
        else
            printf 'TERRARIA_USER=%q\n' "$TERRARIA_USER"
            printf 'TERRARIA_SERVER_DIR=%q\n' "$TERRARIA_SERVER_DIR"
            printf 'TERRARIA_PORT=%q\n' "$TERRARIA_PORT"
            printf 'TERRARIA_WORLD_NAME=%q\n' "$TERRARIA_WORLD_NAME"
            printf 'TERRARIA_MOTD=%q\n' "$TERRARIA_MOTD"
            printf 'TERRARIA_DOWNLOAD_URL=%q\n' "$TERRARIA_DOWNLOAD_URL"
            printf 'TERRARIA_SHA256=%q\n' "${TERRARIA_SHA256:-}"
        fi
    } > "$env_file"

    printf '%s\n' "$env_file"
}

configure_alias_autoload_for_selected_stack() {
    local alias_script

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao automatica de aliases globais."
        return 0
    fi

    alias_script="$(stack_alias_script "$SERVER_TYPE")"
    if [ ! -f "$alias_script" ]; then
        print_warning "Arquivo de aliases nao encontrado para autoload: $alias_script"
        return 0
    fi

    ensure_alias_autoload_entry "$alias_script"
}

run_selected_stack_installer() {
    local env_file
    local target_script
    local entry_function
    local exit_code

    env_file="$(write_stack_env_file)"

    if [ "$SERVER_TYPE" = "minecraft" ]; then
        target_script="$SCRIPT_DIR/minecraft/install.sh"
        entry_function="run_minecraft_install"
    else
        target_script="$SCRIPT_DIR/terraria/install.sh"
        entry_function="run_terraria_install"
    fi

    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$env_file"
        rm -f "$env_file"
        # shellcheck disable=SC1090
        source "$target_script"
        "$entry_function"
    )

    exit_code=$?
    rm -f "$env_file"
    return "$exit_code"
}

cleanup_stack_by_type() {
    local stack_type="$1"
    local service_name
    local stack_dir

    if [ "$stack_type" = "minecraft" ]; then
        service_name="minecraft"
        stack_dir="$MINECRAFT_SERVER_DIR"
    else
        service_name="terraria"
        stack_dir="$TERRARIA_SERVER_DIR"
    fi

    print_step "Desativando stack $stack_type..."

    if is_true "$DRY_RUN"; then
        print_warning "[DRY_RUN] Desativacao real pulada para stack $stack_type."
        return 0
    fi

    if systemctl list-unit-files | grep -q "^${service_name}.service"; then
        systemctl stop "$service_name" >/dev/null 2>&1 || true
        systemctl disable "$service_name" >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    # Remove backup-cron entries from the service user crontab (if present)
    local server_user_var
    if [ "$stack_type" = "minecraft" ]; then
        server_user_var="$MINECRAFT_USER"
    else
        server_user_var="$TERRARIA_USER"
    fi

    # If user-specific crontab exists and contains the backup script, remove it.
    if command -v crontab >/dev/null 2>&1; then
        if crontab -u "$server_user_var" -l 2>/dev/null | grep -Fq "$stack_dir/backup-cron.sh"; then
            local tmp_cron_file
            tmp_cron_file="$(mktemp "${TMPDIR:-/tmp}/crias_cron.XXXXXX")"
            crontab -u "$server_user_var" -l 2>/dev/null | grep -Fv "$stack_dir/backup-cron.sh" > "$tmp_cron_file" || true
            if [ -s "$tmp_cron_file" ]; then
                crontab -u "$server_user_var" "$tmp_cron_file" >/dev/null 2>&1 || true
            else
                crontab -u "$server_user_var" -r >/dev/null 2>&1 || true
            fi
            rm -f "$tmp_cron_file"
        fi

        # Also attempt to remove from root crontab if present
        if crontab -l 2>/dev/null | grep -Fq "$stack_dir/backup-cron.sh"; then
            local tmp_cron_root_file
            tmp_cron_root_file="$(mktemp "${TMPDIR:-/tmp}/crias_cron_root.XXXXXX")"
            crontab -l 2>/dev/null | grep -Fv "$stack_dir/backup-cron.sh" > "$tmp_cron_root_file" || true
            if [ -s "$tmp_cron_root_file" ]; then
                crontab "$tmp_cron_root_file" >/dev/null 2>&1 || true
            else
                crontab -r >/dev/null 2>&1 || true
            fi
            rm -f "$tmp_cron_root_file"
        fi
    fi

    remove_alias_autoload_entry "$stack_dir/comandos.sh"

    print_success "Stack $stack_type desativado sem remover dados."
}

cleanup_other_stack_if_needed() {
    local other_stack
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
        other_dir="$TERRARIA_SERVER_DIR"
    else
        other_stack="minecraft"
        other_dir="$MINECRAFT_SERVER_DIR"
    fi

    if [ -d "$other_dir" ]; then
        has_existing_data=true
    fi

    if systemctl list-unit-files | grep -q "^${other_stack}.service"; then
        has_existing_data=true
    fi

    if [ "$has_existing_data" = true ]; then
        print_warning "Foi detectado stack existente de $other_stack no host."
        print_warning "Essa limpeza preserva dados e apenas desativa o servico do stack oposto: $other_dir"

        if ! ask_confirm "CONFIRMAR DESATIVACAO DO STACK $other_stack?" "N"; then
            print_warning "Desativacao do stack oposto foi cancelada pelo usuario."
            return 0
        fi

        cleanup_stack_by_type "$other_stack"
    fi
}

# ---------------------------------------------------------------------------
# Fase 1+ do plano: instalação opcional do agente de controle remoto (crias-agent).
#
# O agente é um binário Go que escuta em localhost:8473 e é exposto via
# Tailscale Funnel. Permite controle remoto do servidor via gRPC + bot Discord.
#
# Esta função é chamada APÓS o stack principal ser instalado, pois precisa
# de server.properties (Minecraft) ou serverconfig.txt (Terraria) para
# configurar RCON no agent.yaml.
# ---------------------------------------------------------------------------
install_crias_agent_if_enabled() {
    local stack_dir
    local stack_user
    local service_name
    local stack_type_for_agent

    # Resolve config interativa se INSTALL_AGENT estiver vazio.
    if [ -z "$INSTALL_AGENT" ]; then
        if is_true "$NON_INTERACTIVE"; then
            INSTALL_AGENT="false"
        else
            if ask_confirm "Instalar agente de controle remoto (crias-agent)?" "N"; then
                INSTALL_AGENT="true"
            else
                INSTALL_AGENT="false"
            fi
        fi
    fi

    if ! is_true "$INSTALL_AGENT"; then
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do crias-agent."
        return 0
    fi

    print_step "Instalando agente de controle remoto (crias-agent)..."

    # Determina stack alvo.
    if [ "$SERVER_TYPE" = "minecraft" ]; then
        stack_dir="$MINECRAFT_SERVER_DIR"
        stack_user="$MINECRAFT_USER"
        service_name="minecraft"
        stack_type_for_agent="minecraft"
        stack_port="$MINECRAFT_PORT"
    else
        stack_dir="$TERRARIA_SERVER_DIR"
        stack_user="$TERRARIA_USER"
        service_name="terraria"
        stack_type_for_agent="terraria"
        stack_port="$TERRARIA_PORT"
    fi

    # Tier de hardware efetivo (vindo do stack installer ou FORCE_HARDWARE_TIER).
    # Usado para popular agent.yaml → server.hardware_tier, que o bot Discord
    # mostra no /mc status (item v1.1.0).
    local agent_hardware_tier="${FORCE_HARDWARE_TIER:-}"
    if [ -z "$agent_hardware_tier" ] && [ -f "$stack_dir/.hardware-tier" ]; then
        agent_hardware_tier="$(cat "$stack_dir/.hardware-tier" 2>/dev/null || true)"
    fi
    if [ -z "$agent_hardware_tier" ]; then
        agent_hardware_tier="unknown"
    fi

    # 1. Cria usuário crias-agent.
    if ! id "crias-agent" >/dev/null 2>&1; then
        useradd -r -M -s /usr/bin/nologin -d /opt/crias-agent "crias-agent"
    fi

    # 2. Cria diretório de instalação.
    mkdir -p /opt/crias-agent /etc/crias /var/log/crias-agent
    chown -R crias-agent:crias-agent /opt/crias-agent /var/log/crias-agent

    # Validação de inputs antes de gerar config/sudoers (item 7.4 do plano).
    # Prevenir YAML/sudoers malformado por caracteres especiais em paths/user.
    if ! [[ "$stack_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "stack_user inválido para sudoers: $stack_user (use apenas [a-z0-9_-])"
        return 1
    fi
    if ! [[ "$service_name" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "service_name inválido para sudoers: $service_name"
        return 1
    fi
    if ! [[ "$stack_dir" =~ ^/[a-zA-Z0-9/_.-]+$ ]]; then
        print_error "stack_dir inválido para sudoers (caracteres não permitidos): $stack_dir"
        return 1
    fi

    # 3. Baixa binário do último release da branch discord (GitHub API).
    local agent_url
    local api_url="https://api.github.com/repos/ViniciusLopes7/Crias-Server/releases"
    # Tenta tag específica primeiro; fallback para latest.
    agent_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 60 \
        "$api_url" 2>/dev/null \
        | jq -r '[.[] | select(.tag_name | startswith("agent-"))] | .[0].assets[] | select(.name=="crias-agent-linux-amd64") | .browser_download_url // empty' 2>/dev/null || true)

    if [ -z "$agent_url" ]; then
        # Fallback direto para o asset da tag agent-latest.
        agent_url="https://github.com/ViniciusLopes7/Crias-Server/releases/download/agent-latest/crias-agent-linux-amd64"
    fi

    local agent_sha_var="CRIAS_AGENT_SHA256"
    if ! download_and_verify "$agent_url" /tmp/crias-agent "$agent_sha_var" "false"; then
        print_error "Falha ao baixar crias-agent. Instalacao do agente pulada."
        print_warning "Voce pode instalar manualmente depois: ver discord-agent/README.md"
        return 1
    fi

    install -m 755 -o crias-agent -g crias-agent /tmp/crias-agent /opt/crias-agent/crias-agent
    rm -f /tmp/crias-agent

    # 4. Gera token aleatório (32 bytes hex = 64 chars).
    local agent_token
    agent_token="$(generate_token 32)"
    if [ -z "$agent_token" ] || [ "${#agent_token}" -ne 64 ]; then
        print_error "Falha ao gerar token aleatorio para o agente."
        return 1
    fi

    # 5. Lê RCON config (apenas Minecraft tem server.properties).
    local rcon_enabled="false"
    local rcon_host="127.0.0.1"
    local rcon_port="25575"
    local rcon_password=""

    if [ "$stack_type_for_agent" = "minecraft" ]; then
        local props_file="$stack_dir/server.properties"
        if [ -f "$props_file" ]; then
            local rcon_enabled_raw
            rcon_enabled_raw="$(config_read_value "$props_file" "enable-rcon")"
            if [ "$rcon_enabled_raw" = "true" ]; then
                rcon_enabled="true"
            fi
            rcon_port="$(config_read_value "$props_file" "rcon.port")"
            rcon_port="${rcon_port:-25575}"
            rcon_password="$(config_read_value "$props_file" "rcon.password")"
        fi
    fi

    # Validar rcon_password para YAML: não pode conter " ou \n (quebra YAML).
    if [ -n "$rcon_password" ]; then
        if [[ "$rcon_password" == *'"'* ]] || [[ "$rcon_password" == *$'\n'* ]]; then
            print_error "rcon.password em server.properties contém caracteres invalidos (aspas duplas ou newline)."
            print_error "Altere a senha do RCON no servidor antes de instalar o agente."
            return 1
        fi
    fi

    # 6. Gera /etc/crias/agent.yaml.
    cat > /etc/crias/agent.yaml << EOF
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "$agent_token"

server:
  stack: "$stack_type_for_agent"
  service_name: "$service_name"
  manager_script: "$stack_dir/mc-manager.sh"
  server_dir: "$stack_dir"
  server_port: $stack_port
  hardware_tier: "$agent_hardware_tier"
  rcon:
    enabled: $rcon_enabled
    host: "$rcon_host"
    port: $rcon_port
    password: "$rcon_password"

features:
  auto_shutdown:
    enabled: false
    empty_minutes: 30
  health_check:
    interval_seconds: 300
    passive: true
EOF
    chmod 0640 /etc/crias/agent.yaml
    chown root:crias-agent /etc/crias/agent.yaml

    # 7. Configura sudoers (item 7.4 do plano).
    cat > /etc/sudoers.d/crias-agent << EOF
# /etc/sudoers.d/crias-agent
# Generated by Crias-Server installer - do not edit manually
crias-agent ALL=(root) NOPASSWD: /usr/bin/systemctl start $service_name, /usr/bin/systemctl stop $service_name, /usr/bin/systemctl restart $service_name, /usr/bin/systemctl status $service_name, /usr/bin/systemctl is-active $service_name
crias-agent ALL=($stack_user) NOPASSWD: $stack_dir/backup-cron.sh, $stack_dir/mc-manager.sh *
EOF
    chmod 0440 /etc/sudoers.d/crias-agent

    # Valida sintaxe sudoers (item 7.4 do plano — não trustar input cegamente).
    if command -v visudo >/dev/null 2>&1; then
        if ! visudo -cf /etc/sudoers.d/crias-agent >/dev/null 2>&1; then
            print_error "Sintaxe sudoers inválida em /etc/sudoers.d/crias-agent; removendo."
            rm -f /etc/sudoers.d/crias-agent
            return 1
        fi
    else
        print_warning "visudo não disponível; sudoers não validado. Verifique manualmente: cat /etc/sudoers.d/crias-agent"
    fi

    # 8. Instala systemd unit.
    cat > /etc/systemd/system/crias-agent.service << 'EOF'
[Unit]
Description=Crias Agent - Remote control bridge
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
User=crias-agent
Group=crias-agent
WorkingDirectory=/opt/crias-agent
ExecStart=/opt/crias-agent/crias-agent
Restart=on-failure
RestartSec=5

MemoryMax=32M
CPUQuota=10%
TasksMax=10
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/crias-agent /var/log/crias-agent
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
RemoveIPC=yes
LockPersonality=yes
# Go binário é AOT-compiled: pode aplicar MemoryDenyWriteExecute com segurança.
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallArchitectures=native
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/crias-agent.service

    systemctl daemon-reload
    systemctl enable crias-agent >/dev/null 2>&1 || true
    systemctl restart crias-agent >/dev/null 2>&1 || print_warning "crias-agent nao iniciou imediatamente; verifique /var/log/crias-agent/"

    # 9. Instruções finais (token NÃO é impresso em stdout por segurança).
    print_success "crias-agent instalado em /opt/crias-agent/crias-agent"
    print_success "Token de autenticacao gerado em /etc/crias/agent.yaml (chmod 0640)"
    print_step "Para visualizar o token (protected file):"
    print_step "  sudo grep auth_token /etc/crias/agent.yaml"
    print_step "Configure no Railway (bot Discord):"
    print_step "  CRIAS_AGENT_HOST=https://<seu-tailnet>.ts.net"
    print_step "  CRIAS_AGENT_TOKEN=<copie do agent.yaml>"
    print_step "Ative o Tailscale Funnel apos 'sudo tailscale up':"
    print_step "  sudo tailscale funnel 8473"
    print_warning "NAO commitar /etc/crias/agent.yaml nem exportar o token em logs de CI."
}

main() {
    print_header
    apply_config_with_env_precedence "$CONFIG_FILE"

    if is_true "$DRY_RUN"; then
        print_warning "Modo DRY_RUN ativo: nenhuma alteracao destrutiva no host sera aplicada."
        # Keep fail-fast enabled even in DRY_RUN to catch logic errors without exposing secrets.
        trap 'echo "[install.sh] erro em DRY_RUN (exit=$?)" >&2; echo "Funcao: ${FUNCNAME[1]:-unknown}, Linha: ${BASH_LINENO[0]}" >&2; echo "Arquivo: ${BASH_SOURCE[1]:-unknown}" >&2' ERR
    else
        check_root
        check_arch
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
    # Policy gate: ensure EULA acceptance for non-interactive Minecraft installs
    if [ "$SERVER_TYPE" = "minecraft" ] && is_true "${NON_INTERACTIVE:-false}"; then
        if ! is_true "${ACCEPT_EULA:-false}"; then
            print_error "ACCEPT_EULA must be set to true in non-interactive mode to accept Mojang EULA. Aborting."
            exit 1
        fi
    fi

    if ! run_selected_stack_installer; then
        exit 1
    fi
    configure_alias_autoload_for_selected_stack
    cleanup_other_stack_if_needed

    # Fase 1+: instala agente de controle remoto (opcional, pergunta interativo).
    install_crias_agent_if_enabled

    print_success "Instalacao concluida para stack: $SERVER_TYPE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
