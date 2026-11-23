#!/usr/bin/env bash
# Reproducible contract: a failed child test must fail run-all itself.
# Fixture is an isolated copy of run-all with minimal no-op child scripts.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/project"
mkdir -p "$fixture/tests" "$fixture/discord-bot/src" "$fixture/discord-bot/tests"
cp -- "$root/tests/run-all.sh" "$fixture/tests/run-all.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Collect the shell tests invoked directly by the local runner.
local_tests="$tmp/local-tests"
grep -E '^[[:space:]]*run_test[[:space:]]' "$root/tests/run-all.sh" |
    grep -oE '"tests/[A-Za-z0-9_-]+\.sh"' | tr -d '"' | sort -u > "$local_tests"
[ -s "$local_tests" ] || fail "nenhum teste Shell encontrado no run-all"

# A synthetic project with all children succeeding must return 0.
while IFS= read -r test_path; do
    mkdir -p "$fixture/$(dirname "$test_path")"
    printf '#!/bin/bash\nexit 0\n' > "$fixture/$test_path"
done < "$local_tests"

if ! bash "$fixture/tests/run-all.sh" > "$tmp/success.log" 2>&1; then
    tail -30 "$tmp/success.log" >&2
    fail "run-all rejeitou todos os testes de fixture com sucesso"
fi
grep -q 'RESULTADO: PASS=' "$tmp/success.log" ||
    fail "run-all nao imprime resumo final dos resultados"
grep -q 'FAIL=0' "$tmp/success.log" ||
    fail "resumo de sucesso nao reportou FAIL=0"

# Mutate exactly one child. The parent must report the failed name and exit 1.
printf '#!/bin/bash\nexit 41\n' > "$fixture/tests/static-audit.sh"
status=0
bash "$fixture/tests/run-all.sh" > "$tmp/failure.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "um teste falhou, mas run-all retornou 0"
grep -q 'RESULTADO: PASS=' "$tmp/failure.log" ||
    fail "falha nao mostra resumo dos resultados"
grep -q 'FAIL=1' "$tmp/failure.log" ||
    fail "falha nao foi contabilizada uma unica vez"
grep -q 'static-audit' "$tmp/failure.log" ||
    fail "nome do teste com falha nao foi apresentado"

# Prevent drift: any shell script directly executed in CI's test-shell job
# must also be listed in run-all. Other CI profiles (QEMU/Java/network) are
# intentionally separate and must not be pulled into the local runner blindly.
ci_tests="$tmp/ci-tests"
sed -n '/^  test-shell:/,/^  test-release-migration:/p' "$root/.github/workflows/ci.yml" |
    grep -E '^[[:space:]]+bash tests/[A-Za-z0-9_-]+\.sh[[:space:]]*$' |
    awk '{print $2}' | sort -u > "$ci_tests"
[ -s "$ci_tests" ] || fail "manifesto test-shell do CI nao identificado"
while IFS= read -r test_path; do
    if ! grep -Fxq "$test_path" "$local_tests"; then
        fail "CI executa $test_path mas tests/run-all.sh nao o inclui"
    fi
done < "$ci_tests"

printf 'OK: run-all devolve falhas ao processo, resume resultados e cobre a suite shell do CI\n'
