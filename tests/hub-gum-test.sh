#!/usr/bin/env bash
# Ensure gum is required on the installed Arch host, and repaired on failure.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$root/install.sh"

pacman_calls=0
gum_healthy=false
gum() {
    [ "$1" = "--version" ] && [ "$gum_healthy" = true ]
}
pacman() {
    [ "$*" = "-S --noconfirm gum" ] || {
        echo "FAIL: pacman chamado com argumentos inesperados: $*" >&2
        return 1
    }
    pacman_calls=$((pacman_calls + 1))
    gum_healthy=true
}

# DRY_RUN must not modify host or require package tools.
DRY_RUN=true
ensure_hub_gum >/dev/null
[ "$pacman_calls" = 0 ] || { echo "FAIL: DRY_RUN chamou pacman" >&2; exit 1; }

# Broken gum must be repaired on real installs and verified after the action.
DRY_RUN=false
ensure_hub_gum >/dev/null
[ "$pacman_calls" = 1 ] || { echo "FAIL: gum nao foi reparado" >&2; exit 1; }
ensure_hub_gum >/dev/null
[ "$pacman_calls" = 1 ] || { echo "FAIL: reinstall repetido sem necessidade" >&2; exit 1; }

# A failing package installer must prevent a misleading successful setup.
gum_healthy=false
pacman() { return 21; }
if ensure_hub_gum >/dev/null 2>&1; then
    echo "FAIL: instalacao de gum quebrada foi aceita" >&2
    exit 1
fi

# Hub doctor and numeric fallback must remain usable in non-TTY mode.
bash "$root/crias-tui.sh" --doctor >/dev/null
printf '2\n' | bash -c 'source "$1"; hub_choose "Teste" "Um" "Dois"' _ "$root/crias-tui.sh" | grep -qx Dois

# During actual installation the gum check must precede Hub deployment.
first="$(grep -n '^    ensure_hub_gum$' "$root/install.sh" | head -n 1 | cut -d: -f1)"
second="$(grep -n '^    deploy_crias_tui$' "$root/install.sh" | head -n 1 | cut -d: -f1)"
[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || {
    echo "FAIL: gum checado depois do deploy" >&2
    exit 1
}
echo "OK: gum instalado e verificado antes do Hub, recuperacao, fail-closed e modo fallback"
