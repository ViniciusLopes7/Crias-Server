#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for manager in minecraft/mc-manager.sh terraria/tt-manager.sh; do
    SERVER_DIR="$tmp" bash "$ROOT/$manager" help >"$tmp/out" 2>&1 || true
    if grep -q 'unbound variable' "$tmp/out" || ! grep -q 'Uso:' "$tmp/out"; then
        cat "$tmp/out" >&2; exit 1
    fi
done
cat > "$tmp/java" <<'JAVA'
#!/bin/bash
if [ "${1:-}" = -version ]; then echo 'openjdk version "21.0.1"' >&2; exit 0; fi
printf '%s\n' "$@" > "$SERVER_DIR/captured"
JAVA
chmod +x "$tmp/java"
printf 'server-port=25565\n' > "$tmp/server.properties"
printf 'MINECRAFT_LOADER=forge\nMINECRAFT_VERSION=1.21\n' > "$tmp/runtime.env"
mkdir -p "$tmp/libraries/net/minecraftforge/forge/1.21-test"
touch "$tmp/libraries/net/minecraftforge/forge/1.21-test/unix_args.txt"
SERVER_DIR="$tmp" JAVA_BIN="$tmp/java" bash "$ROOT/minecraft/start-server.sh" >"$tmp/out" 2>&1
if ! grep -Fxq '@libraries/net/minecraftforge/forge/1.21-test/unix_args.txt' "$tmp/captured" || grep -Fxq -- '-jar' "$tmp/captured"; then
    cat "$tmp/out" "$tmp/captured" >&2; exit 1
fi
mkdir -p "$tmp/libraries/net/minecraftforge/forge/old"
touch "$tmp/libraries/net/minecraftforge/forge/old/unix_args.txt"
if SERVER_DIR="$tmp" JAVA_BIN="$tmp/java" bash "$ROOT/minecraft/start-server.sh" >"$tmp/out" 2>&1; then
    echo 'Expected ambiguous loader installation to fail' >&2; exit 1
fi
# Mesmo que o heap de runtime.env seja seguro, user_jvm_args.txt nao pode
# sobrescreve-lo e ultrapassar MemoryMax silenciosamente.
rm -f "$tmp/libraries/net/minecraftforge/forge/old/unix_args.txt"
printf '# -Xmx4G (comentario nao deve ser considerado)\n' > "$tmp/user_jvm_args.txt"
SERVER_DIR="$tmp" JAVA_BIN="$tmp/java" bash "$ROOT/minecraft/start-server.sh" >"$tmp/out" 2>&1
printf '-Xmx4G\n' >> "$tmp/user_jvm_args.txt"
if SERVER_DIR="$tmp" JAVA_BIN="$tmp/java" bash "$ROOT/minecraft/start-server.sh" >"$tmp/out" 2>&1; then
    echo "FAIL: arquivo de args Forge sobrescreveu Xmx" >&2; exit 1
fi
grep -q 'user_jvm_args.txt contem Xmx' "$tmp/out"
rm -f "$tmp/user_jvm_args.txt"
printf 'MINECRAFT_LOADER=forge\nMINECRAFT_VERSION=1.21\nMIN_RAM=256M\nMAX_RAM=64M\n' > "$tmp/runtime.env"
if SERVER_DIR="$tmp" JAVA_BIN="$tmp/java" bash "$ROOT/minecraft/start-server.sh" >"$tmp/out" 2>&1; then
    echo "FAIL: runtime com Xms > Xmx foi aceito" >&2; exit 1
fi
grep -q 'MIN_RAM.*excede MAX_RAM' "$tmp/out"

echo 'OK: manager entrypoints and Forge launcher regression checks'
