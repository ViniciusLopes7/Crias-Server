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
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-terraria}"

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

backup_owner_spec() {
    stat -c '%U:%G' "$SERVER_DIR" 2>/dev/null || true
}

adopt_backup_ownership() {
    local target_path="$1"
    local owner_spec

    if [ "$(id -u)" -ne 0 ]; then
        return 0
    fi

    owner_spec="$(backup_owner_spec)"
    if [ -n "$owner_spec" ] && [ "$owner_spec" != "root:root" ] && [ -e "$target_path" ]; then
        chown "$owner_spec" "$target_path" 2>/dev/null || true
    fi
}

create_backup() {
    mkdir -p "$BACKUP_DIR"
    adopt_backup_ownership "$BACKUP_DIR"
    exec 200>"$BACKUP_DIR/.backup.lock"
    adopt_backup_ownership "$BACKUP_DIR/.backup.lock"
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
        adopt_backup_ownership "$BACKUP_DIR/$BACKUP_NAME"
        log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        return 0
    fi

    log "ERRO: Falha ao criar backup."
    return 1
}

cleanup_old_backups() {
    local cutoff_timestamp
    local backup_file
    local backup_name
    local backup_timestamp

    cutoff_timestamp="$(date -d "$RETENTION_DAYS days ago" +%Y%m%d-%H%M%S 2>/dev/null || true)"
    if [ -z "$cutoff_timestamp" ]; then
        find "$BACKUP_DIR" -name "terraria-backup-*.tar.zst" -type f -mtime +"$RETENTION_DAYS" -delete
        return 0
    fi

    shopt -s nullglob
    for backup_file in "$BACKUP_DIR"/terraria-backup-*.tar.zst; do
        backup_name="$(basename "$backup_file")"
        backup_timestamp="${backup_name#terraria-backup-}"
        backup_timestamp="${backup_timestamp%.tar.zst}"

        if [[ "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "$backup_timestamp" < "$cutoff_timestamp" ]]; then
            rm -f "$backup_file"
        fi
    done
    shopt -u nullglob
}

is_service_active_or_skip() {
    if [ "$BACKUP_REQUIRE_ACTIVE_SERVICE" != "true" ]; then
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if ! systemctl show -p LoadState "$BACKUP_SERVICE_NAME.service" >/dev/null 2>&1; then
        log "AVISO: Nao foi possivel verificar status de ${BACKUP_SERVICE_NAME}.service; seguindo backup."
        return 0
    fi

    if systemctl is-active --quiet "$BACKUP_SERVICE_NAME.service"; then
        return 0
    fi

    log "Servidor ${BACKUP_SERVICE_NAME} offline. Backup cancelado."
    return 1
}

main() {
    if ! is_service_active_or_skip; then
        exit 0
    fi

    if create_backup; then
        cleanup_old_backups
        log "Backup concluido com sucesso."
    else
        exit 1
    fi
}

main
