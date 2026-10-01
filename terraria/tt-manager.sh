#!/bin/bash
# terraria/tt-manager.sh
#
# Stack-specific overrides for Terraria. Shared boilerplate (resolve_self,
# cmd_start/stop/.../backup/monitor/hardware_report, show_help, dispatch) lives
# in shared/lib/manager-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -f "$DEFAULT_SERVER_DIR/config/serverconfig.txt" ] && [ -f "/opt/terraria-server/config/serverconfig.txt" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
SERVICE_NAME="terraria"
SERVER_USER="${SERVER_USER:-terraria}"

if [ -d "$SERVER_DIR" ]; then
    if ! id "$SERVER_USER" >/dev/null 2>&1; then
        detected_owner=$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || true) || detected_owner=""
        if [ -n "$detected_owner" ]; then
            SERVER_USER="$detected_owner"
        fi
        unset detected_owner
    fi
fi

BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
SETUP_CRON_SCRIPT="$SERVER_DIR/setup-cron.sh"
CONFIG_FILE="$SERVER_DIR/config/serverconfig.txt"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
TUNING_STATE="$SERVER_DIR/hardware-profile.env"
SHARED_DIR="$SERVER_DIR/.shared"
COMMON_LIB="$SHARED_DIR/common.sh"
HARDWARE_LIB="$SHARED_DIR/hardware-profile.sh"
TT_TUNING_LIB="$SHARED_DIR/terraria-tuning.sh"
MANAGER_COMMON_LIB="$SHARED_DIR/manager-common.sh"

if [ ! -f "$MANAGER_COMMON_LIB" ]; then
    MANAGER_COMMON_LIB="$SCRIPT_DIR/../shared/lib/manager-common.sh"
fi

if [ ! -f "$COMMON_LIB" ]; then
    COMMON_LIB="$SCRIPT_DIR/../shared/lib/common.sh"
fi

if [ ! -f "$HARDWARE_LIB" ]; then
    HARDWARE_LIB="$SCRIPT_DIR/../shared/lib/hardware-profile.sh"
fi

if [ ! -f "$TT_TUNING_LIB" ]; then
    TT_TUNING_LIB="$SCRIPT_DIR/../shared/lib/terraria-tuning.sh"
fi

if [ ! -f "$MANAGER_COMMON_LIB" ]; then
    echo "[ERRO] Biblioteca manager-common nao encontrada." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$MANAGER_COMMON_LIB"

# SELF precisa ser setado após source do manager-common (que define manager_resolve_self).
SELF="$(manager_resolve_self)"

if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
fi

# log()/warn()/err() centralized in common.sh.

get_cfg() {
    local key="$1"
    local default_value="$2"

    local value
    value="$(config_read_value "$CONFIG_FILE" "$key")"
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    echo "$default_value"
}

# Descrições específicas para o show_help compartilhado (console/health diferem
# entre Minecraft e Terraria).
MANAGER_DESC_CONSOLE="Logs em tempo real (console interativo nao suportado)"
MANAGER_DESC_HEALTH="Verifica se a porta do servidor esta em escuta"

cmd_console() {
    warn "Terraria nao possui console RCON nativo neste manager. Exibindo logs em tempo real."
    cmd_logs
}

cmd_setup_cron() {
    if [ ! -x "$SETUP_CRON_SCRIPT" ]; then
        err "Script de setup-cron nao encontrado: $SETUP_CRON_SCRIPT"
        return 1
    fi
    manager_need_root "$SELF" "setup-cron" "$@"
    SERVER_USER="$SERVER_USER" "$SETUP_CRON_SCRIPT"
}

cmd_reconfigure_hardware() {
    local forced_tier="${1:-}"
    local world_path
    local server_port
    local motd
    local world_name

    forced_tier="${forced_tier^^}"

    manager_need_root "$SELF" "reconfigure-hardware" "$forced_tier"

    if [ ! -f "$COMMON_LIB" ] || [ ! -f "$HARDWARE_LIB" ] || [ ! -f "$TT_TUNING_LIB" ]; then
        err "Bibliotecas de tuning nao encontradas em $SHARED_DIR"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$COMMON_LIB"
    # shellcheck source=/dev/null
    source "$HARDWARE_LIB"
    # shellcheck source=/dev/null
    source "$TT_TUNING_LIB"

    case "$forced_tier" in
        ""|LOW|MID|HIGH) ;;
        *)
            err "Tier invalido: $forced_tier (use LOW, MID ou HIGH)"
            return 1
            ;;
    esac

    detect_hardware_profile "$SERVER_DIR" "$forced_tier"
    compute_terraria_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_terraria_runtime_env "$RUNTIME_ENV"

    world_path="$(get_cfg "worldpath" "")"
    server_port="$(get_cfg "port" "")"
    motd="$(get_cfg "motd" "")"
    world_name="$(get_cfg "worldname" "")"
    world_path="${world_path:-$SERVER_DIR/worlds}"
    server_port="${server_port:-7777}"
    motd="${motd:-Servidor Terraria gerenciado por Crias-Server}"
    world_name="${world_name:-world}"

    write_terraria_server_config "$CONFIG_FILE" "$world_path" "$server_port" "$motd" "$world_name"
    write_terraria_tuning_state "$TUNING_STATE"

    echo "Tier detectado: $HW_DETECTED_TIER"
    echo "Tier aplicado: $HW_TIER"
    echo "Max players: $TT_MAX_PLAYERS"
    echo "NPC stream: $TT_NPC_STREAM"

    # Validate SERVER_DIR before chown -R (path traversal prevention).
    if declare -F validate_server_dir >/dev/null 2>&1; then
        if ! validate_server_dir "$SERVER_DIR"; then
            err "SERVER_DIR invalido, nao aplicando chown: $SERVER_DIR"
            return 1
        fi
    fi
    chown -R "${SERVER_USER}:${SERVER_USER}" "$SERVER_DIR"

    warn "Reconfiguracao aplicada em arquivos. Reinicie o servico para aplicar no runtime: sudo systemctl restart $SERVICE_NAME"
}

cmd_health() {
    local server_port

    server_port="$(config_read_value "$CONFIG_FILE" "port")"
    if ! [[ "$server_port" =~ ^[0-9]+$ ]]; then
        server_port=7777
    fi

    if ! port_is_listening "$server_port"; then
        err "Porta $server_port nao esta em escuta."
        return 1
    fi

    log "Health OK: porta $server_port em escuta."
}

manager_dispatch "$@"
