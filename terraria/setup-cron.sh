#!/bin/bash
# terraria/setup-cron.sh
#
# Wrapper fino sobre shared/lib/setup-cron.sh (item A2 do plano).
# Apenas configura variáveis específicas do stack e delega.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carrega common.sh (preferencialmente do .shared instalado).
COMMON_LIB="$SCRIPT_DIR/.shared/common.sh"
if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
else
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/common.sh"
fi

# Carrega setup-cron.sh (preferencialmente do .shared instalado).
SETUP_CRON_LIB="$SCRIPT_DIR/.shared/setup-cron.sh"
if [ -f "$SETUP_CRON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$SETUP_CRON_LIB"
else
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/setup-cron.sh"
fi

# Configuração específica do Terraria.
SETUP_CRON_STACK_NAME="terraria"
SETUP_CRON_SERVICE_NAME="terraria"
SETUP_CRON_SERVER_DIR="$SCRIPT_DIR"
SETUP_CRON_BACKUP_SCRIPT="$SCRIPT_DIR/backup-cron.sh"
SETUP_CRON_SERVER_USER="${SERVER_USER:-}"

setup_cron_run
