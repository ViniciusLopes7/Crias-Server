#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/worlds" ] && [ -d "/opt/terraria-server/worlds" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_DIR="$SERVER_DIR/backups"
WORLDS_DIR="$SERVER_DIR/worlds"
CONFIG_DIR="$SERVER_DIR/config"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
SCREEN_NAME="terraria"

RETENTION_DAYS=7
ZSTD_LEVEL="-3"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="terraria-backup-$DATE.tar.zst"

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
    screen -S "$SCREEN_NAME" -Q select . >/dev/null 2>&1
}

escape_screen_message() {
    printf '%s' "$1" | sed 's/[\\]/\\\\/g; s/"/\\"/g'
}

notify_server() {
    local message="$1"
    if check_server_running; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "say $(escape_screen_message "$message")\n" >/dev/null 2>&1 || true
    fi
}

trigger_save() {
    if check_server_running; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "save\n" >/dev/null 2>&1 || true
        sleep 3
    fi
}

create_backup() {
    mkdir -p "$BACKUP_DIR"

    if [ ! -d "$WORLDS_DIR" ]; then
        log "ERRO: Pasta de mundos nao encontrada: $WORLDS_DIR"
        return 1
    fi

    cd "$SERVER_DIR" || return 1

    if ionice -c3 tar -I "zstd ${ZSTD_LEVEL}" -cf "$BACKUP_DIR/$BACKUP_NAME" "$(basename "$WORLDS_DIR")" "$(basename "$CONFIG_DIR")"; then
        log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        return 0
    fi

    log "ERRO: Falha ao criar backup."
    return 1
}

cleanup_old_backups() {
    find "$BACKUP_DIR" -name "terraria-backup-*.tar.zst" -type f -mtime +"$RETENTION_DAYS" -delete
}

main() {
    notify_server "[Backup] Iniciando backup automatico..."
    trigger_save

    if create_backup; then
        cleanup_old_backups
        notify_server "[Backup] Backup concluido com sucesso."
        log "Backup concluido com sucesso."
    else
        notify_server "[Backup] Falha no backup."
        exit 1
    fi
}

main
