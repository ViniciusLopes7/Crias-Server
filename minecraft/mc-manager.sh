#!/bin/bash
# minecraft/mc-manager.sh
#
# CLI de gerenciamento do Minecraft. Centraliza log()/warn()/err() em
# shared/lib/common.sh (item 6.4 do plano) e gera show_help dinamicamente
# via declare -F.

set -euo pipefail

resolve_self() {
    local src="${BASH_SOURCE[0]}"
    local resolved=""
    if command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -f "$src" 2>/dev/null || true)"
    fi
    if [ -z "$resolved" ] && command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath "$src" 2>/dev/null || true)"
    fi
    if [ -n "$resolved" ]; then
        echo "$resolved"
    else
        echo "$src"
    fi
}

SELF="$(resolve_self)"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -f "$DEFAULT_SERVER_DIR/server.properties" ] && [ -f "/opt/minecraft-server/server.properties" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
SERVICE_NAME="minecraft"
SERVER_USER="${SERVER_USER:-minecraft}"

if [ -d "$SERVER_DIR" ]; then
    if ! id "$SERVER_USER" >/dev/null 2>&1; then
        # detected_owner é temporário; script é top-level (não há `local` em escopo global).
        detected_owner=$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || true) || detected_owner=""
        if [ -n "$detected_owner" ]; then
            SERVER_USER="$detected_owner"
        fi
        unset detected_owner
    fi
fi

BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
SETUP_CRON_SCRIPT="$SERVER_DIR/setup-cron.sh"
PROPS_FILE="$SERVER_DIR/server.properties"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
TUNING_STATE="$SERVER_DIR/hardware-profile.env"
SHARED_DIR="$SERVER_DIR/.shared"
COMMON_LIB="$SHARED_DIR/common.sh"
HARDWARE_LIB="$SHARED_DIR/hardware-profile.sh"
MC_TUNING_LIB="$SHARED_DIR/minecraft-tuning.sh"
MANAGER_COMMON_LIB="$SHARED_DIR/manager-common.sh"

if [ ! -f "$MANAGER_COMMON_LIB" ]; then
    MANAGER_COMMON_LIB="$SCRIPT_DIR/../shared/lib/manager-common.sh"
fi

if [ ! -f "$COMMON_LIB" ]; then
    COMMON_LIB="$SCRIPT_DIR/../shared/lib/common.sh"
fi

if [ ! -f "$MANAGER_COMMON_LIB" ]; then
    echo "[ERRO] Biblioteca manager-common nao encontrada." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$MANAGER_COMMON_LIB"

if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
fi

# log()/warn()/err() centralizados em common.sh (item 6.4 do plano).
# Não redefinimos localmente para evitar divergência de formato.

get_prop() {
    local key="$1"
    local default_value="$2"

    local value
    value="$(config_read_value "$PROPS_FILE" "$key")"
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    echo "$default_value"
}

cmd_start() { manager_cmd_start "$SERVICE_NAME"; }
cmd_stop() { manager_cmd_stop "$SERVICE_NAME"; }
cmd_restart() { manager_cmd_restart "$SERVICE_NAME"; }
cmd_status() { manager_cmd_status "$SERVICE_NAME"; }
cmd_logs() { manager_cmd_logs "$SERVICE_NAME"; }
cmd_console() {
    local rcon_pass
    local rcon_port

    if ! command -v mcrcon >/dev/null 2>&1; then
        warn "Console interativo requer mcrcon. Instale via AUR (ex: yay -S mcrcon) ou construa a partir do PKGBUILD do AUR."
        cmd_logs
        return 0
    fi

    rcon_pass="$(get_prop "rcon.password" "")"
    rcon_port="$(get_prop "rcon.port" "25575")"

    if [ -z "$rcon_pass" ]; then
        warn "RCON nao configurado em $PROPS_FILE (rcon.password)."
        cmd_logs
        return 0
    fi

    if ! [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        rcon_port=25575
    fi

    MCRCON_PASS="$rcon_pass" exec mcrcon -H localhost -P "$rcon_port"
}

cmd_backup() {
    if [ ! -x "$BACKUP_SCRIPT" ]; then
        err "Script de backup nao encontrado: $BACKUP_SCRIPT"
        return 1
    fi
    manager_run_as_server_user "$SERVER_USER" "$BACKUP_SCRIPT"
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
    local server_port online_mode motd
    forced_tier="${forced_tier^^}"

    manager_need_root "$SELF" "reconfigure-hardware" "$forced_tier"

    if [ ! -f "$HARDWARE_LIB" ] || [ ! -f "$MC_TUNING_LIB" ]; then
        err "Bibliotecas de tuning nao encontradas em $SHARED_DIR"
        return 1
    fi

    case "$forced_tier" in
        ""|LOW|MID|HIGH) ;;
        *)
            err "Tier invalido: $forced_tier (use LOW, MID ou HIGH)"
            return 1
            ;;
    esac

    # shellcheck source=/dev/null
    source "$HARDWARE_LIB"
    # shellcheck source=/dev/null
    source "$MC_TUNING_LIB"

    detect_hardware_profile "$SERVER_DIR" "$forced_tier"
    compute_minecraft_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_minecraft_runtime_env "$RUNTIME_ENV"

    server_port="$(config_read_value "$PROPS_FILE" "server-port")"
    online_mode="$(config_read_value "$PROPS_FILE" "online-mode")"
    motd="$(config_read_value "$PROPS_FILE" "motd")"
    server_port="${server_port:-25565}"
    online_mode="${online_mode:-false}"
    motd="${motd:-Servidor Minecraft}"

    write_minecraft_server_properties "$PROPS_FILE" "$server_port" "$online_mode" "$motd"
    write_minecraft_tuning_state "$TUNING_STATE"

    echo "Tier detectado: $HW_DETECTED_TIER"
    echo "Tier aplicado: $HW_TIER"
    echo "Heap aplicado: $MC_MIN_RAM -> $MC_MAX_RAM"
    echo "View/Simulation: $MC_VIEW_DISTANCE / $MC_SIMULATION_DISTANCE"
    echo "Max players: $MC_MAX_PLAYERS"

    chown -R "${SERVER_USER}:${SERVER_USER}" "$SERVER_DIR"

    warn "Reconfiguracao aplicada em arquivos. Reinicie o servico para aplicar no runtime: sudo systemctl restart $SERVICE_NAME"
}

