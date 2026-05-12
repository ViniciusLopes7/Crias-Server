#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/minecraft/backup-cron.sh"

tmp_dir="$(mktemp -d)"
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
if [ -n "${MCRCON_PASS:-}" ]; then
    echo "mcrcon-pass-env:set" >> "${MCRCON_LOG_FILE:?}"
fi
EOF
chmod +x "$stub_bin/mcrcon"

cat > "$stub_bin/zstd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$stub_bin/zstd"

cat > "$stub_bin/ionice" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
shift
shift
exec "$@"
EOF
chmod +x "$stub_bin/ionice"

cat > "$stub_bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Validate expected arguments for tar (should include compression and output)
if [[ "$*" != *"-c"* ]] || [[ "$*" != *"-f"* ]]; then
    echo "ERROR: tar must be called with -c (create) and -f (file) arguments" >&2
    exit 1
fi

echo "tar:$*" >> "${TAR_LOG_FILE:?}"
exit 0
EOF
chmod +x "$stub_bin/tar"

mcrcon_log="$tmp_dir/mcrcon.log"
tar_log="$tmp_dir/tar.log"

PATH="$stub_bin:$PATH" \
SERVER_DIR="$server_dir" \
BACKUP_DRY_RUN=true \
MCRCON_LOG_FILE="$mcrcon_log" \
TAR_LOG_FILE="$tar_log" \
bash "$SCRIPT"

if ! grep -q "save-off" "$mcrcon_log"; then
    echo "FAIL: mcrcon save-off nao foi chamado"
    exit 1
fi

if ! grep -q "save-on" "$mcrcon_log"; then
    echo "FAIL: mcrcon save-on nao foi chamado"
    exit 1
fi

if grep -Eq '(^|[[:space:]])-p([[:space:]]|$)' "$mcrcon_log"; then
    echo "FAIL: mcrcon ainda recebeu senha via argumento -p"
    exit 1
fi

if ! grep -q "mcrcon-pass-env:set" "$mcrcon_log"; then
    echo "FAIL: mcrcon nao recebeu senha via MCRCON_PASS"
    exit 1
fi

if [ -f "$tar_log" ]; then
    echo "FAIL: tar nao deveria rodar em BACKUP_DRY_RUN=true"
    exit 1
fi

echo "OK: backup-dry-run"
