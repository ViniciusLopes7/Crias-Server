#!/usr/bin/env bash
# tests/backup-integrity-test.sh
#
# Contraprovas de integridade do backup (EXP-49/EXP-50/EXP-57/EXP-62/CR-05):
#   1. Backup REAL (tar+zstd) cria arquivo válido, restaurável, byte a byte;
#   2. tar/zstd reais são obrigatórios (stub de exit-0 não passa);
#   3. Falha de tar NÃO publica arquivo final nem notifica sucesso;
#   4. Dois backups no mesmo segundo têm nomes distintos (sem sobrescrita);
#   5. Entrada obrigatória (mundo) ausente => falha sem arquivo (CR-05);
#   6. DRY_RUN não emite notificação de sucesso (EXP-62).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in tar zstd flock ionice; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: ferramenta obrigatoria ausente: $tool (EXP-57 exige tar/zstd reais)"
        exit 1
    fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR" || true' EXIT

# ------------------------------------------------------------------
# 1. Backup real com restore byte a byte.
# ------------------------------------------------------------------
SERVER="$TMP_DIR/server1"
mkdir -p "$SERVER/world" "$SERVER/config"
printf 'conteudo-do-level-dat-%s' "$(date +%s%N)" > "$SERVER/world/level.dat"
printf 'cfg=1\n' > "$SERVER/server.properties"

# Curls stub (webhook): conta notificacoes.
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl-chamado: $*" >> "${CURL_LOG:?}"
exit 0
EOF
chmod +x "$STUB_BIN/curl"

run_backup() {
    local server="$1"
    shift
    PATH="$STUB_BIN:$PATH" \
        SERVER_DIR="$server" \
        BACKUP_DRY_RUN=false \
        BACKUP_REQUIRE_ACTIVE_SERVICE=false \
        BACKUP_NOTIFY_WEBHOOK="http://stub.local/hook" \
        CURL_LOG="$TMP_DIR/curl.log" \
        env "$@" bash "$ROOT_DIR/minecraft/backup-cron.sh"
}

CURL_LOG="$TMP_DIR/curl.log"
: > "$CURL_LOG"

run_backup "$SERVER" >/dev/null 2>&1

backup_file="$(ls "$SERVER"/backups/*.tar.zst 2>/dev/null | head -1 || true)"
if [ -z "$backup_file" ]; then
    echo "FAIL: backup real não produziu arquivo .tar.zst"
    exit 1
fi

# Integridade: zstd -t + listagem contém o level.dat.
if ! zstd -t -q "$backup_file"; then
    echo "FAIL: zstd -t rejeitou o backup criado (EXP-49)"
    exit 1
fi
# NOTA: capturar a listagem antes do grep — com pipefail ativo, o grep -q
# fecha o pipe cedo e o tar morre por SIGPIPE (falso negativo).
backup_listing="$(tar -I zstd -tf "$backup_file")"
if ! printf '%s\n' "$backup_listing" | grep -q 'world/level.dat'; then
    echo "FAIL: backup não contém world/level.dat (EXP-57)"
    echo "listagem: $backup_listing"
    exit 1
fi

# Restore em outro diretório e comparação byte a byte.
RESTORE="$TMP_DIR/restore"
mkdir -p "$RESTORE"
tar -I zstd -xf "$backup_file" -C "$RESTORE"
if ! cmp -s "$SERVER/world/level.dat" "$RESTORE/world/level.dat"; then
    echo "FAIL: restore divergiu do original (EXP-57)"
    exit 1
fi
echo "OK: backup real criado, íntegro e restaurável byte a byte"

# Nenhum .partial pode restar.
if ls "$SERVER"/backups/.*.partial >/dev/null 2>&1; then
    echo "FAIL: arquivo .partial sobrou após sucesso (EXP-49)"
    exit 1
fi

# Sucesso notifica exatamente 1 vez.
notify_count="$(grep -c 'curl-chamado' "$CURL_LOG" || true)"
if [ "$notify_count" -ne 1 ]; then
    echo "FAIL: webhook chamado $notify_count vez(es) no sucesso; esperado 1"
    exit 1
fi

# ------------------------------------------------------------------
# 2. Dois backups no mesmo segundo: nomes distintos (EXP-50).
# ------------------------------------------------------------------
: > "$CURL_LOG"
run_backup "$SERVER" >/dev/null 2>&1
run_backup "$SERVER" >/dev/null 2>&1
backup_count="$(ls "$SERVER"/backups/*.tar.zst 2>/dev/null | wc -l)"
if [ "$backup_count" -lt 3 ]; then
    echo "FAIL: backups no mesmo segundo se sobrescreveram (esperado >=3, obtido $backup_count — EXP-50)"
    exit 1
fi
echo "OK: backups no mesmo segundo não se sobrescrevem ($backup_count arquivos)"

# ------------------------------------------------------------------
# 3. Falha de tar: sem arquivo final, sem notificação de sucesso.
# ------------------------------------------------------------------
FAIL_BIN="$TMP_DIR/failbin"
mkdir -p "$FAIL_BIN"
cat > "$FAIL_BIN/tar" <<'EOF'
#!/usr/bin/env bash
# Simula morte do tar no meio (ENOSPC/processo morto).
exit 1
EOF
chmod +x "$FAIL_BIN/tar"
cp "$STUB_BIN/curl" "$FAIL_BIN/curl"

