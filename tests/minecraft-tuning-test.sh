#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source shared/lib/common.sh
# shellcheck source=/dev/null
source shared/lib/hardware-profile.sh
# shellcheck source=/dev/null
source shared/lib/minecraft-tuning.sh

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "[minecraft-tuning-test] $message: expected=$expected actual=$actual" >&2
        exit 1
    fi
}

assert_match() {
    local value="$1"
    local pattern="$2"
    local message="$3"

    if ! [[ "$value" =~ $pattern ]]; then
        echo "[minecraft-tuning-test] $message: value=$value pattern=$pattern" >&2
        exit 1
    fi
}

compute_minecraft_tuning 4096 4 SSD MID
assert_match "$MC_MIN_RAM" '^[0-9]+M$' 'MC_MIN_RAM format'
assert_match "$MC_MAX_RAM" '^[0-9]+M$' 'MC_MAX_RAM format'
assert_match "$MC_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'MC_SERVICE_MEMORY_MAX_MB format'

min_mb=${MC_MIN_RAM%M}
max_mb=${MC_MAX_RAM%M}
service_mb=$MC_SERVICE_MEMORY_MAX_MB

if [ "$min_mb" -ge "$max_mb" ]; then
    echo "[minecraft-tuning-test] Expected Xms < Xmx, got $min_mb >= $max_mb" >&2
    exit 1
fi

if [ "$service_mb" -le "$max_mb" ]; then
    echo "[minecraft-tuning-test] Expected systemd memory cap to be above Xmx, got service=$service_mb xmx=$max_mb" >&2
    exit 1
fi

compute_minecraft_tuning 2048 2 HDD LOW
assert_match "$MC_MIN_RAM" '^[0-9]+M$' 'MC_MIN_RAM format low'
assert_match "$MC_MAX_RAM" '^[0-9]+M$' 'MC_MAX_RAM format low'
assert_match "$MC_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'MC_SERVICE_MEMORY_MAX_MB format low'

low_xmx=${MC_MAX_RAM%M}
low_xms=${MC_MIN_RAM%M}

if [ "$low_xms" -ge "$low_xmx" ]; then
    echo "[minecraft-tuning-test] Expected low-memory Xms < Xmx, got $low_xms >= $low_xmx" >&2
    exit 1
fi

compute_minecraft_tuning 1024 2 HDD LOW
assert_match "$MC_MIN_RAM" '^[0-9]+M$' 'MC_MIN_RAM format very low'
assert_match "$MC_MAX_RAM" '^[0-9]+M$' 'MC_MAX_RAM format very low'
assert_match "$MC_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'MC_SERVICE_MEMORY_MAX_MB format very low'

very_low_xmx=${MC_MAX_RAM%M}
very_low_xms=${MC_MIN_RAM%M}

if [ "$very_low_xms" -ge "$very_low_xmx" ]; then
    echo "[minecraft-tuning-test] Expected very-low-memory Xms < Xmx, got $very_low_xms >= $very_low_xmx" >&2
    exit 1
fi

if [ "$MC_SERVICE_MEMORY_MAX_MB" -lt "$very_low_xmx" ]; then
    echo "[minecraft-tuning-test] Expected systemd cap to stay at or above Xmx, got service=$MC_SERVICE_MEMORY_MAX_MB xmx=$very_low_xmx" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# CR-09: write_minecraft_server_properties faz MERGE — chaves do admin
# (enable-rcon, rcon.password, level-name, whitelist, comentarios) devem
# sobreviver a uma reescrita; chaves gerenciadas sao atualizadas.
# ---------------------------------------------------------------------------
merge_tmp="$(mktemp -d)"
trap 'rm -rf -- "$merge_tmp" || true' EXIT
props="$merge_tmp/server.properties"

cat > "$props" <<'EOF'
# config do admin — nao mexer
enable-rcon=true
rcon.password=segredo-do-admin
rcon.port=25575
level-name=reino-dos-crias
white-list=true
motd=MOTD antigo do admin
max-players=10
EOF

compute_minecraft_tuning 4096 4 SSD MID
write_minecraft_server_properties "$props" "25565" "true" "MOTD novo do Crias"

# Chaves do admin preservadas (o bug antigo truncava o arquivo inteiro).
for admin_key in "enable-rcon=true" "rcon.password=segredo-do-admin" \
    "rcon.port=25575" "level-name=reino-dos-crias" "white-list=true" \
    "# config do admin — nao mexer"; do
    if ! grep -qF "$admin_key" "$props"; then
        echo "[minecraft-tuning-test] FAIL CR-09: chave do admin perdida no merge: $admin_key" >&2
        cat "$props" >&2
        exit 1
    fi
done

# Chaves gerenciadas atualizadas (ultima ocorrencia vence — a nova).
if ! grep -q '^motd=MOTD novo do Crias$' "$props"; then
    echo "[minecraft-tuning-test] FAIL CR-09: motd gerenciado nao atualizado" >&2
    exit 1
fi
if ! grep -q '^server-port=25565$' "$props"; then
    echo "[minecraft-tuning-test] FAIL CR-09: server-port ausente" >&2
    exit 1
fi

# O MOTD antigo (gerenciado) nao pode prevalecer: jogo le a ULTIMA ocorrencia.
motd_count=$(grep -c '^motd=' "$props" || true)
if [ "$motd_count" -ne 1 ]; then
    echo "[minecraft-tuning-test] FAIL CR-09: esperado 1 motd, encontrado $motd_count" >&2
    exit 1
fi

# Backup do estado pre-merge criado.
if [ ! -f "$props.crias-bak" ]; then
    echo "[minecraft-tuning-test] FAIL CR-09: backup .crias-bak nao criado" >&2
    exit 1
fi

# Reescrita em arquivo NOVO: comportamento classico (sem merge).
props2="$merge_tmp/server2.properties"
write_minecraft_server_properties "$props2" "25566" "false" "MOTD 2"
if ! grep -q '^server-port=25566$' "$props2"; then
    echo "[minecraft-tuning-test] FAIL: arquivo novo sem server-port" >&2
    exit 1
fi
if [ -f "$props2.crias-bak" ]; then
    echo "[minecraft-tuning-test] FAIL: .crias-bak criado para arquivo novo" >&2
    exit 1
fi

echo "[minecraft-tuning-test] OK (inclui contrato de merge CR-09)"