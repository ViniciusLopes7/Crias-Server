#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source shared/lib/common.sh
# shellcheck source=/dev/null
source shared/lib/hardware-profile.sh
# shellcheck source=/dev/null
source shared/lib/terraria-tuning.sh

assert_match() {
    local value="$1"
    local pattern="$2"
    local message="$3"

    if ! [[ "$value" =~ $pattern ]]; then
        echo "[terraria-tuning-test] $message: value=$value pattern=$pattern" >&2
        exit 1
    fi
}

compute_terraria_tuning 4096 4 SSD MID
assert_match "$TT_MAX_PLAYERS" '^[0-9]+$' 'TT_MAX_PLAYERS format'
assert_match "$TT_NPC_STREAM" '^[0-9]+$' 'TT_NPC_STREAM format'
assert_match "$TT_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'TT_SERVICE_MEMORY_MAX_MB format'

if [ "$TT_SERVICE_MEMORY_MAX_MB" -lt 1024 ] || [ "$TT_SERVICE_MEMORY_MAX_MB" -gt 8192 ]; then
    echo "[terraria-tuning-test] TT_SERVICE_MEMORY_MAX_MB fora do range esperado: $TT_SERVICE_MEMORY_MAX_MB" >&2
    exit 1
fi

compute_terraria_tuning 2048 2 HDD HIGH
assert_match "$TT_MAX_PLAYERS" '^[0-9]+$' 'TT_MAX_PLAYERS format high'
assert_match "$TT_BACKUP_ZSTD_LEVEL" '^-?[0-9]+$' 'TT_BACKUP_ZSTD_LEVEL format'

if [ "$TT_MAX_PLAYERS" -gt 12 ]; then
    echo "[terraria-tuning-test] Esperado TT_MAX_PLAYERS <= 12 para cpu_cores <= 2, obtido $TT_MAX_PLAYERS" >&2
    exit 1
fi

if [ "$TT_BACKUP_ZSTD_LEVEL" != "-3" ]; then
    echo "[terraria-tuning-test] Esperado BACKUP_ZSTD_LEVEL=-3 para HDD, obtido $TT_BACKUP_ZSTD_LEVEL" >&2
    exit 1
fi

compute_terraria_tuning 1024 2 HDD LOW
assert_match "$TT_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'TT_SERVICE_MEMORY_MAX_MB format low'

if [ "$TT_SERVICE_MEMORY_MAX_MB" -lt 1024 ]; then
    echo "[terraria-tuning-test] Esperado TT_SERVICE_MEMORY_MAX_MB >= 1024, obtido $TT_SERVICE_MEMORY_MAX_MB" >&2
    exit 1
fi

echo "[terraria-tuning-test] OK"

# ------------------------------------------------------------------
# (CR-03) Contraprova: reconfigure-hardware NAO apaga a senha nem chaves
# do operador no serverconfig.txt (merge seletivo + .crias-bak).
# ------------------------------------------------------------------
TT_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TT_TMP_DIR" || true' EXIT
TT_CFG="$TT_TMP_DIR/serverconfig.txt"

# Estado pre-existente com senha e chave customizada do operador.
cat > "$TT_CFG" <<'EOF'
worldpath=/opt/terraria-server/worlds
worldname=reino
password=segredo-do-admin
maxplayers=20
banlist=banlist.txt
EOF

write_terraria_server_config "$TT_CFG" "/nova/worlds" "7777" "novo motd" "reino"

# Senha PRESERVADA (o bug antigo reescrevia password= vazio).
if ! grep -q '^password=segredo-do-admin$' "$TT_CFG"; then
    echo "FAIL: CR-03 — reconfigure apagou a senha do serverconfig.txt" >&2
    cat "$TT_CFG" >&2
    exit 1
fi
# Chave do operador PRESERVADA.
if ! grep -q '^banlist=banlist.txt$' "$TT_CFG"; then
    echo "FAIL: CR-03 — chave customizada (banlist) foi descartada" >&2
    exit 1
fi
# Chaves gerenciadas ATUALIZADAS (ultima ocorrencia prevalece).
if ! grep -q '^worldpath=/nova/worlds$' "$TT_CFG"; then
    echo "FAIL: CR-03 — worldpath gerenciado nao atualizado" >&2
    exit 1
fi
# Backup pre-merge gerado.
if [ ! -f "$TT_CFG.crias-bak" ]; then
    echo "FAIL: CR-03 — .crias-bak nao criado antes do merge" >&2
    exit 1
fi
echo "OK: CR-03 — senha e chaves do operador preservadas no reconfigure"
