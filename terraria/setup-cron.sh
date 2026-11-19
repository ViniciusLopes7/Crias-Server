#!/bin/bash
# terraria/setup-cron.sh
#
# Thin wrapper over shared/lib/setup-cron.sh. Sets stack-specific variables
# and delegates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# (EXP-34/AUDIT-A-P1) Wrapper ADMINISTRATIVO: instalado em
# /usr/local/libexec/crias (root:root). Resolve as libs do libexec primeiro;
# fallbacks para .shared do servidor (legado) e repo (desenvolvimento).
CRIS_LIBEXEC_LIB_DIR="/usr/local/libexec/crias/lib"

load_crias_lib() {
    local lib_name="$1"
    if [ -f "$CRIS_LIBEXEC_LIB_DIR/$lib_name" ]; then
        # shellcheck source=/dev/null
        source "$CRIS_LIBEXEC_LIB_DIR/$lib_name"
        return 0
    fi
    local server_dir="${SERVER_DIR:-/opt/terraria-server}"
    if [ -f "$server_dir/.shared/$lib_name" ]; then
        # shellcheck source=/dev/null
        source "$server_dir/.shared/$lib_name"
        return 0
    fi
    local root_dir
    root_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ -f "$root_dir/shared/lib/$lib_name" ]; then
        # shellcheck source=/dev/null
        source "$root_dir/shared/lib/$lib_name"
        return 0
    fi
    return 1
}

if ! load_crias_lib common.sh; then
    echo "[ERRO] common.sh nao encontrado (libexec/.shared/repo)." >&2
    exit 1
fi
if ! load_crias_lib setup-cron.sh; then
    echo "[ERRO] setup-cron.sh nao encontrado (libexec/.shared/repo)." >&2
    exit 1
fi

# Terraria-specific config. Variables read by setup_cron_run() in shared/lib/setup-cron.sh.
# shellcheck disable=SC2034
SETUP_CRON_STACK_NAME="terraria"
SETUP_CRON_SERVICE_NAME="terraria"
# (EXP-34) Diretorio do servidor: default do stack com override SERVER_DIR —
# o SCRIPT_DIR so coincide quando rodando do repo (desenvolvimento).
SETUP_CRON_SERVER_DIR="${SERVER_DIR:-/opt/terraria-server}"
SETUP_CRON_BACKUP_SCRIPT="$SETUP_CRON_SERVER_DIR/backup-cron.sh"
SETUP_CRON_SERVER_USER="${SERVER_USER:-}"

setup_cron_run
