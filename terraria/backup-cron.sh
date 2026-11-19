#!/bin/bash
# terraria/backup-cron.sh
#
# Terraria backup using shared/lib/backup-engine.sh.
# Terraria has no RCON, so no pre/post hooks (just lock + tar).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/worlds" ] && [ -d "/opt/terraria-server/worlds" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
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
# Terraria backup config. Variables read by backup_run() in backup-engine.sh.
# shellcheck disable=SC2034  # BACKUP_STACK_NAME, BACKUP_DIRS used by backup-engine.sh
# ---------------------------------------------------------------------------
BACKUP_SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_STACK_NAME="terraria"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-terraria}"
# Diretórios de backup: worlds/ + config/ sempre; Mods/ + Worlds/ se tModLoader.
BACKUP_DIRS=("worlds" "config")

# Modo tML (CR-12): chave explicita do runtime.env com prioridade sobre a
# deteccao por artefato — mesma regra do start-terraria.sh.
TT_RUNTIME_MODE=""
if [ -f "$BACKUP_SERVER_DIR/runtime.env" ]; then
    TT_RUNTIME_MODE="$(grep -E '^TERRARIA_USE_TMODLOADER=' "$BACKUP_SERVER_DIR/runtime.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
fi
TT_IS_TML="false"
if [ "$TT_RUNTIME_MODE" = "true" ] || [ "$TT_RUNTIME_MODE" = "false" ]; then
    TT_IS_TML="$TT_RUNTIME_MODE"
elif [ -x "$BACKUP_SERVER_DIR/server/LaunchUtils/ScriptCaller.sh" ]; then
    TT_IS_TML="true"
fi

# tML: Worlds/ sao mundos (dados — sempre incluir); Mods/ sao jars
# re-baixaveis via SteamCMD (inclusos por padrao, opt-out via
# BACKUP_INCLUDE_MODS=false no runtime.env).
if [ "$TT_IS_TML" = "true" ]; then
    BACKUP_DIRS+=("Worlds")
    if is_true "${BACKUP_INCLUDE_MODS:-true}"; then
        BACKUP_DIRS+=("Mods")
    fi
fi

# Inherit legacy variables (backward compat).
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"

# Terraria has no RCON, so no pre/post hooks (just lock + tar).
# backup_pre_hook and backup_post_hook are not defined; engine skips both.

# Guard de execução direta: permite `source` em testes sem disparar backup.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_run
fi
