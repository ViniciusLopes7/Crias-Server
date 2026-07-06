#!/bin/bash
# terraria/setup-cron.sh
#
# Thin wrapper over shared/lib/setup-cron.sh. Sets stack-specific variables
# and delegates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load common.sh (prefer installed .shared).
COMMON_LIB="$SCRIPT_DIR/.shared/common.sh"
if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
else
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/common.sh"
fi

# Load setup-cron.sh (prefer installed .shared).
SETUP_CRON_LIB="$SCRIPT_DIR/.shared/setup-cron.sh"
if [ -f "$SETUP_CRON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$SETUP_CRON_LIB"
else
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/setup-cron.sh"
fi

# Terraria-specific config. Variables read by setup_cron_run() in shared/lib/setup-cron.sh.
# shellcheck disable=SC2034
SETUP_CRON_STACK_NAME="terraria"
SETUP_CRON_SERVICE_NAME="terraria"
SETUP_CRON_SERVER_DIR="$SCRIPT_DIR"
SETUP_CRON_BACKUP_SCRIPT="$SCRIPT_DIR/backup-cron.sh"
SETUP_CRON_SERVER_USER="${SERVER_USER:-}"

setup_cron_run
