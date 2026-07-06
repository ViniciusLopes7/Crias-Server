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

    # unsquashfs creates files with xattrs/capabilities that non-root can't rm.
    # chmod +w makes them removable; sudo is fallback if available.
    chmod -R u+w -- "$target_dir" 2>/dev/null || true
    rm -rf -- "$target_dir" 2>/dev/null || sudo rm -rf -- "$target_dir" 2>/dev/null || true
}
