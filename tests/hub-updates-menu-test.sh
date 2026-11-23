#!/usr/bin/env bash
# Characterization of the Hub's update menu with the REAL numeric choices.
# Mock updater and sudo Bash functions; never run Arch maintenance or updates.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_case() {
    local label="$1" stack="$2" input="$3" expected="$4"
    local available="${5:-1}" failed_command="${6:-}" expected_warning="${7:-0}"
    local exit_choice update_choice output="$tmp/output" calls="$tmp/calls" status=0
    if [[ "$stack" == minecraft ]]; then
        exit_choice=9
        update_choice=6
    else
        exit_choice=8
        update_choice=5
    fi
    input="${input//@UPDATE@/$update_choice}"
    input="${input//@EXIT@/$exit_choice}"
    : > "$calls"
    printf '%b' "$input" | LOG_CAPTURE="$calls" TEST_STACK="$stack" \
        UPDATER_AVAILABLE="$available" FAIL_COMMAND="$failed_command" TERM=dumb \
        timeout 12 bash -c '
            source "$1"
            detect_stack() { printf "%s\n" "$TEST_STACK"; }
            hub_ensure_gum() { :; }
            hub_gum_interactive() { return 1; }
            show_header() { :; }
            # Match only the exact updater guard. All other [ ] uses
            # keep Bash built-in behavior, including tests elsewhere in Hub.
            function [() {
                if [[ "$#" -eq 4 && "$1" == "!" && "$2" == "-x" &&
                      "$3" == /usr/local/bin/crias-update && "$4" == "]" ]]; then
                    [[ "$UPDATER_AVAILABLE" != 1 ]]
                    return $?
                fi
                builtin [ "$@"
            }
            function /usr/local/bin/crias-update() {
                printf "direct:%s\n" "$*" >> "$LOG_CAPTURE"
                [[ "$FAIL_COMMAND" == "$1" ]] && return 44
                return 0
            }
            sudo() {
                printf "sudo:%s\n" "$*" >> "$LOG_CAPTURE"
                [[ "$FAIL_COMMAND" == "$2" ]] && return 44
                return 0
            }
            main
        ' _ "$root/crias-tui.sh" > "$output" 2>&1 || status=$?

    if [[ "$status" -ne 0 ]]; then
        tail -40 "$output" >&2
        fail "$label: Hub terminou com status $status"
    fi
    if [[ "$(cat "$calls")" != "$expected" ]]; then
        tail -40 "$output" >&2
        fail "$label: esperado [$expected], executado [$(cat "$calls")]"
    fi
    if [[ "$expected_warning" == 1 ]]; then
        grep -Fq 'Atualizador indisponivel' "$output" ||
            fail "$label: aviso de updater ausente nao apareceu"
    else
        ! grep -Fq 'Atualizador indisponivel' "$output" ||
            fail "$label: aviso falso de updater ausente"
    fi
    grep -Fq 'Crias-Server Hub encerrado.' "$output" ||
        fail "$label: nao voltou ao menu principal"
    printf 'OK: %s\n' "$label"
}

# Menu: release check=1, tools update=2, arch check=3, arch maintenance=4, back=5.
run_case "Minecraft release check" minecraft '@UPDATE@\n1\n\n@EXIT@\n' 'direct:check'
run_case "Minecraft release check error tolerated" minecraft '@UPDATE@\n1\n\n@EXIT@\n' 'direct:check' 1 check
run_case "Minecraft apply confirmed" minecraft '@UPDATE@\n2\n1\n\n@EXIT@\n' 'sudo:/usr/local/bin/crias-update apply'
run_case "Minecraft apply canceled" minecraft '@UPDATE@\n2\n2\n@EXIT@\n' ''
run_case "Minecraft apply confirmation EOF" minecraft '@UPDATE@\n2\n' ''
run_case "Minecraft arch check" minecraft '@UPDATE@\n3\n\n@EXIT@\n' 'direct:arch-check'
run_case "Minecraft arch maintenance confirmed" minecraft '@UPDATE@\n4\n1\n\n@EXIT@\n' 'sudo:/usr/local/bin/crias-update arch-apply'
run_case "Minecraft arch maintenance error tolerated" minecraft '@UPDATE@\n4\n1\n\n@EXIT@\n' 'sudo:/usr/local/bin/crias-update arch-apply' 1 arch-apply
run_case "Minecraft arch maintenance canceled" minecraft '@UPDATE@\n4\n2\n@EXIT@\n' ''
run_case "Minecraft arch maintenance confirmation EOF" minecraft '@UPDATE@\n4\n' ''
run_case "Minecraft back" minecraft '@UPDATE@\n5\n@EXIT@\n' ''
run_case "Minecraft invalid choice" minecraft '@UPDATE@\n0\n@EXIT@\n' ''
run_case "Minecraft update choice EOF" minecraft '@UPDATE@\n' ''
run_case "Minecraft updater unavailable" minecraft '@UPDATE@\n\n@EXIT@\n' '' 0 '' 1

run_case "Terraria release check" terraria '@UPDATE@\n1\n\n@EXIT@\n' 'direct:check'
run_case "Terraria apply confirmed" terraria '@UPDATE@\n2\n1\n\n@EXIT@\n' 'sudo:/usr/local/bin/crias-update apply'
run_case "Terraria apply canceled" terraria '@UPDATE@\n2\n2\n@EXIT@\n' ''
run_case "Terraria arch check" terraria '@UPDATE@\n3\n\n@EXIT@\n' 'direct:arch-check'
run_case "Terraria arch maintenance confirmed" terraria '@UPDATE@\n4\n1\n\n@EXIT@\n' 'sudo:/usr/local/bin/crias-update arch-apply'
run_case "Terraria arch maintenance canceled" terraria '@UPDATE@\n4\n2\n@EXIT@\n' ''
run_case "Terraria back" terraria '@UPDATE@\n5\n@EXIT@\n' ''
run_case "Terraria updater unavailable" terraria '@UPDATE@\n\n@EXIT@\n' '' 0 '' 1
# Adjacent menu: normal monitoring remains functional.
run_case "Minecraft adjacent monitoring" minecraft '5\n1\n@EXIT@\n' 'sudo:/usr/local/libexec/crias/mc-manager.sh monitor cpu'

echo 'OK: 23 update-menu navigation contracts, both stacks, no privileged side effects'
