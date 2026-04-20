#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SUCCESS_LOG="tests/fixtures/qemu-boot-success.log"
FAILURE_LOG="tests/fixtures/qemu-boot-failure.log"
TMP_LOG="$(mktemp /tmp/crias-ci-qemu-parser-XXXXXX.log)"
trap 'rm -f "$TMP_LOG"' EXIT

if [ ! -f "$SUCCESS_LOG" ] || [ ! -f "$FAILURE_LOG" ]; then
    echo "[qemu-log-parser-test] Fixtures de log nao encontrados." >&2
    exit 1
fi

echo "[qemu-log-parser-test] Validando fixture de sucesso..."
bash tests/iso-qemu-boot.sh --analyze-log "$SUCCESS_LOG"

echo "[qemu-log-parser-test] Validando fixture de falha..."
set +e
bash tests/iso-qemu-boot.sh --analyze-log "$FAILURE_LOG" > "$TMP_LOG" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
    echo "[qemu-log-parser-test] Parser aceitou um log de falha, regressao detectada." >&2
    cat "$TMP_LOG" >&2
    exit 1
fi

echo "[qemu-log-parser-test] OK"
