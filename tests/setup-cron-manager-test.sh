#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! grep -Fq "manager_need_root \"\$SELF\" \"setup-cron\" \"\$@\"" minecraft/mc-manager.sh; then
    echo "FAIL: minecraft/mc-manager.sh nao preserva subcomando setup-cron no sudo reexec"
    exit 1
fi

if ! grep -Fq "manager_need_root \"\$SELF\" \"setup-cron\" \"\$@\"" terraria/tt-manager.sh; then
    echo "FAIL: terraria/tt-manager.sh nao preserva subcomando setup-cron no sudo reexec"
    exit 1
fi

# Regressão NUL (v1.2.1): o padrão *$'\0'* expande para ** (casa com TUDO) e
# fazia validate_setup_cron_inputs rejeitar QUALQUER path não-vazio (o
# setup-cron de backup quebrava com qualquer config). Valida inputs reais +
# rejeição de metachars continua intacta.
_validate_unit() {
    cd "$ROOT_DIR" || return 1
    bash -c '
        set -uo pipefail
        source shared/lib/common.sh
        source shared/lib/setup-cron.sh
        SETUP_CRON_USER="minecraft"
        SETUP_CRON_SERVER_DIR="/opt/minecraft-server"
        SETUP_CRON_BACKUP_SCRIPT="/opt/minecraft-server/backup.sh"
        SETUP_CRON_BACKUP_SERVICE="/etc/systemd/system/crias-mc-backup.service"
        SETUP_CRON_BACKUP_TIMER="/etc/systemd/system/crias-mc-backup.timer"
        validate_setup_cron_inputs
    ' >/dev/null 2>&1
}

if _validate_unit; then
    echo "OK: validate_setup_cron_inputs aceita paths reais (regressao NUL)"
else
    echo "FAIL: validate_setup_cron_inputs rejeitou paths validos (regressao NUL)"
    exit 1
fi

if bash -c '
        set -uo pipefail
        cd "'"$ROOT_DIR"'"
        source shared/lib/common.sh
        source shared/lib/setup-cron.sh
        SETUP_CRON_USER="minecraft"
        SETUP_CRON_SERVER_DIR="/opt/x; rm -rf /"
        validate_setup_cron_inputs
    ' >/dev/null 2>&1; then
    echo "FAIL: validate_setup_cron_inputs aceitou metachar no path"
    exit 1
else
    echo "OK: validate_setup_cron_inputs rejeita metachars"
fi

echo "OK: setup-cron-manager-test"
