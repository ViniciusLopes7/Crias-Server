#!/bin/bash
# minecraft/backup-cron.sh
#
# Backup do Minecraft usando shared/lib/backup-engine.sh (item A3 do plano).
# Stack-specific: RCON save-lock antes/depois do backup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/world" ] && [ -d "/opt/minecraft-server/world" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
fi

# Carrega libs compartilhadas (instaladas em .shared/ no runtime).
COMMON_LIB="$SCRIPT_DIR/.shared/common.sh"
BACKUP_LIB="$SCRIPT_DIR/.shared/backup-engine.sh"

if [ -f "$BACKUP_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$BACKUP_LIB"
else
    # Fallback para dev: source direto do repo
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/common.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/backup-engine.sh"
fi

# ---------------------------------------------------------------------------
# Configuração do backup para Minecraft.
# Variáveis lidas por backup_run() em shared/lib/backup-engine.sh.
# shellcheck disable=SC2034  # BACKUP_STACK_NAME, BACKUP_DIRS usadas por backup-engine.sh
# ---------------------------------------------------------------------------
BACKUP_SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_STACK_NAME="minecraft"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-minecraft}"
BACKUP_DIRS=("world" "world_nether" "world_the_end")

# Herda variáveis legadas (compat retroativa).
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"
MCRCON_HOST="${MCRCON_HOST:-localhost}"
MCRCON_PORT="${MCRCON_PORT:-25575}"

# Estado do RCON save-lock (compartilhado entre hooks).
RCON_SAVE_LOCK_ACTIVE=false
RCON_PASSWORD=""

# ---------------------------------------------------------------------------
# Lê server.properties para config RCON.
# ---------------------------------------------------------------------------
read_server_property() {
    local key="$1"
    local props_file="$BACKUP_SERVER_DIR/server.properties"

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

# ---------------------------------------------------------------------------
# Hook pre-backup: pausa saves via RCON (save-off + save-all).
# ---------------------------------------------------------------------------
backup_pre_hook() {
    local rcon_pass
    local rcon_enabled
    local rcon_port

    RCON_SAVE_LOCK_ACTIVE=false
    RCON_PASSWORD=""

    if ! command -v mcrcon >/dev/null 2>&1; then
        backup_log "AVISO: mcrcon nao encontrado. Backup seguira sem pausas de save via RCON."
        return 0
    fi

    rcon_enabled="$(read_server_property "enable-rcon" 2>/dev/null || true)"
    rcon_pass="$(read_server_property "rcon.password" 2>/dev/null || true)"
    rcon_port="$(read_server_property "rcon.port" 2>/dev/null || true)"

    if [ -z "$rcon_pass" ]; then
        backup_log "AVISO: RCON nao configurado em $BACKUP_SERVER_DIR/server.properties. Backup seguira em modo best-effort."
        return 0
    fi

    if [ -n "$rcon_enabled" ] && [ "$rcon_enabled" != "true" ]; then
        backup_log "AVISO: RCON desabilitado em $BACKUP_SERVER_DIR/server.properties. Backup seguira em modo best-effort."
        return 0
    fi

    if [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        MCRCON_PORT="$rcon_port"
    fi

    if MCRCON_PASS="$rcon_pass" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-off" "save-all" >/dev/null 2>&1; then
        RCON_SAVE_LOCK_ACTIVE=true
        RCON_PASSWORD="$rcon_pass"
        backup_log "Saves pausados via RCON. Aguardando flush..."
        sleep 3
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Hook post-backup: reativa saves via RCON (save-on).
# ---------------------------------------------------------------------------
backup_post_hook() {
    if [ "${RCON_SAVE_LOCK_ACTIVE:-false}" != "true" ]; then
        return 0
    fi

    # shellcheck disable=SC2310
    MCRCON_PASS="$RCON_PASSWORD" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-on" >/dev/null 2>&1 || true
    backup_log "Saves reativados via RCON."
    RCON_SAVE_LOCK_ACTIVE=false
}

# Compat: função is_service_active_or_skip e backup_log() herdadas da backup-engine.

backup_run
