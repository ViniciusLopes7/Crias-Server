#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/minecraft/backup-cron.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir" || true' EXIT
server_dir="$tmp_dir/server"
mkdir -p "$server_dir/world" "$server_dir/world_nether" "$server_dir/world_the_end"

cat > "$server_dir/server.properties" <<'EOF'
enable-rcon=true
rcon.password=test-pass
rcon.port=25575
EOF

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/mcrcon" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "mcrcon:$*" >> "${MCRCON_LOG_FILE:?}"
EOF
chmod +x "$stub_bin/mcrcon"

cat > "$stub_bin/zstd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_bin/zstd"

cat > "$stub_bin/ionice" <<'EOF'
#!/usr/bin/env bash
shift; shift; shift
exec "$@"
EOF
chmod +x "$stub_bin/ionice"

cat > "$stub_bin/flock" <<'EOF'
#!/usr/bin/env bash
shift
exit 0
EOF
chmod +x "$stub_bin/flock"

cat > "$stub_bin/tar" <<'EOF'
#!/usr/bin/env bash
echo "tar:$*" >> "${TAR_LOG_FILE:?}"
exit 0
EOF
chmod +x "$stub_bin/tar"

mcrcon_log="$tmp_dir/mcrcon.log"
tar_log="$tmp_dir/tar.log"

output=$(PATH="$stub_bin:$PATH" \
    SERVER_DIR="$server_dir" \
    BACKUP_DRY_RUN=true \
    MCRCON_LOG_FILE="$mcrcon_log" \
    TAR_LOG_FILE="$tar_log" \
    bash "$SCRIPT" 2>&1) || true

# DRY_RUN must NOT call mcrcon (save-off/save-on should not touch live server).
if [ -f "$mcrcon_log" ]; then
    echo "FAIL: mcrcon foi chamado em BACKUP_DRY_RUN=true (nao deve pausar saves em servidor live)"
    cat "$mcrcon_log"
    exit 1
fi

# tar must NOT run in DRY_RUN.
if [ -f "$tar_log" ]; then
    echo "FAIL: tar nao deveria rodar em BACKUP_DRY_RUN=true"
    exit 1
fi

# DRY_RUN must log the simulation message.
if ! echo "$output" | grep -q "DRY_RUN.*Backup simulado"; then
    echo "FAIL: mensagem DRY_RUN nao encontrada"
    echo "$output"
    exit 1
fi

echo "OK: backup-dry-run"
