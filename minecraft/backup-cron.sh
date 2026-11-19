#!/bin/bash
# minecraft/backup-cron.sh
#
# Minecraft backup using shared/lib/backup-engine.sh.
# Stack-specific: RCON save-lock before/after backup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/world" ] && [ -d "/opt/minecraft-server/world" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
fi

# Load shared libs (installed in .shared/ at runtime).
COMMON_LIB="$SCRIPT_DIR/.shared/common.sh"
BACKUP_LIB="$SCRIPT_DIR/.shared/backup-engine.sh"

if [ -f "$BACKUP_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$BACKUP_LIB"
else
    # Dev fallback: source directly from repo.
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/common.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/backup-engine.sh"
fi

# ---------------------------------------------------------------------------
# Minecraft backup config. Variables read by backup_run() in backup-engine.sh.
# shellcheck disable=SC2034  # BACKUP_STACK_NAME, BACKUP_DIRS used by backup-engine.sh
# ---------------------------------------------------------------------------
BACKUP_SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_STACK_NAME="minecraft"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-minecraft}"
BACKUP_DIRS=("world" "world_nether" "world_the_end")

# Inherit legacy variables (backward compat).
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

    if MCRCON_PASS="$rcon_pass" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-off" >/dev/null 2>&1; then
        RCON_SAVE_LOCK_ACTIVE=true
        RCON_PASSWORD="$rcon_pass"
        backup_log "Saves pausados via RCON. Aguardando flush..."

        # save-all fail-closed (CR-16): sem flush confirmado o tar nao e
        # confiavel. Duas tentativas; falhou -> aborta o backup (o EXIT trap
        # do engine restaura save-on). Antes: `|| true` prosseguia com o tar
        # sem garantia de consistencia.
        local flush_ok=false
        local flush_attempt=1
        while [ "$flush_attempt" -le 2 ]; do
            if MCRCON_PASS="$rcon_pass" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-all" >/dev/null 2>&1; then
                flush_ok=true
                break
            fi
            flush_attempt=$((flush_attempt + 1))
            [ "$flush_attempt" -le 2 ] && sleep 2
        done
        if [ "$flush_ok" != "true" ]; then
            backup_log "ERRO: save-all falhou apos $((flush_attempt - 1)) tentativa(s); abortando backup (saves serao reativados)."
            return 1
        fi
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

    local attempt=1
    local max_attempts=3
    while [ "$attempt" -le "$max_attempts" ]; do
        if MCRCON_PASS="$RCON_PASSWORD" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-on" >/dev/null 2>&1; then
            backup_log "Saves reativados via RCON."
            RCON_SAVE_LOCK_ACTIVE=false
            return 0
        fi
        backup_log "AVISO: Falha ao reativar saves (tentativa $attempt/$max_attempts)."
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_attempts" ] && sleep 5
    done

    backup_log "ERRO CRITICO: Nao foi possivel reativar saves via RCON apos $max_attempts tentativas."
    backup_log "ERRO CRITICO: O servidor pode estar com save-off ativo. Verifique manualmente com 'mcrcon save-on'."
    RCON_SAVE_LOCK_ACTIVE=false
    return 1
}

# ---------------------------------------------------------------------------
# Escopo do backup (CR-13/CR-14): resolve o mundo efetivo via level-name do
# server.properties (mundos customizados nunca eram backupeados) e inclui
# configuracao essencial. Mods entram por padrao; desative com
# BACKUP_INCLUDE_MODS=false no runtime.env se os backups ficarem grandes.
# ---------------------------------------------------------------------------
MC_LEVEL_NAME="$(read_server_property "level-name" 2>/dev/null || true)"
MC_LEVEL_NAME="${MC_LEVEL_NAME:-world}"
BACKUP_DIRS=("$MC_LEVEL_NAME" "${MC_LEVEL_NAME}_nether" "${MC_LEVEL_NAME}_the_end" "server.properties" "config")
if is_true "${BACKUP_INCLUDE_MODS:-true}"; then
    BACKUP_DIRS+=("mods")
fi

# Compat: função is_service_active_or_skip e backup_log() herdadas da backup-engine.

# Guard de execução direta: permite `source` em testes sem disparar backup.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_run
fi
