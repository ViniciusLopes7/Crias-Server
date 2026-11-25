#!/usr/bin/env bash
# C00: characterize service, backup and system routing before Go migration.
# Real numeric menu; no privileged commands, services, files or network touched.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
count=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_case() {
    local label="$1" stack="$2" input="$3" expected="$4"
    local fail_command="${5:-}" expected_status="${6:-0}"
    local manager exit_choice system_choice diag_choice status=0
    case "$stack" in
        minecraft) manager=/usr/local/libexec/crias/mc-manager.sh; exit_choice=9; system_choice=7; diag_choice=8 ;;
        terraria) manager=/usr/local/libexec/crias/tt-manager.sh; exit_choice=8; system_choice=6; diag_choice=7 ;;
        none) manager=none; exit_choice=0; system_choice=0; diag_choice=0 ;;
        *) fail "unknown stack fixture: $stack" ;;
    esac
    input="${input//@EXIT@/$exit_choice}"
    input="${input//@SYSTEM@/$system_choice}"
    input="${input//@DIAG@/$diag_choice}"
    expected="${expected//@MANAGER@/$manager}"
    : > "$tmp/actions"
    printf '%b' "$input" | TEST_STACK="$stack" LOG_CAPTURE="$tmp/actions" \
        FAIL_COMMAND="$fail_command" TERM=dumb timeout 12 bash -c '
            source "$1"
            detect_stack() {
                if [ "$TEST_STACK" != none ]; then printf "%s\n" "$TEST_STACK"; fi
            }
            hub_ensure_gum() { :; }
            hub_gum_interactive() { return 1; }
            show_header() { :; }
            show_diagnostics() { printf "%s\n" doctor >> "$LOG_CAPTURE"; }
            sudo() {
                printf "%s\n" "$*" >> "$LOG_CAPTURE"
                if [ "${2:-}" = "$FAIL_COMMAND" ]; then return 27; fi
                return 0
            }
            main
        ' _ "$root/crias-tui.sh" > "$tmp/output" 2>&1 || status=$?
    if [ "$status" -ne "$expected_status" ] || [ "$(cat "$tmp/actions")" != "$expected" ]; then
        tail -40 "$tmp/output" >&2
        fail "$label: status=$status expected=$expected_status; calls=[$(cat "$tmp/actions")] expected=[$expected]"
    fi
    if [ "$expected_status" -eq 0 ] && [ "$stack" != none ]; then
        grep -Fq 'Crias-Server Hub encerrado.' "$tmp/output" || fail "$label: no normal exit"
    fi
    count=$((count + 1))
    printf 'OK: %s\n' "$label"
}

run_case "MC status" minecraft '1\n1\n\n@EXIT@\n' '@MANAGER@ status'
run_case "MC status error returns" minecraft '1\n1\n\n@EXIT@\n' '@MANAGER@ status' status
run_case "MC start" minecraft '1\n6\n@EXIT@\n' '@MANAGER@ start'
run_case "MC stop" minecraft '1\n8\n@EXIT@\n' '@MANAGER@ stop'
run_case "MC restart" minecraft '1\n7\n@EXIT@\n' '@MANAGER@ restart'
# Known legacy behavior: unhandled start failure exits the Bash Hub.
# Document it, do not bless it as desired behavior of the future Go TUI.
run_case "MC start failure (legacy exit)" minecraft '1\n6\n@EXIT@\n' '@MANAGER@ start' start 27
run_case "MC stable console" minecraft '1\n2\n@EXIT@\n' '@MANAGER@ console'
run_case "MC stable console error returns" minecraft '1\n2\n\n@EXIT@\n' '@MANAGER@ console' console
run_case "MC fullscreen console" minecraft '1\n9\n@EXIT@\n' '@MANAGER@ console --tui'
run_case "MC console setup" minecraft '1\n11\n\n@EXIT@\n' '@MANAGER@ setup-console'
run_case "MC logs recent" minecraft '1\n4\n1\n\n@EXIT@\n' '@MANAGER@ logs recent'
run_case "MC logs alerts" minecraft '1\n4\n2\n\n@EXIT@\n' '@MANAGER@ logs alerts'
run_case "MC logs boot" minecraft '1\n4\n3\n\n@EXIT@\n' '@MANAGER@ logs boot'
run_case "MC logs follow" minecraft '1\n4\n4\n\n@EXIT@\n' '@MANAGER@ logs follow'
run_case "MC logs back" minecraft '1\n4\n5\n@EXIT@\n' ''
run_case "MC server back" minecraft '1\n12\n@EXIT@\n' ''
run_case "TT status" terraria '1\n1\n\n@EXIT@\n' '@MANAGER@ status'
run_case "TT start" terraria '1\n4\n@EXIT@\n' '@MANAGER@ start'
run_case "TT restart" terraria '1\n5\n@EXIT@\n' '@MANAGER@ restart'
run_case "TT stop" terraria '1\n6\n@EXIT@\n' '@MANAGER@ stop'
run_case "TT console (manager owns logs-only semantics)" terraria '1\n2\n@EXIT@\n' '@MANAGER@ console'
run_case "TT logs" terraria '1\n3\n@EXIT@\n' '@MANAGER@ logs'
run_case "TT server back" terraria '1\n7\n@EXIT@\n' ''

for stack in minecraft terraria; do
    run_case "$stack backup" "$stack" '2\n1\n@EXIT@\n' '@MANAGER@ backup'
    run_case "$stack schedule" "$stack" '2\n2\n@EXIT@\n' '@MANAGER@ setup-cron'
    run_case "$stack backup back" "$stack" '2\n3\n@EXIT@\n' ''
    run_case "$stack backup EOF" "$stack" '2\n' ''
    run_case "$stack tier auto" "$stack" '@SYSTEM@\n1\n1\n@EXIT@\n' '@MANAGER@ reconfigure-hardware'
    run_case "$stack tier LOW" "$stack" '@SYSTEM@\n1\n2\n@EXIT@\n' '@MANAGER@ reconfigure-hardware LOW'
    run_case "$stack tier MID" "$stack" '@SYSTEM@\n1\n3\n@EXIT@\n' '@MANAGER@ reconfigure-hardware MID'
    run_case "$stack tier HIGH" "$stack" '@SYSTEM@\n1\n4\n@EXIT@\n' '@MANAGER@ reconfigure-hardware HIGH'
    run_case "$stack tier back" "$stack" '@SYSTEM@\n1\n5\n@EXIT@\n' ''
    run_case "$stack health" "$stack" '@SYSTEM@\n2\n\n@EXIT@\n' '@MANAGER@ health'
    run_case "$stack hardware report" "$stack" '@SYSTEM@\n3\n\n@EXIT@\n' '@MANAGER@ hardware-report'
    run_case "$stack system back" "$stack" '@SYSTEM@\n4\n@EXIT@\n' ''
    run_case "$stack doctor" "$stack" '@DIAG@\n\n@EXIT@\n' 'doctor'
    run_case "$stack EOF at main" "$stack" '' ''
done
run_case "missing stack invokes doctor" none '' 'doctor'
printf 'OK: %s legacy Hub routing cases; all administrative calls intercepted\n' "$count"
