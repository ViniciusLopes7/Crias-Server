#!/bin/bash
set -euo pipefail

echo "Running static audit checks..."
errors=0

echo "Checking for curl downloads without timeouts (only flagging -o/-O usage)..."
bad_curls=$(grep -RIn "curl [^\n]* -o\|curl [^\n]* -O" --exclude-dir=.git --exclude-dir=docs --exclude-dir=assets || true)
if [ -n "$bad_curls" ]; then
  # Filter out lines that include explicit timeouts
  filtered=$(printf "%s" "$bad_curls" | grep -v -- "--connect-timeout" | grep -v -- "--max-time" || true)
  if [ -n "$filtered" ]; then
    echo "ERROR: Found curl downloads without timeouts:" >&2
    printf "%s\n" "$filtered" >&2
    errors=$((errors+1))
  fi
fi

echo "Checking for tar commands with stderr suppressed to /dev/null..."
bad_tar=$(grep -RIn "tar .*2>/dev/null" --exclude-dir=.git --exclude-dir=docs --exclude-dir=assets || true)
if [ -n "$bad_tar" ]; then
  echo "ERROR: Found tar commands redirecting stderr to /dev/null:" >&2
  printf "%s\n" "$bad_tar" >&2
  errors=$((errors+1))
fi

echo "Checking for ionice+tar with stderr redirection..."
bad_ionice=$(grep -RIn "ionice .*tar .*2>/dev/null" --exclude-dir=.git --exclude-dir=docs --exclude-dir=assets || true)
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
