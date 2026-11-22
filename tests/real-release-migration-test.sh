#!/usr/bin/env bash
# Migration test with REAL, immutable GitHub release assets.
# Scenario A: old ZIP -> published new ZIP, using the real first-update entry.
# Scenario B: old ZIP -> new ZIP with candidate updater/bootstraps overlaid.
# Never touches a live game or any real /opt/, /usr/local/, systemd or pacman.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo bash "$0"; fi
    echo "FAIL: real migration test requires root for admin file ownership" >&2
    exit 1
fi
for command in curl zip unzip sha256sum flock jq; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "FAIL: missing test dependency: $command" >&2; exit 1
    }
done

OLD_TAG="v2026.11.21-6674985"
NEW_TAG="v2026.11.22-8877a39"
OLD_ZIP_SHA="c81cb912a9435bb91781d40c3b228395ff81362d811d4c00ef1fdc73e4e327c0"
NEW_ZIP_SHA="06de2666d20739d69af7882da9943b39aa8694b3dd15740b64e6acc251ea3020"
URL_PREFIX="https://github.com/ViniciusLopes7/Crias-Server/releases/download"
tmp="$(mktemp -d /tmp/crias-real-migration-XXXXXXXX)"
chmod 0700 "$tmp"
trap 'rm -rf -- "$tmp"' EXIT

download_asset() {
    local tag="$1" name="$2" output="$3"
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 300 \
        --retry 5 --retry-all-errors --retry-delay 2 \
        --output "$output" "$URL_PREFIX/$tag/$name"
}

echo "[REAL-MIGRATION] Downloading published assets from GitHub..."
for tag in "$OLD_TAG" "$NEW_TAG"; do
    mkdir -p "$tmp/$tag"
    download_asset "$tag" crias-server-slim.zip "$tmp/$tag/crias-server-slim.zip"
    download_asset "$tag" sha256sums.txt "$tmp/$tag/sha256sums.txt"
    # Verify the published checksum manifest itself and an independent pinned
    # GitHub release asset digest. Neither archive is synthesized here.
    case "$tag" in
        "$OLD_TAG") expected="$OLD_ZIP_SHA" ;;
        "$NEW_TAG") expected="$NEW_ZIP_SHA" ;;
    esac
    printf '%s  %s\n' "$expected" "$tmp/$tag/crias-server-slim.zip" | sha256sum -c - >/dev/null
    (
        cd "$tmp/$tag"
        grep -E '  (./)?crias-server-slim.zip$' sha256sums.txt |
            sed 's|  \./|  |' | sha256sum -c - >/dev/null
    )
    mkdir -p "$tmp/$tag/unpacked"
    unzip -q "$tmp/$tag/crias-server-slim.zip" -d "$tmp/$tag/unpacked"
    test -s "$tmp/$tag/unpacked/crias-bootstrap.sh"
    test -s "$tmp/$tag/unpacked/install.sh"
    echo "[REAL-MIGRATION] Verified published $tag ($expected)"
done

setup_old_install() {
    local location="$1" oldroot="$tmp/$OLD_TAG/unpacked"
    mkdir -p "$location/opt" "$location/bin" "$location/libexec"
    # Invoke the old release's actual deploy helper: versioned symlink and
    # installed old content from its released ZIP, no Minecraft installer.
    (
        # shellcheck source=/dev/null
        source "$oldroot/crias-bootstrap.sh"
        crias_extract_to "$tmp/$OLD_TAG/crias-server-slim.zip" "$location/opt/crias-server" >/dev/null
    )
    test -L "$location/opt/crias-server"
    test -x "$location/opt/crias-server/install.sh"
    readlink -f "$location/opt/crias-server" > "$location/previous-release"
    cp "$location/opt/crias-server/crias-tui.sh" "$location/bin/crias-tui"
    cp "$location/opt/crias-server/minecraft/mc-manager.sh" "$location/libexec/mc-manager.sh"
    printf '\nMINECRAFT_PORT="24590"\nCUSTOM_LOCAL_SECRET="preserve-me"\n' \
        >> "$location/opt/crias-server/config.env"
    mkdir -p "$location/opt/minecraft-server/world" "$location/opt/minecraft-server/mods" \
        "$location/opt/minecraft-server/config"
    printf 'precious world data\n' > "$location/opt/minecraft-server/world/level.dat"
    printf 'mod data\n' > "$location/opt/minecraft-server/mods/example.jar"
    printf 'config data\n' > "$location/opt/minecraft-server/config/example.toml"
    printf 'level-name=world\n' > "$location/opt/minecraft-server/server.properties"
    printf 'XMX_GB=3\n' > "$location/opt/minecraft-server/runtime.env"
}

