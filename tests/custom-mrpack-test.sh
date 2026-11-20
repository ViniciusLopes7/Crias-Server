#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/pack" "$tmp/USB com espaco" "$tmp/server" "$tmp/bin"
printf '%s\n' '{"formatVersion":1,"game":"minecraft","versionId":"test","name":"Teste","files":[],"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"}}' > "$tmp/pack/modrinth.index.json"
(cd "$tmp/pack" && zip -q "$tmp/USB com espaco/meu pack.mrpack" modrinth.index.json)
export TEST_ARCHIVE="$tmp/USB com espaco/meu pack.mrpack" TEST_LOG="$tmp/args.log"
cat > "$tmp/bin/mrpack-install" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --server-dir ]; then shift; server="$1"; fi
    shift
done
printf '%s\n' '{"schema":1,"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"},"server-file":{"path":"server.jar"}}' > "$server/packstate.json"
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_LOG.curl"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then shift; output="$1"; fi
    shift
done
cp "$TEST_ARCHIVE" "$output"
STUB
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$root/minecraft/install.sh"
install_mrpack_install() { :; }
MINECRAFT_SERVER_DIR="$tmp/server"
MINECRAFT_VERSION=1.21.1
MINECRAFT_LOADER=fabric
MINECRAFT_INSTALL_MODPACK=true
MINECRAFT_MODPACK_SOURCE=arquivo
MINECRAFT_MODPACK_FILE="$TEST_ARCHIVE"
_validate_custom_mrpack "$TEST_ARCHIVE"
stack_download_and_install
grep -Fxq "$TEST_ARCHIVE" "$TEST_LOG"
[ "$MC_EFFECTIVE_VERSION" = 1.21.1 ] && [ "$MINECRAFT_LOADER" = fabric ]
MINECRAFT_MODPACK_SOURCE=link
MINECRAFT_MODPACK_URL='https://example.com/pack?token=secret&download=1'
stack_download_and_install
if grep -q 'secret' "$TEST_LOG.curl"; then echo 'FAIL: URL leaked into curl arguments' >&2; exit 1; fi
grep -Fxq -- '--config' "$TEST_LOG.curl"
for bad in 'http://example.com/a' 'https://example.com/"bad' 'https://example.com/\bad' $'https://example.com/a\nurl = "https://bad"'; do
    if _valid_custom_pack_url "$bad"; then echo 'FAIL: invalid URL accepted' >&2; exit 1; fi
done
printf 'not zip\n' > "$tmp/bad.mrpack"
if _validate_custom_mrpack "$tmp/bad.mrpack" >/dev/null 2>&1; then echo 'FAIL: corrupt pack accepted' >&2; exit 1; fi
printf '%s\n' '{"formatVersion":1,"game":"not-minecraft"}' > "$tmp/pack/modrinth.index.json"
(cd "$tmp/pack" && zip -q -FS "$tmp/invalid.mrpack" modrinth.index.json)
if _validate_custom_mrpack "$tmp/invalid.mrpack" >/dev/null 2>&1; then echo 'FAIL: invalid index accepted' >&2; exit 1; fi
echo 'OK: local paths, HTTPS import, secret-safe arguments and pack validation'

# Exercise the actual wizard and the handoff to the stack installer, including spaces.
(
    # shellcheck source=/dev/null
    source "$root/install.sh"
    SERVER_TYPE=minecraft
    choice='Arquivo .mrpack (local ou pendrive montado)'
    tui_choose() { printf -v "$1" '%s' "$choice"; }
    tui_input() { printf -v "$1" '%s' "$TEST_ARCHIVE"; }
    lsblk() { :; }
    prompt_minecraft_modpack_dynamic
    [ "$MINECRAFT_MODPACK_SOURCE" = arquivo ] && [ "$MINECRAFT_MODPACK_FILE" = "$TEST_ARCHIVE" ]
    env_file=$(write_stack_env_file)
    unset MINECRAFT_MODPACK_FILE MINECRAFT_MODPACK_SOURCE
    # shellcheck source=/dev/null
    source "$env_file"
    rm -f "$env_file"
    [ "$MINECRAFT_MODPACK_SOURCE" = arquivo ] && [ "$MINECRAFT_MODPACK_FILE" = "$TEST_ARCHIVE" ]
    choice='Link direto HTTPS de .mrpack'
    tui_input() { printf -v "$1" '%s' 'https://example.com/pack?download=1&x=2'; }
    prompt_minecraft_modpack_dynamic
    [ "$MINECRAFT_MODPACK_SOURCE" = link ] && [ "$MINECRAFT_MODPACK_URL" = 'https://example.com/pack?download=1&x=2' ]
    env_file=$(write_stack_env_file)
    unset MINECRAFT_MODPACK_URL MINECRAFT_MODPACK_SOURCE
    # shellcheck source=/dev/null
    source "$env_file"
    rm -f "$env_file"
    [ "$MINECRAFT_MODPACK_SOURCE" = link ] && [ "$MINECRAFT_MODPACK_URL" = 'https://example.com/pack?download=1&x=2' ]
)
echo 'OK: wizard selection and stack handoff preserve paths and URLs'
