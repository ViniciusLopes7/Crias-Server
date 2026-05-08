#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/world" ] && [ -d "/opt/minecraft-server/world" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_DIR="$SERVER_DIR/backups"
WORLD_DIRS=("world" "world_nether" "world_the_end")
RUNTIME_ENV="$SERVER_DIR/runtime.env"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:-}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
MCRCON_HOST="${MCRCON_HOST:-localhost}"
MCRCON_PORT="${MCRCON_PORT:-25575}"
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-minecraft}"

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

read_server_property() {
    local key="$1"
    local props_file="$SERVER_DIR/server.properties"

    if [ ! -f "$props_file" ]; then
        return 1
    fi

    awk -F'=' -v key="$key" '
        $1 == key {
            value = substr($0, index($0, "=") + 1)
            print value
        }
    ' "$props_file" | tail -n 1
}

enable_rcon_save_lock() {
    local rcon_pass
    local rcon_enabled
    local rcon_port

    RCON_SAVE_LOCK_ACTIVE=false
    RCON_PASSWORD=""

    if ! command -v mcrcon >/dev/null 2>&1; then
        return 0
    fi

    rcon_enabled="$(read_server_property "enable-rcon" 2>/dev/null || true)"
    rcon_pass="$(read_server_property "rcon.password" 2>/dev/null || true)"
    rcon_port="$(read_server_property "rcon.port" 2>/dev/null || true)"

    if [ -z "$rcon_pass" ]; then
        return 0
    fi

    if [ -n "$rcon_enabled" ] && [ "$rcon_enabled" != "true" ]; then
        return 0
    fi

    if [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        MCRCON_PORT="$rcon_port"
    fi

    if mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" -p "$rcon_pass" "save-off" "save-all" >/dev/null 2>&1; then
        RCON_SAVE_LOCK_ACTIVE=true
        RCON_PASSWORD="$rcon_pass"
        log "Saves pausados via RCON. Aguardando flush..."
        sleep 3
    fi

    return 0
}

disable_rcon_save_lock() {
    if [ "${RCON_SAVE_LOCK_ACTIVE:-false}" != "true" ]; then
        return 0
    fi

    mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" -p "$RCON_PASSWORD" "save-on" >/dev/null 2>&1 || true
    log "Saves reativados via RCON."
    RCON_SAVE_LOCK_ACTIVE=false
}

create_backup() {
    local backup_dirs=()

    mkdir -p "$BACKUP_DIR"
    exec 200>"$BACKUP_DIR/.backup.lock"
    if ! flock -n 200; then
        log "ERRO: Ja existe um backup em andamento. Abortando nova execucao."
        return 1
    fi

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

    if ! command -v zstd >/dev/null 2>&1; then
        log "ERRO: zstd nao encontrado no PATH. Instale (pacman -S zstd) ou ajuste o PATH do cron."
        return 1
    fi

    enable_rcon_save_lock

    if [ "$BACKUP_DRY_RUN" = "true" ]; then
        log "[DRY_RUN] Backup simulado para: ${backup_dirs[*]}"
        disable_rcon_save_lock
        return 0
    fi

    if ionice -c2 -n7 tar -I "zstd ${ZSTD_LEVEL}" -cf "$BACKUP_DIR/$BACKUP_NAME" "${backup_dirs[@]}"; then
        disable_rcon_save_lock
        log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        return 0
    fi

    disable_rcon_save_lock
    log "ERRO: Falha ao criar backup."
    return 1
}

cleanup_old_backups() {
    find "$BACKUP_DIR" -name "minecraft-backup-*.tar.zst" -type f -mtime +"$RETENTION_DAYS" -delete
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
    if [ ! -d "$SERVER_DIR" ]; then
        log "ERRO: Diretorio do servidor nao encontrado: $SERVER_DIR"
        exit 1
    fi

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
