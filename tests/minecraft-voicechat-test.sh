#!/usr/bin/env bash
# Regression for Hub-integrated Simple Voice Chat configuration.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/server/config/voicechat" "$tmp/server/mods"
config="$tmp/server/config/voicechat/voicechat-server.properties"
echo 'server-port=25565' > "$tmp/server/server.properties"
touch "$tmp/server/mods/voicechat-forge-1.20.1.jar"
cat > "$config" <<'EOF'
# Preserve all other mod settings
port=24454
voice_host=
bind_address=
max_voice_distance=48
whisper_distance=24
enable_groups=true
EOF
run() { SERVER_DIR="$tmp/server" bash "$root/minecraft/voicechat-tools.sh" "$@"; }
run status > "$tmp/status"
grep -q '24454/UDP' "$tmp/status"
grep -q 'Distancia: 48' "$tmp/status"
run network > "$tmp/network"
grep -q 'tailscale0' "$tmp/network"
run set-port 24455 > "$tmp/changed"
grep -q '^port=24455$' "$config"
grep -q '^voice_host=$' "$config"
grep -q '^enable_groups=true$' "$config"
grep -q '^# Preserve all' "$config"
if run set-port 25565 >/dev/null 2>&1; then echo 'FAIL: game port reused' >&2; exit 1; fi
if run set-port 0 >/dev/null 2>&1; then echo 'FAIL: invalid UDP port accepted' >&2; exit 1; fi
if run set-port '24454;id' >/dev/null 2>&1; then echo 'FAIL: command injection accepted' >&2; exit 1; fi
if run edit </dev/null > "$tmp/edit" 2>&1; then echo 'FAIL: no-tty edit accepted' >&2; exit 1; fi
grep -q 'TTY' "$tmp/edit"
mv "$config" "$tmp/real.conf"
ln -s "$tmp/real.conf" "$config"
if run set-port 24456 >/dev/null 2>&1; then echo 'FAIL: symlink accepted' >&2; exit 1; fi
grep -q '^port=24455$' "$tmp/real.conf"
# All changes stay inside the voicechat config; untouched server data remains.
grep -q '^server-port=25565$' "$tmp/server/server.properties"
echo 'OK: voicechat status, preservation, valid ports, no TTY, symlink refusal and network guidance'
