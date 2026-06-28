#!/bin/bash
set -euo pipefail

echo "Running static audit checks..."
errors=0
scan_excludes=(--exclude-dir=.git --exclude-dir=docs --exclude-dir=assets)

echo "Checking for curl downloads without timeouts (only flagging -o/-O usage)..."
bad_curls=$(grep -RInE "${scan_excludes[@]}" "^[[:space:]]*[^#]*\bcurl\b[^#]*[[:space:]]-(o|O)([[:space:]]|$)" . || true)
if [ -n "$bad_curls" ]; then
  # Filter out lines that include explicit timeouts
  filtered=$(printf "%s\n" "$bad_curls" | grep -v -- "--connect-timeout" | grep -v -- "--max-time" || true)
  if [ -n "$filtered" ]; then
    echo "ERROR: Found curl downloads without timeouts:" >&2
    printf "%s\n" "$filtered" >&2
    errors=$((errors+1))
  fi
fi

echo "Checking for tar commands with stderr suppressed to /dev/null..."
# Match only tar invocations (not URLs containing .tar.gz in arguments of other commands).
# Pattern: line starts with optional whitespace, then `tar ` (with trailing space) as command,
# followed by anything, then `2>/dev/null`.
bad_tar=$(grep -RInE "${scan_excludes[@]}" --exclude-dir=tests "^[[:space:]]*[^#]*\btar [^#]*2>/dev/null" . || true)
if [ -n "$bad_tar" ]; then
  echo "ERROR: Found tar commands redirecting stderr to /dev/null:" >&2
  printf "%s\n" "$bad_tar" >&2
  errors=$((errors+1))
fi

echo "Checking for ionice+tar with stderr redirection..."
bad_ionice=$(grep -RInE "${scan_excludes[@]}" --exclude-dir=tests "^[[:space:]]*[^#]*\bionice\b[^#]*\btar\b[^#]*2>/dev/null" . || true)
if [ -n "$bad_ionice" ]; then
  echo "ERROR: Found ionice+tar redirecting stderr to /dev/null:" >&2
  printf "%s\n" "$bad_ionice" >&2
  errors=$((errors+1))
fi

echo "Checking for presence of git clone in automated ISO bootstrap..."
if grep -qR "git clone" archiso-profile/airootfs/root/.automated_script.sh; then
  echo "Note: .automated_script.sh contains git clone — ensure ISO build includes signed installer or verify manually." >&2
fi

if [ "$errors" -ne 0 ]; then
  echo "Static audit found issues (errors=$errors)." >&2
  exit 1
fi

echo "Static audit passed."
exit 0
