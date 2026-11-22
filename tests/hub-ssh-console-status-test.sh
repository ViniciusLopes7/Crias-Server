#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/crias-hub-ssh-test-XXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

source "$root/shared/lib/manager-common.sh"
systemctl() {
    case "$*" in
        "show minecraft.service -p LoadState --value") echo loaded ;;
        "show minecraft.service -p ActiveState --value") echo active ;;
        "show minecraft.service -p MemoryCurrent --value") echo 2147483648 ;;
        "show minecraft.service -p NRestarts --value") echo 0 ;;
        *) return 1 ;;
    esac
}
manager_cmd_status minecraft > "$tmp/status"
grep -qx "Servidor: minecraft" "$tmp/status"
grep -qx "Estado: rodando" "$tmp/status"
grep -qx "RAM do servico: 2048 MiB" "$tmp/status"
test "$(wc -l < "$tmp/status")" -eq 3
! grep -qE "Hardware|sensors|CGroup|journal" "$tmp/status"
systemctl() {
    case "$*" in
        "show minecraft.service -p LoadState --value") echo loaded ;;
        "show minecraft.service -p ActiveState --value") echo failed ;;
        *) return 1 ;;
    esac
}
manager_cmd_status minecraft > "$tmp/stopped"
grep -q 'Estado: falhou' "$tmp/stopped"
! grep -q 'RAM do servico' "$tmp/stopped"
grep -Fq 'printf '\''%b\n'\'' "${GREEN}Crias-Server Hub encerrado.${NC}"' "$root/crias-tui.sh" || {
    echo "FAIL: saida nao usa printf %b" >&2; exit 1
}

# Actual Minecraft manager + injected RCON failure in SSH-like PTY, without
# opening a network connection or changing the Minecraft service.
if command -v script >/dev/null 2>&1; then
    cat > "$tmp/pty.sh" <<'PTY'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
capture="$2"
export CRIS_MANAGER_ALLOW_UNSAFE=1
systemctl() {
    case "$*" in
        "is-active --quiet minecraft") return 0 ;;
        "show minecraft.service -p LoadState --value") echo loaded ;;
        "show minecraft.service -p ActiveState --value") echo active ;;
        "show minecraft.service -p MemoryCurrent --value") echo 1048576 ;;
        "show minecraft.service -p NRestarts --value") echo 0 ;;
        *) return 1 ;;
    esac
}
source "$root/minecraft/mc-manager.sh" status >/dev/null
get_prop() {
    case "$1" in
        enable-rcon) echo true ;;
        rcon.password) echo test-token-not-for-logs ;;
        rcon.port) echo 25575 ;;
        *) echo "$2" ;;
    esac
}
mcrcon() {
    if [ "${1:-}" = "--help" ]; then echo "--no-tui"; return 0; fi
    printf 'FULLSCREEN_ATTEMPT\n' >> "$capture"
    return 27
}
timeout() {
    [ "${MCRCON_PASSWORD:-}" = "test-token-not-for-logs" ] || exit 81
    local command="${*: -1}"
    printf '%s\n' "$command" >> "$capture"
    case "$command" in
        "chunky start") return 42 ;;
        "chunky progress") echo "RCON_PROGRESSED"; return 0 ;;
        *) return 66 ;;
    esac
}
cmd_console || exit 71
echo "SSH_CONSOLE_RETURNED"
if cmd_console --tui; then exit 72; fi
echo "FULLSCREEN_ERROR_HANDLED"
PTY
    chmod +x "$tmp/pty.sh"
    printf 'chunky start\nchunky progress\nsair\n' |
        TERM=xterm-256color script -q -e \
            -c "bash '$tmp/pty.sh' '$root' '$tmp/capture'" /dev/null > "$tmp/output" 2>&1 || {
                cat "$tmp/output" >&2
                echo "FAIL: sessao SSH simulada caiu" >&2; exit 1
            }
    grep -q 'SSH_CONSOLE_RETURNED' "$tmp/output"
    grep -q 'FULLSCREEN_ERROR_HANDLED' "$tmp/output"
    grep -q 'RCON_PROGRESSED' "$tmp/output"
    test "$(grep -cx 'chunky start' "$tmp/capture")" -eq 1
    test "$(grep -cx 'chunky progress' "$tmp/capture")" -eq 1
    test "$(grep -cx 'FULLSCREEN_ATTEMPT' "$tmp/capture")" -eq 1
    ! grep -q 'test-token-not-for-logs' "$tmp/output"
fi
echo "OK: status compacto, saida ANSI e console RCON resiliente por SSH"
