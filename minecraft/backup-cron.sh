#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/world" ] && [ -d "/opt/minecraft-server/world" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_DIR="$SERVER_DIR/backups"
WORLD_DIRS=("world" "world_nether" "world_the_end")
SCREEN_NAME="minecraft"
RUNTIME_ENV="$SERVER_DIR/runtime.env"

RETENTION_DAYS=7
ZSTD_LEVEL="-3"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="minecraft-backup-$DATE.tar.zst"

if [ -f "$RUNTIME_ENV" ]; then
    # shellcheck source=/dev/null
    source "$RUNTIME_ENV"
fi

if ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    BACKUP_RETENTION_DAYS="$RETENTION_DAYS"
fi

if ! [[ "$BACKUP_ZSTD_LEVEL" =~ ^-?[0-9]+$ ]]; then
    BACKUP_ZSTD_LEVEL="$ZSTD_LEVEL"
fi

if [ -n "$BACKUP_RETENTION_DAYS" ]; then
    RETENTION_DAYS="$BACKUP_RETENTION_DAYS"
fi

if [ -n "$BACKUP_ZSTD_LEVEL" ]; then
    ZSTD_LEVEL="$BACKUP_ZSTD_LEVEL"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_server_running() {
    screen -S "${SCREEN_NAME}" -Q select . >/dev/null 2>&1
}

escape_screen_message() {
    printf '%s' "$1" | sed 's/[\\]/\\\\/g; s/"/\\"/g'
}

notify_players() {
    local message="$1"
    if check_server_running; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "say $(escape_screen_message "$message")\n" >/dev/null 2>&1 || true
    fi
}

pause_saves() {
    if ! check_server_running; then
        return 0
    fi

    screen -S "$SCREEN_NAME" -p 0 -X stuff "save-all\n" >/dev/null 2>&1 || true
    sleep 3
    screen -S "$SCREEN_NAME" -p 0 -X stuff "save-off\n" >/dev/null 2>&1 || true
    sleep 2
}

resume_saves() {
    if check_server_running; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "save-on\n" >/dev/null 2>&1 || true
    fi
}

create_backup() {
    local backup_dirs=()

    mkdir -p "$BACKUP_DIR"
    cd "$SERVER_DIR" || return 1

    for dir in "${WORLD_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            backup_dirs+=("$dir")
        fi
    done

    if [ ${#backup_dirs[@]} -eq 0 ]; then
        log "ERRO: Nenhum diretorio de mundo encontrado."
        return 1
    fi

    if ionice -c3 tar -I "zstd ${ZSTD_LEVEL}" -cf "$BACKUP_DIR/$BACKUP_NAME" "${backup_dirs[@]}"; then
        log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        return 0
    fi

    log "ERRO: Falha ao criar backup."
    return 1
}

cleanup_old_backups() {
    find "$BACKUP_DIR" -name "minecraft-backup-*.tar.zst" -type f -mtime +"$RETENTION_DAYS" -delete
}

main() {
    local was_running=false

    if [ ! -d "$SERVER_DIR" ]; then
        log "ERRO: Diretorio do servidor nao encontrado: $SERVER_DIR"
        exit 1
    fi

    if check_server_running; then
        was_running=true
        notify_players "[Backup] Iniciando backup automatico..."
        pause_saves
    fi

    if create_backup; then
        cleanup_old_backups
        [ "$was_running" = true ] && notify_players "[Backup] Backup concluido com sucesso."
        log "Backup concluido com sucesso."
    else
        [ "$was_running" = true ] && notify_players "[Backup] Falha no backup."
        [ "$was_running" = true ] && resume_saves
        exit 1
    fi

    [ "$was_running" = true ] && resume_saves
}

main
