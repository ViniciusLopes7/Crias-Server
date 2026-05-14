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

echo "OK: setup-cron-manager-test"
