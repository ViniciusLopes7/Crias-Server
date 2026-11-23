#!/usr/bin/env bash
# Characterization: Voice Chat Hub menu dispatches the same manager commands.
# Fallback exercises real stdin; PTY checks the separate Gum input path.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_case() {
    local label="$1" stack="$2" input="$3" expected="$4" fail_action="${5:-}"
    local manager exit_choice output="$tmp/output" actual="$tmp/actions" result=0
    if [ "$stack" = minecraft ]; then
        manager="/usr/local/libexec/crias/mc-manager.sh"
        exit_choice=9
    else
        manager="/usr/local/libexec/crias/tt-manager.sh"
        exit_choice=8
    fi
    input="${input//@EXIT@/$exit_choice}"
    expected="${expected//@MANAGER@/$manager}"
    : > "$actual"
    printf '%b' "$input" | LOG_CAPTURE="$actual" TEST_STACK="$stack" FAIL_ACTION="$fail_action" TERM=dumb \
        timeout 12 bash -c '
            source "$1"
            detect_stack() { echo "$TEST_STACK"; }
            hub_ensure_gum() { :; }
            hub_gum_interactive() { return 1; }
            show_header() { :; }
            sudo() {
                printf "%s\n" "$*" >> "$LOG_CAPTURE"
                if [ -n "$FAIL_ACTION" ] && [ "${3:-}" = "$FAIL_ACTION" ]; then return 42; fi
            }
            main
        ' _ "$root/crias-tui.sh" > "$output" 2>&1 || result=$?
    [ "$result" -eq 0 ] || { tail -35 "$output" >&2; fail "$label: exit $result"; }
    if [ "$(cat "$actual")" != "$expected" ]; then
        tail -35 "$output" >&2
        fail "$label: esperado [$expected] e recebido [$(cat "$actual")]"
    fi
    grep -Fq 'Crias-Server Hub encerrado.' "$output" ||
        fail "$label: fluxo nao retornou ao menu principal"
    if [ "$stack" = terraria ]; then
        ! grep -Fq 'Simple Voice Chat' "$output" ||
            fail "$label: menu Voice Chat foi mostrado para Terraria"
    fi
    echo "OK: $label"
}

# Minecraft main=4 (Voice Chat), submenu: status=1 edit=2 port=3 network=4 back=5.
run_case "status" minecraft '4\n1\n\n@EXIT@\n' '@MANAGER@ voicechat status'
run_case "status error tolerated" minecraft '4\n1\n\n@EXIT@\n' '@MANAGER@ voicechat status' status
run_case "edit" minecraft '4\n2\n@EXIT@\n' '@MANAGER@ voicechat edit'
run_case "set port" minecraft '4\n3\n24455\n\n@EXIT@\n' '@MANAGER@ voicechat set-port 24455'
run_case "empty port cancels" minecraft '4\n3\n\n@EXIT@\n' ''
run_case "port EOF cancels" minecraft '4\n3\n' ''
run_case "network help" minecraft '4\n4\n\n@EXIT@\n' '@MANAGER@ voicechat network'
run_case "network error tolerated" minecraft '4\n4\n\n@EXIT@\n' '@MANAGER@ voicechat network' network
run_case "back" minecraft '4\n5\n@EXIT@\n' ''
run_case "invalid submenu" minecraft '4\n0\n@EXIT@\n' ''
run_case "menu choice EOF" minecraft '4\n' ''

# Adjacent File shortcuts must retain their choice/command.
run_case "adjacent Files" minecraft '3\n3\n@EXIT@\n' '@MANAGER@ files mods'

# Terraria must not expose a Voice Chat action; main option 4 is Monitoramento.
run_case "terraria monitor" terraria '4\n1\n@EXIT@\n' '@MANAGER@ monitor cpu'
run_case "terraria adjacent files" terraria '3\n1\n@EXIT@\n' '@MANAGER@ files root'

# Real pseudo-TTY: the menu uses fallback numbers for deterministic input,
# while port editing uses the original Gum input path ([ -t 0 ] && [ -t 1 ]).
if command -v script >/dev/null 2>&1; then
    cat > "$tmp/pty.sh" <<'PTY'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
capture="$2" mode="$3"
detect_stack() { echo minecraft; }
hub_ensure_gum() { :; }
hub_gum_interactive() { return 1; }
show_header() { :; }
sudo() { printf '%s\n' "$*" >> "$capture"; }
gum() {
    [ "${1:-}" = input ] || return 70
    [ "${2:-}" = '--header=Porta UDP do Voice Chat (1024-65535):' ] || return 71
    [ "${3:-}" = '--placeholder=24454' ] || return 72
    if [ "$mode" = cancel ]; then return 17; fi
    printf '24455\n'
}
main
PTY
    chmod +x "$tmp/pty.sh"
    for mode in ok cancel; do
        : > "$tmp/pty-actions"
        if [ "$mode" = ok ]; then
            input='4\n3\n\n9\n'
            expected='/usr/local/libexec/crias/mc-manager.sh voicechat set-port 24455'
        else
            input='4\n3\n9\n'
            expected=''
        fi
        status=0
        printf '%b' "$input" | TERM=xterm-256color timeout 15 script -q -e \
            -c "bash '$tmp/pty.sh' '$root/crias-tui.sh' '$tmp/pty-actions' '$mode'" /dev/null \
            > "$tmp/pty-output" 2>&1 || status=$?
        [ "$status" -eq 0 ] || { tail -40 "$tmp/pty-output" >&2; fail "PTY Gum $mode: exit $status"; }
        [ "$(cat "$tmp/pty-actions")" = "$expected" ] ||
            fail "PTY Gum $mode: expected [$expected], got [$(cat "$tmp/pty-actions")]"
        grep -Fq 'Crias-Server Hub encerrado.' "$tmp/pty-output" ||
            fail "PTY Gum $mode: hub not closed"
        echo "OK: PTY Gum input $mode"
    done
fi

echo 'OK: Voice Chat Hub numeric navigation and PTY Gum input contracts'
