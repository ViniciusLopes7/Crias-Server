#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source "$ROOT/minecraft/install.sh"
MINECRAFT_SERVER_DIR="$tmp"
MINECRAFT_VERSION=26.3
MINECRAFT_LOADER=fabric
MINECRAFT_SERVER_FILE=server.jar
cat > "$tmp/packstate.json" <<'JSON'
{"schema":1,"dependencies":{"minecraft":"1.20.1","fabric-loader":"","forge":"47.4.0"},"server-file":{"path":"actual.jar"}}
JSON
_resolve_modpack_effective_versions
[ "$MC_EFFECTIVE_VERSION" = 1.20.1 ]
[ "$MINECRAFT_LOADER" = forge ]
[ "$MINECRAFT_SERVER_FILE" = actual.jar ]
printf '%s\n' '{"dependencies":{"minecraft":"1.21.1","fabric-loader":"1","forge":"2"}}' > "$tmp/packstate.json"
if _resolve_modpack_effective_versions >"$tmp/ambiguous.log" 2>&1; then echo 'FAIL: ambiguous loader accepted' >&2; exit 1; fi
grep -q 'multiplos loaders' "$tmp/ambiguous.log"
echo 'OK: ambiguous loaders rejected as expected'
rm "$tmp/packstate.json"
if _resolve_modpack_effective_versions >"$tmp/missing.log" 2>&1; then echo 'FAIL: missing state accepted' >&2; exit 1; fi
grep -q 'Nao foi possivel confirmar' "$tmp/missing.log"
echo 'OK: missing pack state rejected as expected'
echo 'OK: actual pack state determines version, loader and server file'
