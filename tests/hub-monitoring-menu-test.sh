#!/usr/bin/env bash
# Characterization of the real Hub Monitoring menu before extracting its handler.
# Uses the numeric fallback and intercepts sudo; never starts monitoring tools.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_case() {
    local label="$1" stack="$2" input="$3" expected="$4"
    local exit_choice manager result=0 actual="$tmp/actions" output="$tmp/output"
    case "$stack" in
        minecraft) exit_choice=9; manager="/usr/local/libexec/crias/mc-manager.sh" ;;
        terraria) exit_choice=8; manager="/usr/local/libexec/crias/tt-manager.sh" ;;
        *) fail "invalid fixture stack: $stack" ;;
    esac
    input="${input//@EXIT@/$exit_choice}"
    expected="${expected//@MANAGER@/$manager}"
    : > "$actual"

    printf '%b' "$input" | LOG_CAPTURE="$actual" TEST_STACK="$stack" TERM=dumb timeout 12 \
        bash -c '
            source "$1"
            detect_stack() { printf "%s\n" "$TEST_STACK"; }
            hub_ensure_gum() { :; }
            hub_gum_interactive() { return 1; }
            show_header() { :; }
            sudo() { printf "%s\n" "$*" >> "$LOG_CAPTURE"; }
            main
        ' _ "$root/crias-tui.sh" > "$output" 2>&1 || result=$?

    [ "$result" -eq 0 ] || { tail -35 "$output" >&2; fail "$label: hub exited $result"; }
    if [ "$(cat "$actual")" != "$expected" ]; then
        tail -35 "$output" >&2
        fail "$label: expected [$expected], got [$(cat "$actual")]"
    fi
    grep -Fq 'Crias-Server Hub encerrado.' "$output" ||
        fail "$label: hub did not return to main menu"
    echo "OK: $label"
}

# Main Monitoramento = 5 for Minecraft, 4 for Terraria.
# Submenu order: btop (CPU)=1; ncdu (disk)=2; back=3.
run_case "minecraft btop" minecraft '5\n1\n@EXIT@\n' '@MANAGER@ monitor cpu'
run_case "minecraft ncdu" minecraft '5\n2\n@EXIT@\n' '@MANAGER@ monitor disk'
run_case "minecraft back" minecraft '5\n3\n@EXIT@\n' ''
run_case "minecraft invalid" minecraft '5\n0\n@EXIT@\n' ''
run_case "minecraft blank cancels" minecraft '5\n\n@EXIT@\n' ''
run_case "minecraft EOF cancels" minecraft '5\n' ''
run_case "terraria btop" terraria '4\n1\n@EXIT@\n' '@MANAGER@ monitor cpu'
run_case "terraria ncdu" terraria '4\n2\n@EXIT@\n' '@MANAGER@ monitor disk'
run_case "terraria back" terraria '4\n3\n@EXIT@\n' ''
run_case "terraria adjacent Files" terraria '3\n3\n@EXIT@\n' '@MANAGER@ files mods'

echo 'OK: 10 Monitoring Hub navigation contracts (both stacks, real fallback, stubbed sudo)'
