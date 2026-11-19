#!/usr/bin/env bash
# tests/backup-saveon-success-test.sh
#
# CR-02 (contrato): num backup BEM-SUCEDIDO (tar OK), save-on deve ser
# executado EXATAMENTE UMA vez (ativacao explicita no sucesso + EXIT trap
# no-op via guard RCON_SAVE_LOCK_ACTIVE). O bug original: o caminho de
# sucesso limpava o trap sem chamar o post-hook — servidor ficava com
# save-off apos backup OK.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/minecraft/backup-cron.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir" || true' EXIT
server_dir="$tmp_dir/server"
mkdir -p "$server_dir/world" "$server_dir/mods" "$server_dir/config"

cat > "$server_dir/server.properties" <<'EOF'
enable-rcon=true
rcon.password=test-pass
rcon.port=25575
level-name=world
EOF

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

# mcrcon stub: tudo funciona (save-off, save-all, save-on OK).
MCRCON_LOG="$tmp_dir/mcrcon.log"
cat > "$stub_bin/mcrcon" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "mcrcon:\$*" >> "$MCRCON_LOG"
exit 0
EOF
chmod +x "$stub_bin/mcrcon"

# (EXP-57) tar/zstd/flock/ionice REAIS: o caminho novo valida o archive
# (.partial -> zstd -t -> tar -tf -> mv). O stub antigo (exit 0 sem criar
# arquivo) fazia qualquer tar "bem-sucedido" — justamente o falso positivo
# que o teste de contrato precisa impedir: um tar que nao produz arquivo
# NAO pode terminar em sucesso.
for tool in tar zstd flock ionice; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: ferramenta obrigatoria ausente no PATH: $tool (o teste exige tar/zstd/flock/ionice reais — EXP-57)"
        exit 1
    fi
done

# Executa o backup com tudo funcionando.
PATH="$stub_bin:$PATH" \
    SERVER_DIR="$server_dir" \
    BACKUP_DRY_RUN=false \
    BACKUP_REQUIRE_ACTIVE_SERVICE=false \
    bash "$SCRIPT" >/dev/null 2>&1

# save-off e save-all devem ter sido chamados.
if ! grep -q "save-off" "$MCRCON_LOG"; then
    echo "FAIL: save-off nao foi chamado"
    cat "$MCRCON_LOG"
    exit 1
fi
if ! grep -q "save-all" "$MCRCON_LOG"; then
    echo "FAIL: save-all nao foi chamado"
    exit 1
fi

# CONTRATO CR-02: save-on executado EXATAMENTE UMA vez no sucesso.
saveon_count=$(grep -c "save-on" "$MCRCON_LOG" || true)
if [ "$saveon_count" -ne 1 ]; then
    echo "FAIL: save-on executado $saveon_count vez(es); esperado exatamente 1 (CR-02)"
    echo "  mcrcon log:"
    cat "$MCRCON_LOG"
    exit 1
fi

echo "OK: backup-saveon-success (save-on exatamente 1x apos backup bem-sucedido)"
