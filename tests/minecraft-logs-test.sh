#!/bin/bash
# Contraprovas para visoes de logs do Minecraft e preservacao de evidencias.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/server"

cat > "$tmp/bin/journalctl" <<'STUB'
#!/bin/bash
printf "%s\n" "$*" >> "$JOURNAL_TEST_ARGS"
if [ "${JOURNAL_TEST_FAIL:-0}" = 1 ]; then
    echo "falha simulada de acesso ao journal" >&2
    exit 3
fi
echo "2026-11-20T06:00:00-0300 mc[100]: INFO Inicio regular"
echo "2026-11-20T06:00:01-0300 mc[100]: [main/WARN] Config Forge ajustada"
echo "2026-11-20T06:00:02-0300 mc[100]: [main/ERROR] Falha simulada"
STUB
chmod +x "$tmp/bin/journalctl"
: > "$tmp/args"

invoke() {
    CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$tmp/server" \
        JOURNAL_TEST_ARGS="$tmp/args" PATH="$tmp/bin:$PATH" \
        bash "$root/minecraft/mc-manager.sh" logs "$@"
}

recent="$(invoke recent)"
grep -q "Inicio regular" <<< "$recent"
grep -q -- "--no-pager -o short-iso" "$tmp/args"

boot="$(invoke boot)"
grep -q "Inicio regular" <<< "$boot"
grep -q -- "-b -n 200 --no-pager -o short-iso" "$tmp/args"

alerts="$(invoke alerts)"
grep -q "Config Forge ajustada" <<< "$alerts"
grep -q "Falha simulada" <<< "$alerts"
if grep -q "INFO Inicio regular" <<< "$alerts"; then
    echo "FAIL: filtro alerts exibiu INFO" >&2; exit 1
fi

follow="$(invoke follow)"
grep -q "Inicio regular" <<< "$follow"
grep -q -- "-n 80 -f -o short-iso" "$tmp/args"

if invoke argumento-invalido > "$tmp/invalid.out" 2>&1; then
    echo "FAIL: opcao de log invalida foi aceita" >&2; exit 1
fi
grep -q "Uso: logs" "$tmp/invalid.out"

if JOURNAL_TEST_FAIL=1 invoke alerts > "$tmp/error.out" 2>&1; then
    echo "FAIL: falha do journalctl foi mascarada" >&2; exit 1
fi

# A VM precisa manter os logs completos, sem apenas o resumo filtrado.
grep -Fq "minecraft-logs.tar.gz" "$root/tests/qemu/run-vm.sh"
grep -Fq "summary.tsv" "$root/tests/qemu/guest-test.sh"
echo "OK: logs Minecraft (follow/recent/boot/alerts), erros propagados e artefatos QEMU preservados"
