#!/bin/bash
set -euo pipefail

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
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:-}"

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

create_backup() {
    mkdir -p "$BACKUP_DIR"
    exec 200>"$BACKUP_DIR/.backup.lock"
    if ! flock -n 200; then
        log "ERRO: Ja existe um backup em andamento. Abortando nova execucao."
        return 1
    fi

    if [ ! -d "$WORLDS_DIR" ]; then
        log "ERRO: Pasta de mundos nao encontrada: $WORLDS_DIR"
        return 1
    fi

    cd "$SERVER_DIR" || return 1

    if ! command -v zstd >/dev/null 2>&1; then
        log "ERRO: zstd nao encontrado no PATH. Instale (pacman -S zstd) ou ajuste o PATH do cron."
        return 1
    fi

    if ionice -c2 -n7 tar -I "zstd ${ZSTD_LEVEL}" -cf "$BACKUP_DIR/$BACKUP_NAME" "$(basename "$WORLDS_DIR")" "$(basename "$CONFIG_DIR")"; then
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
    if create_backup; then
        cleanup_old_backups
        log "Backup concluido com sucesso."
    else
        exit 1
    fi
}

main
