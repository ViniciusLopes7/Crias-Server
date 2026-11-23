#!/usr/bin/env bash
# Characterization of the existing Hub navigation before extracting handlers.
# Runs the real numeric-menu flow; all administrative actions are intercepted.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
manager="/usr/local/libexec/crias/mc-manager.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_case() {
    local label="$1" input="$2" expected="$3"
    local output="$tmp/output" actual="$tmp/actions" result=0

    : > "$actual"
    # Commands are read by the actual hub_choose fallback from stdin.
    # The command stub runs in the caller, never invokes sudo or systemd.
    printf '%b' "$input" | LOG_CAPTURE="$actual" TERM=dumb timeout 12 \
        bash -c '
            source "$1"
            detect_stack() { echo minecraft; }
            hub_ensure_gum() { :; }
            hub_gum_interactive() { return 1; }
            show_header() { :; }
            sudo() { printf "%s\n" "$*" >> "$LOG_CAPTURE"; }
            main
        ' _ "$root/crias-tui.sh" > "$output" 2>&1 || result=$?

    if [ "$result" -ne 0 ]; then
        tail -40 "$output" >&2
        fail "$label: hub terminou com status $result"
    fi
    if [ "$(cat "$actual")" != "$expected" ]; then
        cat "$output" >&2
        fail "$label: esperado [$expected], executado [$(cat "$actual")]"
    fi
    grep -Fq 'Crias-Server Hub encerrado.' "$output" ||
        fail "$label: fluxo nao voltou ao menu principal/Sair"
    printf 'OK: %s\n' "$label"
}

# The main menu option 1 opens Servidor; option 5 opens Memoria Java.
# Inside memory, status=1, fixed=2, manual=3, auto=4, back=5.
run_case "status" '1\n5\n1\n\n9\n' "$manager memory status"
run_case "fixed confirmed" '1\n5\n2\n1\n\n9\n' "$manager memory fixed"
run_case "fixed cancelled" '1\n5\n2\n2\n9\n' ""
run_case "manual fixed" '1\n5\n3\n3072\n1\n\n9\n' "$manager memory set 3072 fixed"
run_case "manual adaptive" '1\n5\n3\n4096\n2\n\n9\n' "$manager memory set 4096 dynamic"
run_case "manual invalid" '1\n5\n3\nabc\n\n9\n' ""
run_case "manual mode cancelled" '1\n5\n3\n4096\n3\n9\n' ""
run_case "automatic confirmed" '1\n5\n4\n1\n\n9\n' "$manager memory auto"
run_case "automatic cancelled" '1\n5\n4\n2\n9\n' ""
run_case "memory back" '1\n5\n5\n9\n' ""

# Adjacent menu must not be affected: Chunky watch is option 3 in Servidor.
run_case "chunky 10 seconds" '1\n3\n1\n9\n' "$manager chunky watch 10"
run_case "chunky 5 seconds" '1\n3\n2\n9\n' "$manager chunky watch 5"
run_case "chunky back" '1\n3\n5\n9\n' ""

printf 'OK: Hub menu memory/Chunky characterization (real fallback input; stubbed sudo)\n'
