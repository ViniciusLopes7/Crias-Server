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
cd "$ROOT_DIR"

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
run_test "archiso-profile-validate" "tests/archiso-profile-validate.sh"
run_test "iso-label-validate"       "tests/iso-label-validate.sh"
run_test "config-parser"            "tests/config-parser.sh"
run_test "config-parser-eq-test"    "tests/config-parser-eq-test.sh"
run_test "stack-installer-test"     "tests/stack-installer-test.sh"
run_test "agent-install-hook-test"  "tests/agent-install-hook-test.sh"
run_test "backup-dry-run"           "tests/backup-dry-run.sh"
run_test "terraria-backup-dry-run"  "tests/terraria-backup-dry-run.sh"
run_test "minecraft-tuning-test"    "tests/minecraft-tuning-test.sh"
run_test "terraria-tuning-test"     "tests/terraria-tuning-test.sh"
run_test "setup-cron-manager-test"  "tests/setup-cron-manager-test.sh"
run_test "qemu-log-parser-test"     "tests/qemu-log-parser-test.sh"

# Testes que requerem ISO construída (SKIP se ISO_PATH não definido).
run_test "iso-initramfs-validate"        "tests/iso-initramfs-validate.sh"        "true"
run_test "iso-live-credentials-validate" "tests/iso-live-credentials-validate.sh" "true"
run_test "iso-qemu-boot"                 "tests/iso-qemu-boot.sh"                 "true"

# Testes Python do discord-bot (se python3 + deps disponíveis).
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST: discord-bot pytest (Python)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v python3 >/dev/null 2>&1; then
    PY_BIN=""
    # Procura por python com discord.py + grpc_tools instalados.
    # Tenta versões específicas primeiro (mais comum ter deps em 3.13/3.12 via pip --user),
    # depois python3 genérico.
    for alt_py in python3.13 python3.12 python3.11 python3; do
        if command -v "$alt_py" >/dev/null 2>&1 && "$alt_py" -c "import discord, grpc_tools" 2>/dev/null; then
            PY_BIN="$alt_py"
            break
        fi
    done

    if [ -n "$PY_BIN" ]; then
        # Garante que código protobuf está gerado.
        if [ ! -f discord-bot/src/crias_bot/grpc_gen/crias_pb2.py ]; then
            echo "→ Gerando código protobuf Python..."
            "$PY_BIN" -m grpc_tools.protoc \
                -I discord-agent/proto \
                --python_out=discord-bot/src/crias_bot/grpc_gen \
                --grpc_python_out=discord-bot/src/crias_bot/grpc_gen \
                discord-agent/proto/crias.proto 2>/dev/null || true
            # Fix import path (protoc gera import absoluto; precisamos relativo ao pacote).
            sed -i 's/^import crias_pb2 as crias__pb2/from crias_bot.grpc_gen import crias_pb2 as crias__pb2/' \
                discord-bot/src/crias_bot/grpc_gen/crias_pb2_grpc.py 2>/dev/null || true
            touch discord-bot/src/crias_bot/grpc_gen/__init__.py
        fi

        # Determina site-packages dinamicamente via Python (sem hardcode de paths).
        PY_SITE="$("$PY_BIN" -c "import site; print(site.getusersitepackages())" 2>/dev/null || true)"

        if [ -n "$PY_SITE" ] && [ -d "$PY_SITE/discord" ]; then
            PY_ENV="PYTHONPATH=$PY_SITE:discord-bot/src"
        else
            PY_ENV="PYTHONPATH=discord-bot/src"
        fi

        pytest_log="$(mktemp /tmp/crias-pytest.XXXXXX.log)"
        if env "$PY_ENV" "$PY_BIN" -m pytest discord-bot/tests/ -v --tb=short > "$pytest_log" 2>&1; then
            echo "→ PASS"
            PASS=$((PASS + 1))
            tail -5 "$pytest_log"
        else
            echo "→ FAIL"
            tail -30 "$pytest_log"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("discord-bot pytest")
        fi
        rm -f "$pytest_log"
    else
        echo "→ SKIP (discord.py ou grpc_tools não instalados)"
        SKIP=$((SKIP + 1))
    fi
else
    echo "→ SKIP (python3 não disponível)"
    SKIP=$((SKIP + 1))
fi

# Resumo final.
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Resumo Final                                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║   PASS: %-3d                                              ║\n" "$PASS"
printf "║   FAIL: %-3d                                              ║\n" "$FAIL"
printf "║   SKIP: %-3d                                              ║\n" "$SKIP"
echo "╚══════════════════════════════════════════════════════════╝"

if [ "${#FAILED_TESTS[@]}" -gt 0 ]; then
    echo ""
    echo "Testes que falharam:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  ✗ $t"
    done
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
