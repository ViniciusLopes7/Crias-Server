#!/usr/bin/env bash
# Contract: RCON setup is safe, preserves game properties and does not restart.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/crias-rcon-ci-XXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/server"
props="$tmp/server/server.properties"
cat > "$tmp/bin/mcrcon" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    echo '  --no-tui  Disable fullscreen terminal'
    exit 0
fi
echo "mcrcon test stub"
EOF
chmod 0755 "$tmp/bin/mcrcon"

# Verify non-root health checks: neither root password nor new server required.
cat > "$props" <<'EOF'
# Personal world settings must not be lost
server-port=25565
online-mode=false
motd=Reino dos Crias
level-name=nosso-reino
enable-rcon=false
rcon.password=
rcon.port=25575
EOF

if [ "$(id -u)" -eq 0 ]; then
    runner=()
elif command -v sudo >/dev/null && sudo -n true >/dev/null 2>&1; then
    runner=(sudo -n)
else
    echo "SKIP: teste de configuracao RCON requer root/sudo no runner"
    bash -n "$root/minecraft/mc-manager.sh"
    bash -n "$root/minecraft/install-mcrcon.sh"
    exit 0
fi

manager="$root/minecraft/mc-manager.sh"
call_manager() {
    "${runner[@]}" env \
        CRIS_MANAGER_ALLOW_UNSAFE=1 \
        SERVER_DIR="$tmp/server" \
        SERVER_USER="$(id -un)" \
        PATH="$tmp/bin:$PATH" \
        bash "$manager" "$@"
}
call_manager setup-console > "$tmp/setup.log" 2>&1 || {
    echo "FAIL: setup-console nao funcionou" >&2
    cat "$tmp/setup.log" >&2
    exit 1
}
grep -q '^enable-rcon=true$' "$props"
grep -q '^rcon.port=25575$' "$props"
grep -q '^online-mode=false$' "$props"
grep -q '^level-name=nosso-reino$' "$props"
grep -q '^motd=Reino dos Crias$' "$props"
grep -q '^# Personal world settings' "$props"
test "$(stat -c '%a' "$props")" = 600
pass="$(awk -F= '$1=="rcon.password" {print $2}' "$props")"
[[ "$pass" =~ ^[0-9a-f]{64}$ ]] || { echo 'FAIL: senha RCON nao foi gerada corretamente' >&2; exit 1; }
if grep -Fq "$pass" "$tmp/setup.log"; then
    echo "FAIL: senha vazou para logs do setup" >&2
    exit 1
fi

# Idempotent: keep the existing password (no silent rotation).
call_manager setup-console > "$tmp/setup2.log" 2>&1
pass2="$(awk -F= '$1=="rcon.password" {print $2}' "$props")"
test "$pass" = "$pass2"

# Explicitly refuse a symlink in place of properties.
mv "$props" "$tmp/real.properties"
ln -s "$tmp/real.properties" "$props"
if call_manager setup-console > "$tmp/symlink.log" 2>&1; then
    echo 'FAIL: symlink server.properties foi aceito' >&2
    exit 1
fi
grep -q 'link simbolico' "$tmp/symlink.log"
test "$(awk -F= '$1=="rcon.password" {print $2}' "$tmp/real.properties")" = "$pass"

# Console without an interactive TTY must fail clearly, never fallback to
# journalctl (which previously caused an unending mass of log lines).
rm "$props"
mv "$tmp/real.properties" "$props"
if call_manager console </dev/null > "$tmp/console.log" 2>&1; then
    echo 'FAIL: console sem TTY abriu' >&2
    exit 1
fi
grep -q 'TTY' "$tmp/console.log"
if grep -q 'Acompanhando as ultimas 80 linhas' "$tmp/console.log"; then
    echo 'FAIL: console caiu silenciosamente para logs' >&2
    exit 1
fi

echo 'OK: mcrcon setup idempotente, senha privada, propriedades preservadas, sem TTY falha segura'
