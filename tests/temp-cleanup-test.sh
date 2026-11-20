#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
# An inherited or predictable registry path must not be reused.
forged="$tmp/crias-temps.$$"
printf 'do-not-touch\n' > "$forged"
export CRIAS_TEMPS_FILE="$forged"
# shellcheck source=/dev/null
source "$root/shared/lib/common.sh"
[ "$CRIAS_TEMPS_FILE" != "$forged" ]
[ "$(cat "$forged")" = do-not-touch ]
[ -f "$CRIAS_TEMPS_FILE" ]
[ "$(stat -c %a "$CRIAS_TEMPS_FILE")" = 600 ]
first=$(mktemp_crias_dir)
printf data > "$first/data"
remove_crias_temp_dir "$first"
[ ! -e "$first" ] || { echo 'FAIL: registered directory remains' >&2; exit 1; }
foreign="$tmp/crias.abcdef"
mkdir "$foreign"
if remove_crias_temp_dir "$foreign" >/dev/null 2>&1; then echo 'FAIL: unregistered directory removed' >&2; exit 1; fi
[ -d "$foreign" ]
second=$(mktemp_crias_dir)
rmdir "$second"
ln -s "$foreign" "$second"
if remove_crias_temp_dir "$second" >/dev/null 2>&1; then echo 'FAIL: symlink accepted' >&2; exit 1; fi
[ -d "$foreign" ]
_crias_cleanup_temps
[ ! -e "$CRIAS_TEMPS_FILE" ]
echo 'OK: private registry and safe temporary directory removal'