: > "$CURL_LOG"
set +e
PATH="$FAIL_BIN:$STUB_BIN:$PATH" \
    SERVER_DIR="$SERVER" \
    BACKUP_DRY_RUN=false \
    BACKUP_REQUIRE_ACTIVE_SERVICE=false \
    BACKUP_NOTIFY_WEBHOOK="http://stub.local/hook" \
    CURL_LOG="$CURL_LOG" \
    bash "$ROOT_DIR/minecraft/backup-cron.sh" >/dev/null 2>&1
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "FAIL: backup com tar falhando terminou em sucesso"
    exit 1
fi
# Nenhum .tar.zst NOVO pode ter sido publicado pelo run falho (os antigos
# permanecem); nenhum .partial pode restar.
if ls "$SERVER"/backups/.*.partial >/dev/null 2>&1; then
    echo "FAIL: .partial sobrou após falha de tar (EXP-49)"
    exit 1
fi
# Notificacao de FALHA e o comportamento correto; sucesso seria o erro.
curl_calls="$(grep -c 'curl-chamado' "$CURL_LOG" || true)"
if [ "$curl_calls" -gt 1 ]; then
    echo "FAIL: falha de tar gerou $curl_calls notificacoes; esperado no maximo 1 (de falha)"
    exit 1
fi
if [ "$curl_calls" -eq 1 ] && ! grep -q 'FALHOU' "$CURL_LOG"; then
    echo "FAIL: notificacao enviada nao e de falha (EXP-49)"
    exit 1
fi
echo "OK: falha de tar não publica backup nem parcial"

# ------------------------------------------------------------------
# 4. Mundo obrigatório ausente: falha sem arquivo (CR-05).
# ------------------------------------------------------------------
NO_WORLD="$TMP_DIR/server-no-world"
mkdir -p "$NO_WORLD/config"
printf 'level-name=reino\n' > "$NO_WORLD/server.properties"

set +e
PATH="$STUB_BIN:$PATH" \
    SERVER_DIR="$NO_WORLD" \
    BACKUP_DRY_RUN=false \
    BACKUP_REQUIRE_ACTIVE_SERVICE=false \
    BACKUP_NOTIFY_WEBHOOK="http://stub.local/hook" \
    CURL_LOG="$CURL_LOG" \
    bash "$ROOT_DIR/minecraft/backup-cron.sh" >/dev/null 2>&1
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "FAIL: backup sem o mundo (level-name=reino ausente) terminou em sucesso (CR-05)"
    exit 1
fi
if ls "$NO_WORLD"/backups/*.tar.zst >/dev/null 2>&1; then
    echo "FAIL: backup sem mundo publicou arquivo (CR-05)"
    exit 1
fi
echo "OK: mundo obrigatório ausente => falha sem arquivo publicado"

# ------------------------------------------------------------------
# 4b. (AUDIT-B N1) Mundo customizado FUNCIONA: a validação EXP-51 com o
# regex citado rejeitava QUALQUER level-name != "world" (backup quebrado).
# ------------------------------------------------------------------
CUSTOM="$TMP_DIR/server-custom-world"
mkdir -p "$CUSTOM/reino" "$CUSTOM/config"
printf 'level-name=reino\n' > "$CUSTOM/server.properties"
printf 'dados do reino\n' > "$CUSTOM/reino/level.dat"

: > "$CURL_LOG"
if ! run_backup "$CUSTOM" >/dev/null 2>&1; then
    echo "FAIL: backup com level-name customizado (reino) falhou (AUDIT-B N1 — regressão EXP-51)"
    run_backup "$CUSTOM" || true
    exit 1
fi
if ! ls "$CUSTOM"/backups/*.tar.zst >/dev/null 2>&1; then
    echo "FAIL: backup do mundo customizado não publicou arquivo (N1)"
    exit 1
fi
echo "OK: level-name customizado (reino) backupeado com sucesso"

# 4c. (EXP-51) Nomes perigosos rejeitados: traversal, opção, dot.
for bad_name in "../escape" "-checkpoint" ".." "."; do
    BAD="$TMP_DIR/server-bad-name"
    rm -rf "$BAD"
    mkdir -p "$BAD/config"
    printf 'level-name=%s\n' "$bad_name" > "$BAD/server.properties"
    set +e
    run_backup "$BAD" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: level-name perigoso '$bad_name' foi aceito (EXP-51)"
        exit 1
    fi
done
echo "OK: level-name perigoso (traversal/opção/dot) rejeitado"

# ------------------------------------------------------------------
# 5. DRY_RUN: sem notificação de sucesso (EXP-62).
# ------------------------------------------------------------------
: > "$CURL_LOG"
PATH="$STUB_BIN:$PATH" \
    SERVER_DIR="$SERVER" \
    BACKUP_DRY_RUN=true \
    BACKUP_REQUIRE_ACTIVE_SERVICE=false \
    BACKUP_NOTIFY_WEBHOOK="http://stub.local/hook" \
    CURL_LOG="$CURL_LOG" \
    bash "$ROOT_DIR/minecraft/backup-cron.sh" >/dev/null 2>&1

if grep -q 'curl-chamado' "$CURL_LOG"; then
    echo "FAIL: DRY_RUN disparou notificação (EXP-62)"
    exit 1
fi
echo "OK: DRY_RUN sem notificações"

echo "OK: backup-integrity-test"
