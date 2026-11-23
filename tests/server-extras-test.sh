#!/bin/bash
# Characterization: current extra/QoL identity rules, before refactoring.
# Real fixture JARs + stubbed download; no network or live server.
set -euo pipefail
exec </dev/null
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
source "$root/minecraft/install.sh"

MINECRAFT_SERVER_DIR="$tmp/server"
CALLS="$tmp/downloads"
DRY_RUN=false

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset_case() {
    rm -rf -- "$MINECRAFT_SERVER_DIR"
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"
    : > "$CALLS"
    MINECRAFT_PENDING_MODS=()
    MINECRAFT_INSTALL_QOL_MODS=true
    MINECRAFT_MODS_STRICT=false
    MINECRAFT_LOADER=forge
    MINECRAFT_VERSION=1.21.1
    MC_EFFECTIVE_VERSION=1.20.1
    MINECRAFT_EXTRA_MODS=""
    MINECRAFT_QOL_MODS=""
    FAIL_SLUG=""
}
make_jar() {
    local name="$1" member="$2" payload="$3" work="$tmp/fixture"
    rm -rf -- "$work"
    mkdir -p "$work/$(dirname "$member")"
    printf '%b' "$payload" > "$work/$member"
    (cd "$work" && zip -q "$MINECRAFT_SERVER_DIR/mods/$name" "$member")
}
download_modrinth_mod() {
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$5" "${6:-}" >> "$CALLS"
    [ "$1" != "$FAIL_SLUG" ]
}
assert_downloads() {
    local actual expected="$1"
    actual="$(cat "$CALLS")"
    [ "$actual" = "$expected" ] || fail "calls: expected [$expected], got [$actual]"
}
assert_pending() {
    [ "${#MINECRAFT_PENDING_MODS[@]}" -eq "$1" ] ||
        fail "pending expected $1, got ${#MINECRAFT_PENDING_MODS[@]}"
}

# A renamed Forge JAR is identified by its declared root mod ID.
reset_case
make_jar "opaque.jar" "META-INF/mods.toml" '[[mods]]\nmodId="spark"\n'
MINECRAFT_EXTRA_MODS="spark"
stack_install_extra_mods
assert_downloads ""
assert_pending 0

# Dependencies must not be mistaken for a mod declaration.
reset_case
make_jar "other.jar" "META-INF/mods.toml" '[[mods]]\nmodId="other"\n[[dependencies.other]]\nmodId="skinrestorer"\n'
MINECRAFT_EXTRA_MODS="skinrestorer"
stack_install_extra_mods
assert_downloads 'skinrestorer|forge|1.20.1|skinrestorer|'
assert_pending 0

# Renamed Fabric JAR with matching ID is recognized in extra mode.
reset_case
MINECRAFT_LOADER=fabric
make_jar "opaque.jar" "fabric.mod.json" '{"id":"chunky","version":"1.0"}'
MINECRAFT_EXTRA_MODS="chunky"
stack_install_extra_mods
assert_downloads ""

# Known versioned names and exact slug.jar are recognized in extra mode.
reset_case
touch "$MINECRAFT_SERVER_DIR/mods/ChUnKy-1.3.jar"
MINECRAFT_EXTRA_MODS="chunky"
stack_install_extra_mods
assert_downloads ""
reset_case
touch "$MINECRAFT_SERVER_DIR/mods/spark.jar"
MINECRAFT_EXTRA_MODS="spark"
stack_install_extra_mods
assert_downloads ""

# BASELINE GAP: NeoForge-specific metadata is not read for a renamed JAR.
reset_case
MINECRAFT_LOADER=neoforge
make_jar "opaque.jar" "META-INF/neoforge.mods.toml" '[[mods]]\nmodId="spark"\n'
MINECRAFT_EXTRA_MODS="spark"
stack_install_extra_mods
assert_downloads 'spark|neoforge|1.20.1|spark|'
echo 'BASELINE GAP: renamed NeoForge JAR not detected by extras'

# BASELINE GAP: QoL versioned-name loop receives no file input.
reset_case
MINECRAFT_LOADER=fabric
touch "$MINECRAFT_SERVER_DIR/mods/Chunky-1.3.jar"
MINECRAFT_QOL_MODS="chunky:chunky"
install_minecraft_qol_mods
assert_downloads 'chunky|fabric|1.20.1|chunky|MOD_CHUNKY_SHA256'
echo 'BASELINE GAP: QoL downloads an existing versioned Chunky JAR'

# BASELINE GAP: QoL ignores matching mod ID in renamed Fabric JAR.
reset_case
MINECRAFT_LOADER=fabric
make_jar "opaque.jar" "fabric.mod.json" '{"id":"spark"}'
MINECRAFT_QOL_MODS="spark:spark"
install_minecraft_qol_mods
assert_downloads 'spark|fabric|1.20.1|spark|MOD_SPARK_SHA256'
echo 'BASELINE GAP: QoL ignores renamed Fabric mod ID'

# Separate QoL policy: file_name is destination, slug is project.
reset_case
MINECRAFT_LOADER=fabric
MINECRAFT_QOL_MODS="server-tool:spark"
install_minecraft_qol_mods
assert_downloads 'spark|fabric|1.20.1|server-tool|MOD_SERVER_TOOL_SHA256'

# The QoL set is gated by loader; extras are skipped on vanilla.
reset_case
MINECRAFT_LOADER=forge
MINECRAFT_QOL_MODS="spark:spark"
install_minecraft_qol_mods
assert_downloads ""
reset_case
MINECRAFT_LOADER=vanilla
MINECRAFT_EXTRA_MODS=spark
stack_install_extra_mods
assert_downloads ""

# Download failures collect pending mods; strict is evaluated at finalize.
reset_case
MINECRAFT_EXTRA_MODS="spark"
FAIL_SLUG="spark"
stack_install_extra_mods
assert_downloads 'spark|forge|1.20.1|spark|'
assert_pending 1
stack_install_finalize
MINECRAFT_MODS_STRICT=true
if stack_install_finalize; then
    fail "strict mode accepted pending mods"
fi

echo 'OK: characterized extra/QoL lookup, effective version and strict policy'
