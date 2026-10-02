#!/bin/bash
# tests/run-all.sh
#
# Roda toda a bateria de testes do Crias-Server e reporta resultados.
# Uso: bash tests/run-all.sh
#
# Este script roda:
#   - Testes bash que não precisam de ISO real
#   - Testes de sintaxe Python
#   - Sintaxe de todos os .sh
# Testes que precisam de ISO real (iso-initramfs-validate.sh, etc.) são
# listados como SKIP porque exigem uma ISO construída primeiro.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

run_test() {
    local name="$1"
    local script="$2"
    local requires_iso="${3:-false}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$requires_iso" = "true" ] && [ -z "${ISO_PATH:-}" ]; then
        echo "→ SKIP (requer ISO real; defina ISO_PATH=/path/to/crias.iso)"
        SKIP=$((SKIP + 1))
        return 0
    fi

    # Log único por teste (evita race se run-all.sh rodar em paralelo).
    local test_log
    test_log="$(mktemp /tmp/crias-test-output.XXXXXX.log)"

    if bash "$script" > "$test_log" 2>&1; then
        echo "→ PASS"
        PASS=$((PASS + 1))
    else
        echo "→ FAIL"
        echo "--- output (últimas 20 linhas):"
        tail -20 "$test_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
    rm -f "$test_log"
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Crias-Server — Bateria Completa de Testes              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Data: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Repo: $ROOT_DIR"

# Sintaxe bash de TODOS os scripts.
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Sintaxe bash de TODOS os scripts.
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST: bash -n em todos os .sh do repo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash_errors=0
while IFS= read -r script; do
    if ! bash -n "$script" 2>/tmp/syntax-err.log; then
        echo "→ FAIL: $script"
        cat /tmp/syntax-err.log
        bash_errors=$((bash_errors + 1))
        FAILED_TESTS+=("bash -n: $script")
    fi
done < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './node_modules/*' | sort)

if [ "$bash_errors" -eq 0 ]; then
    echo "→ PASS (todos os .sh têm sintaxe válida)"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

# Sintaxe Python (se python3 disponível).
if command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: python -m py_compile em todos os .py do bot"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    py_errors=0
    while IFS= read -r py; do
        # Passa filename como argv (evita injeção via path com aspas).
        if ! python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$py" 2>/tmp/py-err.log; then
            echo "→ FAIL: $py"
            cat /tmp/py-err.log
            py_errors=$((py_errors + 1))
            FAILED_TESTS+=("python ast: $py")
        fi
    done < <(find discord-bot -type f -name '*.py' -not -path '*/__pycache__/*' 2>/dev/null | sort)

    if [ "$py_errors" -eq 0 ]; then
        echo "→ PASS (todos os .py têm sintaxe válida)"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
fi

# YAML validation (se python yaml disponível).
if python3 -c "import yaml" 2>/dev/null; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: yaml.safe_load em todos os .yaml/.yml do repo"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    yaml_errors=0
    while IFS= read -r yml; do
        if ! python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$yml" 2>/tmp/yaml-err.log; then
            echo "→ FAIL: $yml"
            cat /tmp/yaml-err.log
            yaml_errors=$((yaml_errors + 1))
            FAILED_TESTS+=("yaml: $yml")
        fi
    done < <(find . -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path './.git/*' 2>/dev/null | sort)
    if [ "$yaml_errors" -eq 0 ]; then
        echo "→ PASS (todos os YAMLs têm sintaxe válida)"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
fi

# JSON validation (se python disponível).
if command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: json.loads em todos os .json do repo"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    json_errors=0
    while IFS= read -r j; do
        if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$j" 2>/tmp/json-err.log; then
            echo "→ FAIL: $j"
            cat /tmp/json-err.log
            json_errors=$((json_errors + 1))
            FAILED_TESTS+=("json: $j")
        fi
    done < <(find . -type f -name '*.json' -not -path './.git/*' -not -path '*/node_modules/*' 2>/dev/null | sort)
    if [ "$json_errors" -eq 0 ]; then
        echo "→ PASS (todos os JSONs têm sintaxe válida)"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
fi

# Testes que rodam sem ISO.
run_test "quick-script-tests"       "tests/quick-script-tests.sh"
run_test "install-contracts"        "tests/install-contracts.sh"
run_test "static-audit"             "tests/static-audit.sh"
run_test "arch-smoke"               "tests/arch-smoke.sh"
run_test "arch-dry-install"         "tests/arch-dry-install.sh"
run_test "crias-bootstrap-test"          "tests/crias-bootstrap-test.sh"
run_test "config-parser"            "tests/config-parser.sh"
run_test "config-parser-eq-test"    "tests/config-parser-eq-test.sh"
run_test "stack-installer-test"     "tests/stack-installer-test.sh"
run_test "agent-install-hook-test"  "tests/agent-install-hook-test.sh"
run_test "install-ssh-hook-test"    "tests/install-ssh-hook-test.sh"
run_test "install-monitor-hook-test" "tests/install-monitor-hook-test.sh"
run_test "backup-dry-run"           "tests/backup-dry-run.sh"
run_test "terraria-backup-dry-run"  "tests/terraria-backup-dry-run.sh"
run_test "minecraft-tuning-test"    "tests/minecraft-tuning-test.sh"
run_test "terraria-tuning-test"     "tests/terraria-tuning-test.sh"
run_test "setup-cron-manager-test"  "tests/setup-cron-manager-test.sh"
run_test "tui-fallback-test"        "tests/tui-fallback-test.sh"
run_test "mc-manifests-test"        "tests/mc-manifests-test.sh"
run_test "tmodloader-test"           "tests/tmodloader-test.sh"
run_test "mutation-test"            "tests/mutation-test.sh"

