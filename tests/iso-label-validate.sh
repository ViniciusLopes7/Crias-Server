#!/usr/bin/env bash
# tests/iso-label-validate.sh
#
# Valida o iso_label definido em archiso-profile/profiledef.sh.
#
# Regras validadas (ISO 9660 / FAT label constraints):
#   1. iso_label deve ter no máximo 11 caracteres (limite do ISO 9660 / FAT).
#   2. iso_label deve conter apenas letras A-Z e dígitos 0-9 (uppercase ASCII).
#   3. O valor aqui computado deve bater com o iso_label real do profiledef.sh.
#
# Referências:
#   - https://wiki.archlinux.org/title/Archiso#Required_files
#   - https://en.wikipedia.org/wiki/ISO_9660#Volume_descriptor_set
#
# TST-001: antes este teste era placebo — apenas truncava para 11 chars e
# sempre dava PASS, mesmo se iso_label contivesse caracteres inválidos ou
# fosse maior que o limite. Agora faz 3 assertions reais.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

profile="$PROJECT_ROOT/archiso-profile/profiledef.sh"

if [ ! -f "$profile" ]; then
    echo "FAIL: profiledef.sh não encontrado em $profile" >&2
    exit 1
fi

# Extrai iso_label do profiledef.sh de forma isolada (sem herdar ambiente).
# profiledef.sh usa `declare -A file_permissions=()` antes de ser sourceado
# em mkarchiso; precisamos declarar antes para que a sintaxe ["/x"]="0:0:755"
# funcione em bash 5.2+.
iso_label="$(bash -c "declare -A file_permissions; source '$profile' && printf '%s' \"\$iso_label\"" 2>/dev/null || true)"

if [ -z "$iso_label" ]; then
    echo "FAIL: não foi possível extrair iso_label do profiledef.sh" >&2
    exit 1
fi

# Assertion 1: máximo 11 caracteres (ISO 9660 / FAT label limit).
if [ "${#iso_label}" -gt 11 ]; then
    echo "FAIL: iso_label '$iso_label' tem ${#iso_label} caracteres (máx 11)" >&2
    exit 1
fi

# Assertion 2: apenas letras A-Z e dígitos 0-9 (uppercase ASCII).
# Não permite lowercase, espaços, hífens, underscores ou pontuação.
if ! printf '%s' "$iso_label" | grep -qE '^[A-Z0-9]+$'; then
    echo "FAIL: iso_label '$iso_label' contém caracteres inválidos (apenas A-Z0-9 permitido)" >&2
    exit 1
fi

# Assertion 3: recompute local deve bater com o valor do profiledef.sh.
# Reproduz a lógica do profiledef.sh para garantir que o teste não dá falso
# positivo se o profiledef.sh for modificado para usar outro esquema.
git_short=""
if command -v git >/dev/null 2>&1; then
    git_short="$(git -C "$PROJECT_ROOT" rev-parse --short=6 HEAD 2>/dev/null || true)"
fi

if [ -n "$git_short" ]; then
    prefix="$(printf '%.5s' "$git_short" | tr '[:lower:]' '[:upper:]')"
    expected_label="CRIAS${prefix}"
else
    expected_label="CRIAS00000"
fi
expected_label="${expected_label:0:11}"

if [ "$iso_label" != "$expected_label" ]; then
    echo "FAIL: iso_label '$iso_label' diverge do esperado '$expected_label'" >&2
    echo "     (recompute local não bate com profiledef.sh — bug em iso_label?)" >&2
    exit 1
fi

echo "PASS: iso_label '$iso_label' válido (comprimento=${#iso_label}, charset=A-Z0-9, bate com profiledef.sh)"
