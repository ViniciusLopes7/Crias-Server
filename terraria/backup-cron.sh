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

# Detecta tModLoader: se server/LaunchUtils/ScriptCaller.sh existe, inclui Mods/ e Worlds/.
if [ -x "$BACKUP_SERVER_DIR/server/LaunchUtils/ScriptCaller.sh" ]; then
    BACKUP_DIRS+=("Mods" "Worlds")
fi

# Inherit legacy variables (backward compat).
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"

# Terraria has no RCON, so no pre/post hooks (just lock + tar).
# backup_pre_hook and backup_post_hook are not defined; engine skips both.

backup_run
