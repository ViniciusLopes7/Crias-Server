#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -f "$DEFAULT_SERVER_DIR/config/serverconfig.txt" ] && [ -f "/opt/terraria-server/config/serverconfig.txt" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
SERVER_USER="${SERVER_USER:-terraria}"
SCREEN_NAME="terraria"
START_SCRIPT="$SERVER_DIR/start-terraria.sh"
BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
CONFIG_FILE="$SERVER_DIR/config/serverconfig.txt"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
TUNING_STATE="$SERVER_DIR/hardware-profile.env"
SHARED_DIR="$SERVER_DIR/.shared"

HARDWARE_LIB="$SHARED_DIR/hardware-profile.sh"
TT_TUNING_LIB="$SHARED_DIR/terraria-tuning.sh"

if [ "$(id -nu)" != "$SERVER_USER" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        exec sudo -u "$SERVER_USER" "$0" "$@"
    else
        echo "[ERRO] Execute com sudo: sudo $0 $*"
        exit 1
    fi
fi

if [ -f "$HARDWARE_LIB" ]; then
    # shellcheck source=/dev/null
    source "$HARDWARE_LIB"
fi
if [ -f "$TT_TUNING_LIB" ]; then
    # shellcheck source=/dev/null
    source "$TT_TUNING_LIB"
fi

log() {
    echo "[INFO] $1"
}

warn() {
    echo "[AVISO] $1"
}

err() {
    echo "[ERRO] $1" >&2
}

check_server_running() {
    screen -list | grep -q "$SCREEN_NAME"
}

get_cfg() {
    local key="$1"
    local default_value="$2"

    if [ -f "$CONFIG_FILE" ]; then
        local value
        value=$(grep -E "^${key}=" "$CONFIG_FILE" | tail -n 1 | cut -d'=' -f2-)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$default_value"
}

start_server() {
    if check_server_running; then
        warn "Servidor ja esta rodando."
        return 1
    fi

    if [ ! -x "$START_SCRIPT" ]; then
        err "Script de inicio nao encontrado: $START_SCRIPT"
        return 1
    fi

    mkdir -p "$SERVER_DIR/.screen"
    screen -dmS "$SCREEN_NAME" "$START_SCRIPT"
    sleep 2

    if check_server_running; then
        log "Servidor iniciado."
        return 0
    fi

    err "Falha ao iniciar servidor."
    return 1
}

stop_server() {
    if ! check_server_running; then
        warn "Servidor nao esta rodando."
        return 1
    fi

    screen -S "$SCREEN_NAME" -p 0 -X stuff "say [Server] Reiniciando em 5 segundos...\n"
    sleep 5
    screen -S "$SCREEN_NAME" -p 0 -X stuff "save\n"
    sleep 2
    screen -S "$SCREEN_NAME" -p 0 -X stuff "exit\n"

    for _ in $(seq 1 60); do
        if ! check_server_running; then
            log "Servidor parado com sucesso."
            return 0
        fi
        sleep 1
    done

    warn "Timeout na parada graciosa, forçando encerramento."
    screen -S "$SCREEN_NAME" -X quit
}

restart_server() {
    stop_server || true
    sleep 2
    start_server
}

status_server() {
    if check_server_running; then
        echo "Status: RODANDO"
        local pid
        pid=$(pgrep -f "TerrariaServer.bin.x86_64" | head -n 1)
        if [ -n "$pid" ]; then
            echo "PID: $pid"
            echo "CPU: $(ps -p "$pid" -o %cpu= | xargs)%"
            echo "RAM: $(ps -p "$pid" -o rss= | awk '{printf \"%.1f MB\", $1/1024}')"
            echo "Uptime: $(ps -p "$pid" -o etime= | xargs)"
        fi
    else
        echo "Status: PARADO"
    fi
}

console_server() {
    if ! check_server_running; then
        err "Servidor nao esta rodando."
        return 1
    fi

    echo "Saida do console: Ctrl+A, depois D"
    screen -r "$SCREEN_NAME"
}

send_command() {
    shift
    local command="$*"

    if [ -z "$command" ]; then
        err "Uso: $0 cmd <comando>"
        return 1
    fi

    if ! check_server_running; then
        err "Servidor nao esta rodando."
        return 1
    fi

    screen -S "$SCREEN_NAME" -p 0 -X stuff "$command\n"
    log "Comando enviado: $command"
}

run_backup() {
    if [ ! -x "$BACKUP_SCRIPT" ]; then
        err "Script de backup nao encontrado: $BACKUP_SCRIPT"
        return 1
    fi

    "$BACKUP_SCRIPT"
}

reconfigure_hardware() {
    local forced_tier="${1^^}"
    local world_path
    local server_port
    local motd
    local world_name

    if [ ! -f "$HARDWARE_LIB" ] || [ ! -f "$TT_TUNING_LIB" ]; then
        err "Bibliotecas de tuning nao encontradas em $SHARED_DIR"
        return 1
    fi

    case "$forced_tier" in
        ""|LOW|MID|HIGH)
            ;;
        *)
            err "Tier invalido: $forced_tier (use LOW, MID ou HIGH)"
            return 1
            ;;
    esac

    detect_hardware_profile "$SERVER_DIR" "$forced_tier"
    compute_terraria_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_terraria_runtime_env "$RUNTIME_ENV"

    world_path=$(get_cfg "worldpath" "$SERVER_DIR/worlds")
    server_port=$(get_cfg "port" "7777")
    motd=$(get_cfg "motd" "Servidor Terraria gerenciado por Crias-Server")
    world_name=$(get_cfg "worldname" "world")

    write_terraria_server_config "$CONFIG_FILE" "$world_path" "$server_port" "$motd" "$world_name"
    write_terraria_tuning_state "$TUNING_STATE"

    log "Reconfiguracao concluida."
    echo "Tier detectado: $HW_DETECTED_TIER"
    echo "Tier aplicado: $HW_TIER"
    echo "Max players: $TT_MAX_PLAYERS"
    echo "NPC stream: $TT_NPC_STREAM"

    if check_server_running; then
        warn "Servidor esta rodando. Execute: $0 restart para aplicar as novas configuracoes."
    fi
}

hardware_report() {
    if [ -f "$TUNING_STATE" ]; then
        cat "$TUNING_STATE"
    else
        warn "Arquivo de estado nao encontrado: $TUNING_STATE"
    fi
}

show_help() {
    cat << EOF
Uso: $0 <comando>

Comandos:
  start                   Inicia o servidor
  stop                    Para o servidor
  restart                 Reinicia o servidor
  status                  Mostra status
  console                 Conecta no console (screen)
  cmd <texto>             Envia comando para o servidor
  backup                  Executa backup imediato
  reconfigure-hardware    Recalcula tuning automaticamente
  reconfigure-hardware LOW|MID|HIGH  Forca tier especifico
  hardware-report         Exibe perfil/tuning aplicado
EOF
}

case "$1" in
    start) start_server ;;
    stop) stop_server ;;
    restart) restart_server ;;
    status) status_server ;;
    console) console_server ;;
    cmd) send_command "$@" ;;
    backup) run_backup ;;
    reconfigure-hardware)
        reconfigure_hardware "$2"
        ;;
    hardware-report)
        hardware_report
        ;;
    *)
        show_help
        exit 1
        ;;
esac
