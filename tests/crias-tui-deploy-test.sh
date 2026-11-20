#!/bin/bash
# Regression tests for early TUI deploy and read-only diagnosis.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# The TUI fallback works without a TTY or the gum dependency.
choice="$(printf "2\n" | bash -c 'source "$1"; hub_choose "Teste" "Primeiro" "Segundo"' _ "$root/crias-tui.sh")"
[ "$choice" = "Segundo" ] || { echo "FAIL: menu numerado" >&2; exit 1; }
bash "$root/crias-tui.sh" --doctor >/dev/null
bash "$root/crias-tui.sh" --help | grep -q -- "--doctor"

# Deploy happens before the heavyweight stack installer begins.
first="$(grep -n "^    deploy_crias_tui$" "$root/install.sh" | head -n1 | cut -d: -f1)"
stack="$(grep -n "^    run_selected_stack_installer$" "$root/install.sh" | head -n1 | cut -d: -f1)"
[ -n "$first" ] && [ "$first" -lt "$stack" ] || { echo "FAIL: deploy tardio" >&2; exit 1; }

# Missing source or a copy failure must never be reported as success.
source "$root/install.sh"
DRY_RUN=false
old_dir="$SCRIPT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"; _crias_cleanup_temps' EXIT
SCRIPT_DIR="$tmp"
if deploy_crias_tui >/dev/null 2>&1; then
    echo "FAIL: fonte ausente foi aceita" >&2; exit 1
fi
SCRIPT_DIR="$old_dir"
install() { return 1; }
if deploy_crias_tui >/dev/null 2>&1; then
    echo "FAIL: copia mal-sucedida foi aceita" >&2; exit 1
fi
echo "OK: TUI antecipado, menu fallback, diagnostico e fail-closed"
