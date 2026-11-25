#!/usr/bin/env bash
# C00: characterize actual shared backend return codes and capability failures.
# No real systemctl, sudo, package installation or game process.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=/dev/null
source "$root/shared/lib/manager-common.sh"
SERVICE_NAME=minecraft
SERVER_USER=fixture
SERVER_DIR="$tmp/server"
SELF="$root/minecraft/mc-manager.sh"
BACKUP_SCRIPT="$tmp/missing-backup"
TUNING_STATE="$tmp/missing-tuning"
LOAD=loaded
ACTIVE=active
MEM=2097152
RESTARTS=0
SYSTEMCTL_RC=0
count=0
err() { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }
manager_need_root() { printf 'elevation\n' >> "$tmp/writes"; }
manager_run_as_server_user() { printf 'run-as\n' >> "$tmp/writes"; return 96; }
sudo() { printf 'sudo\n' >> "$tmp/writes"; return 97; }
systemctl() {
    case "$*" in
        "show $SERVICE_NAME.service -p LoadState --value") printf '%s\n' "$LOAD" ;;
        "show $SERVICE_NAME.service -p ActiveState --value") printf '%s\n' "$ACTIVE" ;;
        "show $SERVICE_NAME.service -p MemoryCurrent --value") printf '%s\n' "$MEM" ;;
        "show $SERVICE_NAME.service -p NRestarts --value") printf '%s\n' "$RESTARTS" ;;
        "start $SERVICE_NAME"|"stop $SERVICE_NAME"|"restart $SERVICE_NAME")
            printf '%s\n' "$*" >> "$tmp/systemctl"; return "$SYSTEMCTL_RC" ;;
        *) return 88 ;;
    esac
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() {
    local expected="$1" label="$2" rc=0
    shift 2
    # Isolate even dispatch branches that call exit.
    ( "$@" ) > "$tmp/output" 2>&1 || rc=$?
    [ "$rc" -eq "$expected" ] || { cat "$tmp/output" >&2; fail "$label: rc=$rc expected=$expected"; }
    count=$((count + 1))
    printf 'OK: %s (rc=%s)\n' "$label" "$rc"
}
has() { grep -Fq -- "$1" "$tmp/output" || fail "missing output: $1"; }
lacks() { if grep -Fq -- "$1" "$tmp/output"; then fail "unexpected output: $1"; fi; }

for SERVICE_NAME in minecraft terraria; do
    LOAD=not-found
    expect 1 "$SERVICE_NAME absent unit" manager_dispatch status
    has 'nao instalado/encontrado'
    LOAD=''
    expect 1 "$SERVICE_NAME unavailable LoadState" manager_dispatch status
    LOAD=loaded
    for state in inactive failed activating deactivating unknown; do
        ACTIVE="$state"
        expect 0 "$SERVICE_NAME status $state is not readiness" manager_dispatch status
        lacks 'RAM do servico:'
        case "$state" in
            inactive) has 'Estado: parado' ;;
            failed) has 'Estado: falhou' ;;
            activating) has 'Estado: iniciando' ;;
            deactivating) has 'Estado: parando' ;;
            unknown) has 'Estado: desconhecido' ;;
        esac
    done
    ACTIVE=active
    MEM=invalid
    RESTARTS=invalid
    expect 0 "$SERVICE_NAME unavailable resource metrics" manager_dispatch status
    lacks 'RAM do servico:'
    lacks 'Reinicios automaticos:'
    MEM=0
    RESTARTS=2
    expect 0 "$SERVICE_NAME real zero and restart count" manager_dispatch status
    has 'RAM do servico: 0 MiB'
    has 'Reinicios automaticos: 2'
    SYSTEMCTL_RC=43
    for action in start stop restart; do
        : > "$tmp/systemctl"
        expect 43 "$SERVICE_NAME $action propagates failure" manager_dispatch "$action"
        [ "$(cat "$tmp/systemctl")" = "$action $SERVICE_NAME" ] || fail "wrong target or retry"
    done
    expect 1 "$SERVICE_NAME missing backup" manager_dispatch backup
    has 'Script de backup nao encontrado'
    expect 0 "$SERVICE_NAME missing tuning is warning" manager_dispatch hardware-report
    has 'Arquivo de estado nao encontrado'
    expect 2 "$SERVICE_NAME excessive files arguments" manager_dispatch files root logs
    expect 2 "$SERVICE_NAME excessive setup-files arguments" manager_dispatch setup-files extra
    expect 1 "$SERVICE_NAME invalid monitoring kind" manager_dispatch monitor invalid
    expect 1 "$SERVICE_NAME unknown command" manager_dispatch definitely-unknown
done

# Shared dispatcher with no optional stack-specific implementations.
SERVICE_NAME=terraria
for action in chunky memory voicechat; do
    expect 2 "unsupported optional operation $action" manager_dispatch "$action"
    has 'neste stack'
done
[ ! -e "$tmp/writes" ] || fail "a rejected/read-only operation crossed the write boundary"
printf 'OK: %s shared backend contract cases; no real administrative writes\n' "$count"
