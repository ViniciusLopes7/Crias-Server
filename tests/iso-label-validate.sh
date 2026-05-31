#!/bin/bash

set -euo pipefail


ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Recompute iso_label using the same logic as profiledef.sh but in a portable way
git_short=""
if command -v git >/dev/null 2>&1; then
    git_short="$(git -C "$ROOT_DIR" rev-parse --short=6 HEAD 2>/dev/null || true)"
fi

if [ -n "$git_short" ]; then
    prefix="$(printf '%.5s' "$git_short" | tr '[:lower:]' '[:upper:]')"
    iso_label="CRIAS${prefix}"
else
    iso_label="CRIASNOGIT0"
fi

# Trim to 11 chars (FAT limit)
iso_label="$(echo "$iso_label" | cut -c1-11)"

if [ -z "$iso_label" ]; then
    echo "iso_label computation failed" >&2
    exit 1
fi

echo "iso_label OK: $iso_label"
