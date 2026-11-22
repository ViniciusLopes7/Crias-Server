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

# CRITICAL regression: within choice=$(hub_choose ...), stdout is a pipe
# even in an interactive SSH/PTY session. Previous [ -t 1 ] forced fallback.
# Mock Gum validates terminal routing without racing keyboard input in CI.
if command -v script >/dev/null 2>&1; then
    pty_tmp="$(mktemp -d /tmp/crias-hub-gum-pty.XXXXXXXX)"
    cat > "$pty_tmp/interactive.sh" <<'PTY_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
gum() {
    case "\${1:-}" in
        --version) echo "gum stub v1"; return 0 ;;
        choose)
            [ -t 0 ] && [ -t 2 ] && [ ! -t 1 ] || {
                echo "FAIL: Gum nao foi chamado em PTY com stdout capturado" >&2
                return 91
            }
            [ "\${2:-}" = "--header=Teste PTY  ·  ↑/↓ mover  Enter selecionar  Esc voltar" ] || {
                echo "FAIL: cabecalho do gum inesperado" >&2; return 92
            }
            printf '%s\n' "\${@: -1}"
            return 0 ;;
        *) return 93 ;;
    esac
}
selected=$(hub_choose "Teste PTY" "Primeiro" "Segundo")
[ "$selected" = "Segundo" ] || { echo "FAIL: sem menu por setas" >&2; exit 1; }
echo "GUM_TTY_SELECTION_OK"
PTY_SCRIPT
    chmod +x "$pty_tmp/interactive.sh"
    # script(1) allocates a PTY; no real interactive input is required.
    TERM=xterm-256color script -q -e -c "bash '$pty_tmp/interactive.sh' '$root/crias-tui.sh'" /dev/null > "$pty_tmp/output" 2>&1 || {
        cat "$pty_tmp/output" >&2
        rm -rf -- "$pty_tmp"
        echo "FAIL: teste PTY para o caminho Gum" >&2
        exit 1
    }
    grep -q "GUM_TTY_SELECTION_OK" "$pty_tmp/output" || {
        cat "$pty_tmp/output" >&2; rm -rf -- "$pty_tmp"; exit 1
    }
    rm -rf -- "$pty_tmp"
fi

# During actual installation the gum check must precede Hub deployment.
first="$(grep -n '^    ensure_hub_gum$' "$root/install.sh" | head -n 1 | cut -d: -f1)"
second="$(grep -n '^    deploy_crias_tui$' "$root/install.sh" | head -n 1 | cut -d: -f1)"
[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || {
    echo "FAIL: gum checado depois do deploy" >&2
    exit 1
}
echo "OK: gum instalado e verificado antes do Hub, recuperacao, fail-closed e modo fallback"
