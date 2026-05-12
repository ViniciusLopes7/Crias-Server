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
        log "AVISO: mcrcon nao encontrado. Backup seguira sem pausas de save via RCON."
        return 0
    fi

    rcon_enabled="$(read_server_property "enable-rcon" 2>/dev/null || true)"
    rcon_pass="$(read_server_property "rcon.password" 2>/dev/null || true)"
    rcon_port="$(read_server_property "rcon.port" 2>/dev/null || true)"

    if [ -z "$rcon_pass" ]; then
        log "AVISO: RCON nao configurado em $SERVER_DIR/server.properties. Backup seguira em modo best-effort."
        return 0
    fi

    if [ -n "$rcon_enabled" ] && [ "$rcon_enabled" != "true" ]; then
        log "AVISO: RCON desabilitado em $SERVER_DIR/server.properties. Backup seguira em modo best-effort."
        return 0
    fi

    if [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        MCRCON_PORT="$rcon_port"
    fi

    if MCRCON_PASS="$rcon_pass" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-off" "save-all" >/dev/null 2>&1; then
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

    MCRCON_PASS="$RCON_PASSWORD" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-on" >/dev/null 2>&1 || true
    log "Saves reativados via RCON."
    RCON_SAVE_LOCK_ACTIVE=false
}

create_backup() {
    local backup_dirs=()

    mkdir -p "$BACKUP_DIR"
    adopt_backup_ownership "$BACKUP_DIR"
    exec 200>"$BACKUP_DIR/.backup.lock"
    adopt_backup_ownership "$BACKUP_DIR/.backup.lock"
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
        adopt_backup_ownership "$BACKUP_DIR/$BACKUP_NAME"
        disable_rcon_save_lock
        log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        return 0
    fi

    disable_rcon_save_lock
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
        find "$BACKUP_DIR" -name "minecraft-backup-*.tar.zst" -type f -mtime +"$RETENTION_DAYS" -delete
        return 0
    fi

    shopt -s nullglob
    for backup_file in "$BACKUP_DIR"/minecraft-backup-*.tar.zst; do
        backup_name="$(basename "$backup_file")"
        backup_timestamp="${backup_name#minecraft-backup-}"
        backup_timestamp="${backup_timestamp%.tar.zst}"

        if [[ "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "$backup_timestamp" < "$cutoff_timestamp" ]]; then
            rm -f "$backup_file"
        fi
    done
    shopt -u nullglob
}

is_service_active_or_skip() {
    # In dry-run mode, skip checking the real service state so the dry-run
    # exercise still exercises RCON and backup logic for tests.
    if [ "$BACKUP_DRY_RUN" = "true" ]; then
        log "[DRY_RUN] Pulando verificacao de status do serviço"
        return 0
    fi
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
