#!/bin/bash
# End-to-end checks for temporary registry, safe cleanup and root TMPDIR.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export TMPDIR="$tmp"

# Predictable/inherited registry paths are never trusted.
forged="$tmp/crias-temps.$$"
printf "do-not-touch\n" > "$forged"
export CRIAS_TEMPS_FILE="$forged"
# shellcheck source=/dev/null
source "$root/shared/lib/common.sh"
[ "$CRIAS_TEMPS_FILE" != "$forged" ]
[ "$(cat "$forged")" = do-not-touch ]
[ -f "$CRIAS_TEMPS_FILE" ]
[ "$(stat -c %a "$CRIAS_TEMPS_FILE")" = 600 ]

if [ "$EUID" -eq 0 ]; then
    [ "$_crias_temp_root" = /tmp ] || { echo "FAIL: root honored unsafe TMPDIR" >&2; exit 1; }
else
    [ "$_crias_temp_root" = "$tmp" ] || { echo "FAIL: TMPDIR ignored for unprivileged process" >&2; exit 1; }
fi

first="$(mktemp_crias_dir)"
[ -d "$first" ] && [ "$(stat -c %a "$first")" = 700 ]
printf "data\n" > "$first/data"
remove_crias_temp_dir "$first"
[ ! -e "$first" ] || { echo "FAIL: registered directory remains" >&2; exit 1; }

secret="$(mktemp_crias_file)"
[ -f "$secret" ] && [ "$(stat -c %a "$secret")" = 600 ]

foreign="$tmp/foreign-work"
mkdir "$foreign"
if remove_crias_temp_dir "$foreign" >/dev/null 2>&1; then
    echo "FAIL: unregistered directory removed" >&2; exit 1
fi
[ -d "$foreign" ]

second="$(mktemp_crias_dir)"
rmdir "$second"
ln -s "$foreign" "$second"
if remove_crias_temp_dir "$second" >/dev/null 2>&1; then
    echo "FAIL: symlink accepted by explicit removal" >&2; exit 1
fi

# The EXIT handler must validate entries, not blindly rm -rf a registry line.
printf "%s\n" "$foreign" "$tmp/../" "/tmp/crias.x/../" >> "$CRIAS_TEMPS_FILE"
if _crias_temp_path_allowed "/tmp/crias.x/../"; then
    echo "FAIL: traversal hidden in a mktemp-looking name" >&2; exit 1
fi
if _crias_temp_path_allowed "$foreign"; then
    echo "FAIL: foreign directory accepted for temp cleanup" >&2; exit 1
fi
_crias_cleanup_temps
[ -f "$forged" ] && [ -d "$foreign" ]
[ -L "$second" ] || { echo "FAIL: symlink unexpectedly followed/removed" >&2; exit 1; }
rm -f -- "$second"
[ ! -e "$secret" ]
[ ! -e "$CRIAS_TEMPS_FILE" ]

# The secure snapshot directory must use the registry-backed helper.
grep -Fq 'STACK_SNAPSHOT_DIR="$(mktemp_crias_dir)"' "$root/shared/lib/stack-installer.sh"
grep -Fq '_crias_register_temp "$unit_tmp"' "$root/shared/lib/stack-installer.sh"

echo "OK: private registry, strict cleanup allowlist, no traversal and snapshot registration"