verify_migrated() {
    local location="$1" newtag="$2"
    local active="$location/opt/crias-server"
    local oldref
    oldref="$(readlink -f "$active")"
    test -L "$active"
    test "$oldref" != "$location/previous-release"
    test "$(cat "$active/.crias-release-tag")" = "$newtag"
    grep -q 'MINECRAFT_PORT="24590"' "$active/config.env"
    grep -q 'CUSTOM_LOCAL_SECRET="preserve-me"' "$active/config.env"
    test "$(stat -c %a "$active/config.env")" = 600
    test -x "$location/bin/crias-tui"
    test -x "$location/bin/crias-update"
    test -x "$location/libexec/mc-manager.sh"
    test -f "$location/libexec/lib/manager-common.sh"
    test "$(cat "$location/opt/minecraft-server/world/level.dat")" = "precious world data"
    test "$(cat "$location/opt/minecraft-server/mods/example.jar")" = "mod data"
    test "$(cat "$location/opt/minecraft-server/config/example.toml")" = "config data"
    test "$(cat "$location/opt/minecraft-server/server.properties")" = "level-name=world"
    test "$(cat "$location/opt/minecraft-server/runtime.env")" = "XMX_GB=3"
    test ! -e "$location/opt/crias-server.releases/.update-transaction"
    # Confirm no game installation/reconfiguration was invoked by this script.
    ! grep -q 'preserve-me' "$tmp/migrate-$newtag.log"
}

echo "[REAL-MIGRATION] Scenario A: exact released old -> released new"
location="$tmp/published"
setup_old_install "$location"
export CRIAS_UPDATE_INSTALL_DIR="$location/opt/crias-server"
export CRIAS_UPDATE_LIBEXEC_DIR="$location/libexec"
export CRIAS_UPDATE_BIN_DIR="$location/bin"
export CRIAS_UPDATE_LOCK="$location/update.lock"
export CRIAS_RELEASE_TAG="$NEW_TAG"
# Invoke the real first-time migration entrypoint from the published new ZIP.
# It extracts the new updater from that ZIP and runs it against the old
# versioned installation, fetching the official release through GitHub.
(
    source "$tmp/$NEW_TAG/unpacked/crias-bootstrap.sh"
    mkdir -p "$tmp/first-entry"
    # Published updater v2026.11.22 resolves the old bootstrap from
    # /opt/crias-server. CI cannot use real /opt; stage an IDENTICAL copy of
    # the official old bootstrap beside it (same code, isolated path).
    cp "$location/opt/crias-server/crias-bootstrap.sh" "$tmp/first-entry/crias-bootstrap.sh"
    cmp "$tmp/$OLD_TAG/unpacked/crias-bootstrap.sh" "$tmp/first-entry/crias-bootstrap.sh"
    crias_bootstrap_tools_only "$tmp/$NEW_TAG/crias-server-slim.zip" "$tmp/first-entry"
) > "$tmp/migrate-$NEW_TAG.log" 2>&1 || {
    cat "$tmp/migrate-$NEW_TAG.log" >&2; exit 1
}
verify_migrated "$location" "$NEW_TAG"
echo "[REAL-MIGRATION] PASS exact production bootstrap --update-tools path"

echo "[REAL-MIGRATION] Scenario B: old release + candidate updater and bootstrap"
location="$tmp/candidate"
setup_old_install "$location"
export CRIAS_UPDATE_INSTALL_DIR="$location/opt/crias-server"
export CRIAS_UPDATE_LIBEXEC_DIR="$location/libexec"
export CRIAS_UPDATE_BIN_DIR="$location/bin"
export CRIAS_UPDATE_LOCK="$location/update.lock"
mkdir -p "$tmp/candidate-payload" "$tmp/candidate-script"
cp -a "$tmp/$NEW_TAG/unpacked/." "$tmp/candidate-payload/"
cp "$ROOT/crias-update.sh" "$tmp/candidate-payload/crias-update.sh"
cp "$ROOT/crias-bootstrap.sh" "$tmp/candidate-payload/crias-bootstrap.sh"
(
    cd "$tmp/candidate-payload"
    zip -qr "$tmp/candidate-slim.zip" .
)
printf '%s  crias-server-slim.zip\n' "$(sha256sum "$tmp/candidate-slim.zip" | awk '{print $1}')" > "$tmp/candidate.sha256"
cp "$ROOT/crias-update.sh" "$tmp/candidate-script/crias-update.sh"
# Live code under test, but REAL release payload for every other file.
(
    source "$tmp/candidate-script/crias-update.sh"
    crias_fetch_release_urls() {
        CRIAS_RELEASE_TAG_NAME="$NEW_TAG"
        CRIAS_ZIP_URL="$URL_PREFIX/$NEW_TAG/crias-server-slim.zip"
        CRIAS_SHA_URL="$URL_PREFIX/$NEW_TAG/sha256sums.txt"
        CRIAS_RELEASE_TARGET="8877a39"
    }
    update_download() {
        case "$1" in
            */crias-server-slim.zip) cp "$tmp/candidate-slim.zip" "$2" ;;
            */sha256sums.txt) cp "$tmp/candidate.sha256" "$2" ;;
            *) return 1 ;;
        esac
    }
    update_apply
) > "$tmp/migrate-candidate.log" 2>&1 || {
    cat "$tmp/migrate-candidate.log" >&2; exit 1
}
cp "$tmp/migrate-candidate.log" "$tmp/migrate-$NEW_TAG.log"
verify_migrated "$location" "$NEW_TAG"
cmp "$ROOT/crias-update.sh" "$location/opt/crias-server/crias-update.sh"
echo "[REAL-MIGRATION] PASS candidate updater migrated immutable old release with candidate overlay"
echo "[REAL-MIGRATION] PASS verified official archives, checksum, settings, worlds, mods and admin tools"