cmd_hardware_report() {
    if [ -f "$TUNING_STATE" ]; then
        cat "$TUNING_STATE"
    else
        warn "Arquivo de estado nao encontrado: $TUNING_STATE"
    fi
}

cmd_health() {
    local server_port
    local rcon_pass
    local rcon_port

    server_port="$(get_prop "server-port" "25565")"
    if ! [[ "$server_port" =~ ^[0-9]+$ ]]; then
        server_port=25565
    fi

    if ! port_is_listening "$server_port"; then
        err "Porta $server_port nao esta em escuta."
        return 1
    fi

    rcon_pass="$(get_prop "rcon.password" "")"
    rcon_port="$(get_prop "rcon.port" "25575")"
    if ! [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        rcon_port=25575
    fi

    if [ -n "$rcon_pass" ] && command -v mcrcon >/dev/null 2>&1; then
        if MCRCON_PASS="$rcon_pass" timeout 10 mcrcon -H localhost -P "$rcon_port" "list" >/dev/null 2>&1; then
            log "Health OK: porta $server_port e RCON responderam."
            return 0
        fi

        err "Porta $server_port em escuta, mas RCON nao respondeu."
        return 1
    fi

    warn "Health limitado a porta em escuta; RCON indisponivel para verificacao."
    return 0
}

# ---------------------------------------------------------------------------
# show_help gerado dinamicamente via declare -F (item 6.4 do plano).
# ---------------------------------------------------------------------------
show_help() {
    cat << EOF
Uso: $0 <comando>

Comandos disponiveis:
EOF
    # Lista funções cmd_* dinamicamente e mapeia para descrição.
    local fn
    while IFS= read -r fn; do
        local cmd="${fn#cmd_}"
        local desc=""
        case "$cmd" in
            start)                      desc="Inicia o servico (systemd)" ;;
            stop)                       desc="Para o servico (systemd)" ;;
            restart)                    desc="Reinicia o servico (systemd)" ;;
            status)                     desc="Mostra status (systemd)" ;;
            logs)                       desc="Tail dos logs (journalctl)" ;;
            console)                    desc="Console interativo via RCON (fallback para logs)" ;;
            health)                     desc="Verifica porta e RCON do servidor" ;;
            backup)                     desc="Executa backup imediato" ;;
            setup-cron)                 desc="Configura timer systemd de backup" ;;
            reconfigure-hardware)       desc="Recalcula tuning (TIER: LOW|MID|HIGH ou vazio)" ;;
            hardware-report)            desc="Exibe perfil/tuning aplicado" ;;
        esac
        printf '  %-30s %s\n' "$cmd" "$desc"
    done < <(declare -F | awk '{print $3}' | grep -E '^cmd_' | sort)
}

case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    stop) shift; cmd_stop "$@" ;;
    restart) shift; cmd_restart "$@" ;;
    status) shift; cmd_status "$@" ;;
    logs) shift; cmd_logs "$@" ;;
    console) shift; cmd_console "$@" ;;
    health) shift; cmd_health "$@" ;;
    backup) shift; cmd_backup "$@" ;;
    setup-cron) shift; cmd_setup_cron "$@" ;;
    reconfigure-hardware) shift; cmd_reconfigure_hardware "${1:-}" ;;
    hardware-report) shift; cmd_hardware_report "$@" ;;
    *) show_help; exit 1 ;;
esac
