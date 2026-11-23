#!/usr/bin/env bash
# Characterization: the Hub file shortcuts must preserve actions and cancel flow.
# Runs the actual numeric menu, intercepting sudo instead of touching the host.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_case() {
    local label="$1" stack="$2" input="$3" expected="$4" fail_area="${5:-}"
    local capture="$tmp/calls" output="$tmp/output" status=0 exit_choice manager

    case "$stack" in
        minecraft) exit_choice=9; manager="/usr/local/libexec/crias/mc-manager.sh" ;;
        terraria) exit_choice=8; manager="/usr/local/libexec/crias/tt-manager.sh" ;;
        *) fail "stack desconhecida na fixture: $stack" ;;
    esac
    input="${input//@EXIT@/$exit_choice}"
    expected="${expected//@MANAGER@/$manager}"
    : > "$capture"

    printf '%b' "$input" | \
        LOG_CAPTURE="$capture" TEST_STACK="$stack" FAIL_AREA="$fail_area" TERM=dumb \
        timeout 12 bash -c '
            source "$1"
            detect_stack() { printf "%s\n" "$TEST_STACK"; }
            hub_ensure_gum() { :; }
            hub_gum_interactive() { return 1; }
            show_header() { :; }
            sudo() {
                printf "%s\n" "$*" >> "$LOG_CAPTURE"
                if [ "${FAIL_AREA:-}" = "mods" ] && [ "${3:-}" = "mods" ]; then
                    return 27
                fi
            }
            main
        ' _ "$root/crias-tui.sh" > "$output" 2>&1 || status=$?

    if [ "$status" -ne 0 ]; then
        tail -40 "$output" >&2
        fail "$label: erro do Hub (status=$status)"
    fi
    if [ "$(cat "$capture")" != "$expected" ]; then
        tail -40 "$output" >&2
        fail "$label: esperado [$expected], encontrado [$(cat "$capture")]"
    fi
    grep -Fq 'Crias-Server Hub encerrado.' "$output" ||
        fail "$label: nao retornou ao menu principal"
    printf 'OK: %s\n' "$label"
}

# Minecraft: Files is option 3; its options are root, world, mods,
# config, backups, logs, setup-files, back (in that precise order).
run_case "minecraft root" minecraft '3\n1\n@EXIT@\n' '@MANAGER@ files root'
run_case "minecraft world" minecraft '3\n2\n@EXIT@\n' '@MANAGER@ files world'
run_case "minecraft mods" minecraft '3\n3\n@EXIT@\n' '@MANAGER@ files mods'
run_case "minecraft config" minecraft '3\n4\n@EXIT@\n' '@MANAGER@ files config'
run_case "minecraft backups" minecraft '3\n5\n@EXIT@\n' '@MANAGER@ files backups'
run_case "minecraft logs" minecraft '3\n6\n@EXIT@\n' '@MANAGER@ files logs'

# setup-files needs positive confirmation; cancellation and back do nothing.
run_case "minecraft setup confirmed" minecraft '3\n7\n1\n\n@EXIT@\n' '@MANAGER@ setup-files'
run_case "minecraft setup cancelled" minecraft '3\n7\n2\n@EXIT@\n' ''
run_case "minecraft files back" minecraft '3\n8\n@EXIT@\n' ''
run_case "minecraft files invalid" minecraft '3\n0\n@EXIT@\n' ''

# A failed manager files command must not kill the Hub; the pause remains.
run_case "minecraft files failure" minecraft '3\n3\n\n@EXIT@\n' '@MANAGER@ files mods' mods

# Same menu and manager path convention for Terraria, with 8 main choices.
run_case "terraria root" terraria '3\n1\n@EXIT@\n' '@MANAGER@ files root'
run_case "terraria world" terraria '3\n2\n@EXIT@\n' '@MANAGER@ files world'
run_case "terraria setup confirmed" terraria '3\n7\n1\n\n@EXIT@\n' '@MANAGER@ setup-files'
run_case "terraria setup cancelled" terraria '3\n7\n2\n@EXIT@\n' ''
run_case "terraria files back" terraria '3\n8\n@EXIT@\n' ''

# Adjacent main menu option Voice Chat (Minecraft) must remain unchanged.
run_case "adjacent Voice Chat status" minecraft '4\n1\n\n@EXIT@\n' '@MANAGER@ voicechat status'

echo 'OK: 17 Hub file/adjacent navigation contracts (real fallback, stub sudo)'
