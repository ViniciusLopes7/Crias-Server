#!/usr/bin/env bash
# tests/envsubst-test.sh
#
# Valida que o template .service pode ser processado por envsubst sem erros
# e produz a unit systemd esperada com variáveis substituídas corretamente.
#
# CR-03 (regressão): o teste ANTIGO exportava as variáveis antes do envsubst
# — exatamente o que o installer NÃO fazia (locals sem export). O bug
# (User=, ExecStart=/start-server.sh, MemoryMax=M) era mascarado. Agora o
# teste replica o padrão real do installer: valores via env do COMANDO,
# ambiente sem as variáveis.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v envsubst >/dev/null 2>&1; then
    echo "SKIP: envsubst não disponível neste ambiente (gettext não instalado)"
    exit 0
fi

# Garante ambiente LIMPO (sem as variáveis) — como num shell de instalação.
unset SERVER_USER SERVER_DIR MEMORY_MAX_MB SERVICE_NAME 2>/dev/null || true

# 1. Template do Minecraft — padrão do installer (env do comando, sem export).
# (AUDIT-B N3) MC_OUTPUT dedicado: OUTPUT e sobrescrito pela unit do Terraria
# mais abaixo — a validacao EXP-55 precisa do render do Minecraft preservado.
MC_OUTPUT=$(env SERVER_USER="minecraft" SERVER_DIR="/opt/minecraft-server" \
    MEMORY_MAX_MB="4096" SERVICE_NAME="minecraft" \
    envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
    < "$ROOT_DIR/minecraft/minecraft.service")
OUTPUT="$MC_OUTPUT"

if ! echo "$OUTPUT" | grep -q '^User=minecraft$'; then
    echo "FAIL: User não substituído no template do Minecraft"
    echo "$OUTPUT" | head -20
    exit 1
fi

if ! echo "$OUTPUT" | grep -q '^WorkingDirectory=/opt/minecraft-server$'; then
    echo "FAIL: WorkingDirectory não substituído no template do Minecraft"
    exit 1
fi

if ! echo "$OUTPUT" | grep -q '^MemoryMax=4096M$'; then
    echo "FAIL: MemoryMax não substituído no template do Minecraft"
    exit 1
fi

# Verifica que NÃO restaram placeholders __VAR__
if echo "$OUTPUT" | grep -q '__'; then
    echo "FAIL: Template do Minecraft contém placeholders não substituídos"
    echo "$OUTPUT"
    exit 1
fi


# (EXP-55) Helper: valida sintaxe de um unit .service com systemd-analyze,
# filtrando ruido de ambiente (units do sistema, paths inexistentes em CI).
verify_unit_syntax() {
    local unit_file="$1"
    local verify_log
    verify_log="$(mktemp /tmp/crias-systemd-analyze.XXXXXX.log)"
    systemd-analyze verify "$unit_file" > "$verify_log" 2>&1 || true
    local our_errors
    our_errors="$(grep -E "$(basename "$unit_file")" "$verify_log" 2>/dev/null \
        | grep -viE 'not executable|No such file|Command .* is not' \
        | grep -iE 'error|fail|invalid|unknown|syntax' || true)"
    if [ -n "$our_errors" ]; then
        echo "FAIL: systemd-analyze verify encontrou erros de sintaxe em $unit_file:" >&2
        echo "$our_errors" >&2
        rm -f "$verify_log"
        return 1
    fi
    rm -f "$verify_log"
    return 0
}

# 1b. Documentação viva do modo de falha (CR-03): envsubst SEM o env do
# comando produz campos vazios — prova empírica de por que o installer
# precisa do prefixo `env`.
BAD_OUTPUT=$(envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
    < "$ROOT_DIR/minecraft/minecraft.service" || true)
if ! echo "$BAD_OUTPUT" | grep -q '^User=$'; then
    echo "FAIL: controle do CR-03 — envsubst sem env-prefix deveria gerar User= vazio"
    exit 1
fi
if ! echo "$BAD_OUTPUT" | grep -q '^MemoryMax=M$'; then
    echo "FAIL: controle do CR-03 — envsubst sem env-prefix deveria gerar MemoryMax=M"
    exit 1
fi
echo "OK: controle negativo (sem env-prefix → campos vazios, como documentado no CR-03)"

# 2. Template do Terraria
OUTPUT=$(env SERVER_USER="terraria" SERVER_DIR="/opt/terraria-server" \
    MEMORY_MAX_MB="2048" SERVICE_NAME="terraria" \
    envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
    < "$ROOT_DIR/terraria/terraria.service")

if ! echo "$OUTPUT" | grep -q '^User=terraria$'; then
    echo "FAIL: User não substituído no template do Terraria"
    exit 1
fi

if ! echo "$OUTPUT" | grep -q '^MemoryMax=2048M$'; then
    echo "FAIL: MemoryMax não substituído no template do Terraria"
    exit 1
fi

# 3. O installer usa o padrão env-prefix (regressão estática).
if ! grep -q 'env SERVER_USER=' "$ROOT_DIR/shared/lib/stack-installer.sh"; then
    echo "FAIL: install_stack_service não usa env SERVER_USER=... envsubst (regressão CR-03)"
    exit 1
fi
echo "OK: install_stack_service usa env-prefix no envsubst"

# 4. Validação com systemd-analyze verify (se disponível).
# (EXP-55) Cada template em seu PROPRIO arquivo .service: antes a unit do
# Minecraft era renderizada, sobrescrita pela do Terraria e validada "sob o
# nome Minecraft" — a unit do Minecraft nunca passava pelo verify.
# O nome .service tambem e exigencia do systemd-analyze (CR-01).
if command -v systemd-analyze >/dev/null 2>&1; then
    MC_UNIT="/tmp/crias-minecraft-test.service"
    echo "$MC_OUTPUT" > "$MC_UNIT"
    verify_unit_syntax "$MC_UNIT" || exit 1
    echo "OK: systemd-analyze verify passou para a unit do Minecraft"

    TMP_UNIT="/tmp/crias-terraria-test.service"
    echo "$OUTPUT" > "$TMP_UNIT"
    verify_log="$(mktemp /tmp/crias-systemd-analyze.XXXXXX.log)"
    systemd-analyze verify "$TMP_UNIT" > "$verify_log" 2>&1 || true

    # Filtra: só linhas que mencionam NOSSO unit file E são erros de sintaxe.
    # Ignora erros de units do sistema (netplan, snapd) e paths inexistentes.
    our_errors="$(grep -E "$(basename "$TMP_UNIT")" "$verify_log" 2>/dev/null \
        | grep -viE 'not executable|No such file|Command .* is not' \
        | grep -iE 'error|fail|invalid|unknown|syntax' || true)"

    if [ -n "$our_errors" ]; then
        echo "FAIL: systemd-analyze verify encontrou erros de sintaxe em $TMP_UNIT:" >&2
        echo "$our_errors" >&2
        rm -f "$TMP_UNIT" "$verify_log"
        exit 1
    fi
    echo "OK: systemd-analyze verify passou (sem erros de sintaxe no nosso unit)"
    rm -f "$TMP_UNIT" "$verify_log"
fi

echo "OK: envsubst-test"
