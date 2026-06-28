#!/bin/bash
# tests/lib/cleanup.sh
#
# Helper compartilhado para cleanup seguro de diretórios temporários em testes.
# Source: `source "$ROOT_DIR/tests/lib/cleanup.sh"`

safe_cleanup_dir() {
    local target_dir="${1:-}"

    if [ -z "$target_dir" ] || [ "$target_dir" = "/" ]; then
        return 1
    fi

    rm -rf -- "$target_dir"
}
