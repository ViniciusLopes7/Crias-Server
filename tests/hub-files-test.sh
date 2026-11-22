#!/usr/bin/env bash
# Test that Hub file shortcuts open the right game directories, never as root.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/crias-hub-files-XXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
server="$tmp/server"
mkdir -p "$server/mods" "$server/config" "$server/backups" "$server/Reino dos Crias" "$tmp/bin"
printf 'level-name=Reino dos Crias\n' > "$server/server.properties"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/mc"
chmod +x "$tmp/bin/mc"
casefile="$tmp/check-pty.sh"
cat > "$casefile" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
server="$2"
capture="$3"
export PATH="$(dirname "$capture")/bin:$PATH"
source "$root/shared/lib/common.sh"
source "$root/shared/lib/manager-common.sh"
SERVER_DIR="$server"
SERVICE_NAME=minecraft
SERVER_USER="$(id -un)"
SELF="$root/minecraft/mc-manager.sh"
manager_need_root() { :; }
sudo() {
    # Assert command is delegated, not run by root in this test process.
    [ "$1" = "-u" ] && [ "$2" = "$SERVER_USER" ] && [ "$3" = "--" ] || exit 1
    printf '%s\n' "$*" >> "$capture"
}
for area in root mods config world backups; do
    cmd_files "$area"
done
if cmd_files unknown >/dev/null 2>&1; then
    echo "FAIL: selector desconhecido aceito" >&2
    exit 1
fi
# Even if there is a symlink from logs/ outside, it must not be traversed.
ln -s /etc "$server/logs"
if cmd_files logs >/dev/null 2>&1; then
    echo "FAIL: symlink de atalho para fora do servidor aceito" >&2
    exit 1
fi
EOF
chmod +x "$casefile"
if ! command -v script >/dev/null 2>&1; then
    echo "SKIP: util-linux script ausente; atalhos ainda cobertos pelo CI estatico" >&2
    exit 0
fi
# script allocates a real PTY to exercise the same TTY checks as SSH.
if ! script -q -e -c "bash '$casefile' '$root' '$server' '$tmp/capture'" /dev/null > "$tmp/output" 2>&1; then
    cat "$tmp/output" >&2
    echo "FAIL: erro ao navegar pelos atalhos de arquivos" >&2
    exit 1
fi
for expected in "$server" "$server/mods" "$server/config" "$server/Reino dos Crias" "$server/backups"; do
    grep -Fq " mc $expected" "$tmp/capture" || {
        echo "FAIL: mc nao abriu diretorio esperado: $expected" >&2
        cat "$tmp/capture" >&2
        exit 1
    }
done
test "$(wc -l < "$tmp/capture")" = 5 || { echo "FAIL: mc abriu areas nao solicitadas" >&2; exit 1; }
echo "OK: atalhos de arquivos por PTY, mundo personalizado, usuario do jogo e symlink bloqueado"
