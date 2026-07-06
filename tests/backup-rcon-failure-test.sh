#!/usr/bin/env bash
# tests/backup-rcon-failure-test.sh
# Valida que save-on é sempre restaurado quando save-off foi enviado,
# mesmo se save-all falhar (cobre o bug C-1/C-2 da auditoria original).
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

# mcrcon stub: save-off succeeds, save-all fails, save-on succeeds.
# This simulates the dangerous scenario where save-off was sent but save-all fails.
MCRCON_LOG="$tmp_dir/mcrcon.log"
cat > "$stub_bin/mcrcon" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "mcrcon:\$*" >> "$MCRCON_LOG"
# save-off: succeed
# save-all: fail (exit 1)
# save-on: succeed
case "\$*" in
    *save-off*) exit 0 ;;
    *save-all*) exit 1 ;;
    *save-on*) exit 0 ;;
    *) exit 0 ;;
esac
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
exit 0
EOF
chmod +x "$stub_bin/tar"

TAR_LOG="$tmp_dir/tar.log"
export TAR_LOG

# Run backup (not DRY_RUN) — save-off succeeds, save-all fails.
# The trap should ensure save-on is still called.
PATH="$stub_bin:$PATH" \
    SERVER_DIR="$server_dir" \
    BACKUP_DRY_RUN=false \
    BACKUP_REQUIRE_ACTIVE_SERVICE=false \
    bash "$SCRIPT" 2>&1 || true

# save-off must have been called.
if ! grep -q "save-off" "$MCRCON_LOG"; then
    echo "FAIL: save-off nao foi chamado"
    cat "$MCRCON_LOG"
    exit 1
fi

# save-on MUST have been called (even though save-all failed).
# This is the critical assertion: the trap must restore saves.
if ! grep -q "save-on" "$MCRCON_LOG"; then
    echo "FAIL: save-on nao foi chamado apos falha de save-all (C-1/C-2 bug)"
    echo "  mcrcon log:"
    cat "$MCRCON_LOG"
    exit 1
fi

echo "OK: backup-rcon-failure (save-on restaurado apos falha de save-all)"
