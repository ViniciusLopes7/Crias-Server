#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/shared/lib/config-parser.sh"

# Renomeado de TMPDIR para TEST_TMPDIR para não sobrescrever a variável de
# ambiente global $TMPDIR (que subprocessos consultam).
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMPDIR" || true' EXIT
CFG="$TEST_TMPDIR/test.env"

cat > "$CFG" <<'EOF'
# normal
GOOD_VAL=hello
QUOTE_VAL="a b c"
# malicious attempts
MALICIOUS=$(touch "$TEST_TMPDIR/pwned")
BACKTICK=`touch "$TEST_TMPDIR/pwn2"`
SHELL_EXP="$(echo pwn3)"
EMPTY_LINE=
INVALID LINE
EOF

# Ensure no pwn files exist before
if [ -e "$TEST_TMPDIR/pwned" ] || [ -e "$TEST_TMPDIR/pwn2" ] || [ -e "$TEST_TMPDIR/pwn3" ]; then
  echo "Precondition failed: pwn files already exist"
  exit 2
fi

# Call parser
load_config_file "$CFG"

# Validate values
if [ "${GOOD_VAL:-}" != "hello" ]; then
  echo "FAIL: GOOD_VAL wrong: ${GOOD_VAL:-}"
  exit 1
fi

if [ "${QUOTE_VAL:-}" != "a b c" ]; then
  echo "FAIL: QUOTE_VAL wrong: ${QUOTE_VAL:-}"
  exit 1
fi

# Ensure malicious commands did not run
if [ -e "$TEST_TMPDIR/pwned" ] || [ -e "$TEST_TMPDIR/pwn2" ] || [ -e "$TEST_TMPDIR/pwn3" ]; then
  echo "FAIL: malicious command substitution executed"
  ls -la $TEST_TMPDIR
  exit 1
fi

# Validate that invalid line was ignored
# There's no direct var to check; success if we reach here

echo "OK: config-parser"
