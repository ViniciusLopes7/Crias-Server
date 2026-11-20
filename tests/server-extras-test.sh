#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
source "$root/minecraft/install.sh"
MINECRAFT_SERVER_DIR="$tmp/server"
mkdir -p "$MINECRAFT_SERVER_DIR/mods" "$tmp/jar/META-INF"
printf '[[mods]]\nmodId="spark"\n' > "$tmp/jar/META-INF/mods.toml"
(cd "$tmp/jar" && zip -q "$MINECRAFT_SERVER_DIR/mods/renamed.jar" META-INF/mods.toml)
printf '[[mods]]\nmodId="different"\n[[dependencies.different]]\nmodId="skinrestorer"\n' > "$tmp/jar/META-INF/mods.toml"
(cd "$tmp/jar" && zip -q "$MINECRAFT_SERVER_DIR/mods/other.jar" META-INF/mods.toml)
touch "$MINECRAFT_SERVER_DIR/mods/Chunky-1.3.146.jar"
MINECRAFT_LOADER=forge
MC_EFFECTIVE_VERSION=1.20.1
MINECRAFT_EXTRA_MODS='spark,chunky,skinrestorer'
DRY_RUN=false
MINECRAFT_PENDING_MODS=()
download_modrinth_mod() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$tmp/downloads"; }
stack_install_extra_mods
[ "$(cat "$tmp/downloads")" = 'skinrestorer forge 1.20.1' ]
echo 'OK: curated extras detect existing mods, resolve effective version and avoid dependency false positive'
