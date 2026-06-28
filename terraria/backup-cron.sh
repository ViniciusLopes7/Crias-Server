#!/bin/bash
# terraria/backup-cron.sh
#
# Backup do Terraria usando shared/lib/backup-engine.sh (item A3 do plano).
# Terraria não tem RCON, então não há hooks pre/post (apenas lock + tar).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/worlds" ] && [ -d "/opt/terraria-server/worlds" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
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
# Configuração do backup para Terraria.
# Variáveis lidas por backup_run() em shared/lib/backup-engine.sh.
# shellcheck disable=SC2034  # BACKUP_STACK_NAME, BACKUP_DIRS usadas por backup-engine.sh
# ---------------------------------------------------------------------------
BACKUP_SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_STACK_NAME="terraria"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-terraria}"
BACKUP_DIRS=("worlds" "config")

# Herda variáveis legados (compat retroativa).
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"

# Terraria não tem RCON, então não há hooks pre/post (apenas lock + tar).
# backup_pre_hook e backup_post_hook não são definidos; a engine pula ambos.

backup_run
