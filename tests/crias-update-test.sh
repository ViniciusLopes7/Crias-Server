#!/usr/bin/env bash
# Offline integration test of release updater. Requires root for root-owned
# admin tools, but all paths and fixtures are isolated under /tmp.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        exec sudo -n bash "$0"
    fi
    echo "SKIP: teste integrado do updater exige root/sudo"
    exit 0
fi
tmp="$(mktemp -d /tmp/crias-update-test-XXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

export CRIAS_UPDATE_INSTALL_DIR="$tmp/app"
export CRIAS_UPDATE_LIBEXEC_DIR="$tmp/libexec"
export CRIAS_UPDATE_BIN_DIR="$tmp/bin"
export CRIAS_UPDATE_LOCK="$tmp/crias-update.lock"
# shellcheck source=/dev/null
source "$root/crias-update.sh"

# Build a synthetic, offline release with the real current admin scripts.
mkdir -p "$tmp/release"
for dir in shared minecraft terraria; do
    cp -a "$root/$dir" "$tmp/release/"
done
for file in install.sh crias-bootstrap.sh crias-tui.sh crias-update.sh config.env; do
    cp -a "$root/$file" "$tmp/release/"
done
(
    cd "$tmp/release"
    zip -qr "$tmp/crias-server-slim.zip" .
)
(cd "$tmp" && sha256sum crias-server-slim.zip > sha256sums.txt)

# Simulate a prior installed version with a modified config.env and game data.
mkdir -p "$tmp/app.releases/release.previous" "$tmp/bin" "$tmp/libexec" "$tmp/minecraft/world"
printf '%s\n' "MINECRAFT_PORT=24512" 'CUSTOM_SECRET=not-for-logs' > "$tmp/app.releases/release.previous/config.env"
printf '%s\n' 'v2026.11.21-previous' > "$tmp/app.releases/release.previous/.crias-release-tag"
echo '#!/bin/bash' > "$tmp/app.releases/release.previous/install.sh"
echo "old hub" > "$tmp/bin/crias-tui"
echo "old manager" > "$tmp/libexec/mc-manager.sh"
echo "game-world-must-not-change" > "$tmp/minecraft/world/level.dat"
ln -s "$tmp/app.releases/release.previous" "$tmp/app"
worldhash="$(sha256sum "$tmp/minecraft/world/level.dat" | awk '{print $1}')"
oldref="$(readlink -f "$tmp/app")"

# No internet is used; official API/asset names are simulated exactly.
release_tag="v2026.11.22-test"
crias_fetch_release_urls() {
    CRIAS_RELEASE_TAG_NAME="$release_tag"
    CRIAS_ZIP_URL="https://github.com/$CRIAS_REPO/releases/download/$release_tag/$CRIAS_ASSET_ZIP"
    CRIAS_SHA_URL="https://github.com/$CRIAS_REPO/releases/download/$release_tag/$CRIAS_ASSET_SHA"
    CRIAS_RELEASE_TARGET="fixture"
}
update_download() {
    local url="$1" output="$2"
    case "$url" in
        */crias-server-slim.zip) cp -- "$tmp/crias-server-slim.zip" "$output" ;;
        */sha256sums.txt) cp -- "$tmp/sha256sums.txt" "$output" ;;
        *) return 1 ;;
    esac
}
update_check > "$tmp/check.log"
grep -q "$release_tag" "$tmp/check.log"
test "$(readlink -f "$tmp/app")" = "$oldref"

# Real apply updates only admin tools and versioned source files.
update_apply > "$tmp/update.log"
newref="$(readlink -f "$tmp/app")"
test "$newref" != "$oldref"
test -x "$tmp/bin/crias-update"
test -x "$tmp/bin/crias-tui"
test -x "$tmp/libexec/mc-manager.sh"
test -r "$tmp/libexec/lib/manager-common.sh"
test "$(cat "$newref/.crias-release-tag")" = "$release_tag"
test "$(stat -c %a "$newref/config.env")" = 600
grep -q 'MINECRAFT_PORT=24512' "$newref/config.env"
grep -q 'CUSTOM_SECRET=not-for-logs' "$newref/config.env"
! grep -q 'not-for-logs' "$tmp/update.log"
test "$(sha256sum "$tmp/minecraft/world/level.dat" | awk '{print $1}')" = "$worldhash"
grep -q '^old hub$' "$tmp/bin/crias-tui" && { echo 'FAIL: Hub nao atualizou' >&2; exit 1; }

# Second call must not touch the current install.
update_apply > "$tmp/idempotent.log"
test "$(readlink -f "$tmp/app")" = "$newref"
grep -q 'ja instalada' "$tmp/idempotent.log"

