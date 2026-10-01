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
# Match apenas `tar` como COMANDO (precedido por start de linha ou whitespace, não por `.`).
# Isso evita falso positivo em paths como `image.tar` ou `file.tar.gz`.
# Pattern: (start ou whitespace) + tar + espaço + args + 2>/dev/null
bad_tar=$(grep -RInE "${scan_excludes[@]}" --exclude-dir=tests "(^|[[:space:]])tar [^#]*2>/dev/null" . || true)
if [ -n "$bad_tar" ]; then
  echo "ERROR: Found tar commands redirecting stderr to /dev/null:" >&2
  printf "%s\n" "$bad_tar" >&2
  errors=$((errors+1))
fi

echo "Checking for ionice+tar with stderr redirection..."
bad_ionice=$(grep -RInE "${scan_excludes[@]}" --exclude-dir=tests "(^|[[:space:]])ionice\b[^#]*\btar\b[^#]*2>/dev/null" . || true)
if [ -n "$bad_ionice" ]; then
  echo "ERROR: Found ionice+tar redirecting stderr to /dev/null:" >&2
  printf "%s\n" "$bad_ionice" >&2
  errors=$((errors+1))
fi

echo "Checking bootstrap uses curl+release download (not git clone as primary)..."
# O bootstrap deve baixar da release do GitHub via curl, não clonar o repo.
# git clone só é aceito em mensagens de fallback (comentadas ou em strings de erro).
bootstrap_src="crias-bootstrap.sh"
if [ -f "$bootstrap_src" ]; then
  # Conta ocorrências de git clone fora de contexto de fallback (strings/mensagens).
  git_clone_count=$(grep -cE '^[[:space:]]*git clone' "$bootstrap_src" || true)
  if [ "$git_clone_count" -gt 0 ]; then
    echo "Note: crias-bootstrap.sh contém 'git clone' como comando ativo — preferir curl+release download." >&2
  fi
fi

if [ "$errors" -ne 0 ]; then
  echo "Static audit found issues (errors=$errors)." >&2
  exit 1
fi

echo "Static audit passed."
exit 0
