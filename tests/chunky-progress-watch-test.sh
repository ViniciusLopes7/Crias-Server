#!/usr/bin/env bash
# Exercise continuous Chunky progress polling under a pseudo-SSH terminal.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/crias-chunky-watch-XXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/mcrcon" <<'MCRCON'
#!/bin/bash
[ "${MCRCON_PASS:-}" = "mock-secret" ] || { echo "FAIL: no password env" >&2; exit 79; }
printf '%s\n' "$*" >> "$WATCH_LOG"
printf 'Chunky: processed 34%%; ETA 10min\n'
MCRCON
chmod +x "$tmp/mcrcon"
cat > "$tmp/pty.sh" <<'PTY'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
export CRIS_MANAGER_ALLOW_UNSAFE=1
systemctl() {
    case "$*" in
        "show minecraft.service -p LoadState --value") echo loaded ;;
        "show minecraft.service -p ActiveState --value") echo active ;;
        "show minecraft.service -p MemoryCurrent --value") echo 0 ;;
        "show minecraft.service -p NRestarts --value") echo 0 ;;
        "is-active --quiet minecraft")
            ticks=$(( ${ticks:-0} + 1 ))
            [ "$ticks" -le 2 ]
            ;;
        *) return 1 ;;
    esac
}
source "$root/minecraft/mc-manager.sh" status >/dev/null
get_prop() {
    case "$1" in
        enable-rcon) echo true ;;
        rcon.password) echo mock-secret ;;
        rcon.port) echo 25575 ;;
        *) echo "$2" ;;
    esac
}
sleep(){ :; }
cmd_chunky watch 1 >/dev/null 2>&1 && { echo "FAIL: unsafe frequency accepted"; exit 1; }
cmd_chunky watch 10 || { echo "FAIL: chunky watch failed"; exit 1; }
echo "CHUNKY_WATCH_RETURNED"
PTY
chmod +x "$tmp/pty.sh"
if command -v script >/dev/null 2>&1; then
    PATH="$tmp:$PATH" WATCH_LOG="$tmp/watch-log" TERM=xterm-256color \
        script -q -e -c "bash '$tmp/pty.sh' '$root'" /dev/null > "$tmp/out" 2>&1 || {
            cat "$tmp/out" >&2; exit 1
        }
    grep -q 'CHUNKY_WATCH_RETURNED' "$tmp/out"
    [ "$(wc -l < "$tmp/watch-log")" = 2 ] || {
        echo "FAIL: expected two read-only progress polls" >&2; exit 1
    }
    grep -q 'chunky progress' "$tmp/watch-log"
    ! grep -q 'mock-secret' "$tmp/out"
    echo "OK: Chunky automatic RCON polling in SSH PTY, bounded interval, no secrets"
fi