# A checksum mismatch MUST NOT publish or touch binaries.
release_tag="v2026.11.22-corrupted"
update_download() {
    local url="$1" output="$2"
    case "$url" in
        */crias-server-slim.zip) cp -- "$tmp/crias-server-slim.zip" "$output" ;;
        */sha256sums.txt) printf '%064d  crias-server-slim.zip\n' 0 > "$output" ;;
        *) return 1 ;;
    esac
}
if (update_apply >"$tmp/invalid.log" 2>&1); then
    echo "FAIL: release com SHA invalido aplicada" >&2
    exit 1
fi
test "$(readlink -f "$tmp/app")" = "$newref"

# A failure AFTER switching releases must restore both link and admin files.
release_tag="v2026.11.22-rollback"
update_download() {
    local url="$1" output="$2"
    case "$url" in
        */crias-server-slim.zip) cp -- "$tmp/crias-server-slim.zip" "$output" ;;
        */sha256sums.txt) cp -- "$tmp/sha256sums.txt" "$output" ;;
        *) return 1 ;;
    esac
}
# Overrides only within a subshell, so the production function stays intact.
if (
    update_deploy_admin() {
        update_track_install "$CRIAS_UPDATE_INSTALL_DIR/crias-tui.sh" "$CRIAS_UPDATE_BIN_DIR/crias-tui" 0755 || return 1
        echo 'injected failure after partial deploy' >&2
        return 27
    }
    update_apply > "$tmp/failure.log" 2>&1
); then
    echo "FAIL: falha no deploy foi aceita" >&2
    exit 1
fi
test "$(readlink -f "$tmp/app")" = "$newref"
test "$(sha256sum "$tmp/minecraft/world/level.dat" | awk '{print $1}')" = "$worldhash"
test -x "$tmp/bin/crias-update"
test "$(cat "$newref/.crias-release-tag")" = "v2026.11.22-test"

# Crash test: a separate process prepares the durable journal, switches
# the release, replaces an admin tool, and is SIGKILLed before commit.
# Recovery must work in a NEW process, with no in-memory trap state.
crashref="$tmp/app.releases/release.crashed"
cp -a "$newref" "$crashref"
printf '#!/bin/bash\n# partial admin file from crash\n' > "$crashref/crias-tui.sh"
if (
    update_prepare_journal "$newref" "$crashref" || exit 1
    update_publish_release() {
        ln -s "$crashref" "$tmp/crash-link" || return 1
        mv -f -T "$tmp/crash-link" "$tmp/app" || return 1
    }
    UPDATE_NEW_REF="$crashref"
    update_publish_release || exit 1
    update_track_install "$crashref/crias-tui.sh" "$tmp/bin/crias-tui" 0755 || exit 1
    kill -KILL "$BASHPID"
); then
    echo "FAIL: subprocesso SIGKILL deveria retornar falha" >&2
    exit 1
fi
test "$(readlink -f "$tmp/app")" = "$crashref"
grep -q 'partial admin file' "$tmp/bin/crias-tui"
# Recovery must not need network, new downloads, or the process that crashed.
update_recover
test "$(readlink -f "$tmp/app")" = "$newref"
test ! -d "$tmp/app.releases/.update-transaction"
! grep -q 'partial admin file' "$tmp/bin/crias-tui"
test "$(sha256sum "$tmp/minecraft/world/level.dat" | awk '{print $1}')" = "$worldhash"
echo "OK: SIGKILL deixou journal persistente; proxima execucao restaurou link e scripts"

# An update must refuse direct/nonversioned installations, without removing.
mkdir -p "$tmp/ordinary"
echo 'legacy' > "$tmp/ordinary/install.sh"
(
    CRIAS_UPDATE_INSTALL_DIR="$tmp/ordinary"
    if update_apply > /dev/null 2>&1; then
        echo "FAIL: alterou diretorio nao versionado" >&2
        exit 1
    fi
)
test -f "$tmp/ordinary/install.sh"

# Package upgrades must refuse non-interactive execution, before pacman runs.
pacman() { echo "PACMAN-RAN" > "$tmp/unexpected-pacman"; return 1; }
if update_arch_apply </dev/null > "$tmp/arch-guard.log" 2>&1; then
    echo "FAIL: Arch update aceitou sessao sem TTY" >&2
    exit 1
fi
test ! -e "$tmp/unexpected-pacman" || {
    echo "FAIL: atualizacao Arch disparou pacman sem TTY" >&2
    exit 1
}
echo 'OK: updater offline, tag, checksum, config private, atomic publish, idempotence, rollback, no game changes, Arch TTY guard'
