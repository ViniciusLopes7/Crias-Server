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
# git clone só é aceito em mensagens de fallback (comentadas ou em strings de erros).
bootstrap_src="crias-bootstrap.sh"
if [ -f "$bootstrap_src" ]; then
  # Conta ocorrências de git clone fora de contexto de fallback (strings/mensagens).
  git_clone_count=$(grep -cE '^[[:space:]]*git clone' "$bootstrap_src" || true)
  if [ "$git_clone_count" -gt 0 ]; then
    echo "Note: crias-bootstrap.sh contém 'git clone' como comando ativo — preferir curl+release download." >&2
  fi
fi

echo "Checking for gum interactive commands with 2>/dev/null (suppresses TUI)..."
# gum choose/confirm/input/filter escrevem o TUI em stderr via tea.WithOutput(os.Stderr)
# (ver https://github.com/charmbracelet/gum blob/main/choose/command.go linha ~150).
# Redirecionar stderr para /dev/null mata o TUI: o script aparenta travar, e
# Ctrl+C dispara o ERR trap. Bug histórico curado em F9-TUI-fix; este check
# previne re-introdução. Não cobre gum style/spin (não usam bubbletea TUI).
# Perl -0777 lê arquivo inteiro; [^;)|&] matcha newlines em character class.
if command -v perl >/dev/null 2>&1; then
  bad_gum=""
  scan_files=$(find . -name "*.sh" \
      -not -path "./.git/*" \
      -not -path "./docs/*" \
      -not -path "./tests/*" \
      -not -path "./node_modules/*" 2>/dev/null || true)
  for f in $scan_files; do
    [ -f "$f" ] || continue
    out=$(perl -0777 -ne '
      while (/gum[[:space:]]+(choose|confirm|input|filter)\b[^;)|&]*?2>\/dev\/null/gs) {
        print "$ARGV: gum $1 ... 2>/dev/null (suprime TUI)\n";
      }
    ' "$f" 2>/dev/null || true)
    [ -n "$out" ] && bad_gum="$bad_gum$out"
  done
  if [ -n "$bad_gum" ]; then
    echo "ERROR: Found gum interactive commands with 2>/dev/null (suppresses TUI):" >&2
    printf "%s\n" "$bad_gum" >&2
    errors=$((errors+1))
  fi
else
  echo "Note: perl não disponível, pulando verificação de gum 2>/dev/null." >&2
fi

if [ "$errors" -ne 0 ]; then
  echo "Static audit found issues (errors=$errors)." >&2
  exit 1
fi

echo "Static audit passed."
exit 0
