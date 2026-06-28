#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/terraria/backup-cron.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir" || true' EXIT
server_dir="$tmp_dir/server"
mkdir -p "$server_dir/worlds" "$server_dir/config"

echo "seed" > "$server_dir/worlds/world.wld"
echo "config" > "$server_dir/config/serverconfig.txt"

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

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

cat > "$stub_bin/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exit 0
EOF
chmod +x "$stub_bin/flock"

cat > "$stub_bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "tar:$*" >> "${TAR_LOG_FILE:?}"
exit 0
EOF
chmod +x "$stub_bin/tar"

tar_log="$tmp_dir/tar.log"

PATH="$stub_bin:$PATH" \
SERVER_DIR="$server_dir" \
BACKUP_DRY_RUN=true \
TAR_LOG_FILE="$tar_log" \
bash "$SCRIPT"

if [ -f "$tar_log" ]; then
    echo "FAIL: tar nao deveria rodar em BACKUP_DRY_RUN=true"
    exit 1
fi

echo "OK: terraria-backup-dry-run"
