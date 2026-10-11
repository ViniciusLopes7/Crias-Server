#!/bin/bash
# tests/tui-fallback-test.sh
#
# Testa shared/lib/tui.sh no caminho de FALLBACK (sem gum), que e o que roda
# em CI/sandbox sem TTY real. Valida que:
#   - tui_available() retorna falso (sem gum).
#   - tui_choose atribui default em EOF.
#   - tui_confirm retorna o default em EOF (Y -> 0, N -> 1).
#   - tui_input atribui default em EOF.
#   - tui_checklist atribui defaults em EOF.
#   - tui_filter retorna nao-zero em EOF (lista cancelada).
#
# NAO testa o caminho gum REAL (precisa de TTY interativo + gum instalado);
# esse caminho e validado manualmente em live ISO/PTY. O caminho gum em SI e
# exercitado com um FAKE gum deterministico (secao 8), que cobre a logica de
# atribuicao printf -v sem depender de TTY.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/tui.sh"

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1" >&2
    [ -n "${2:-}" ] && echo "       expected: $2" >&2
    [ -n "${3:-}" ] && echo "       got:      $3" >&2
    FAIL=$((FAIL + 1))
}

echo "[tui-fallback-test] Testando caminho de fallback (sem gum)..."

# --- 0. Engine detection ---
echo "- Deteccao de engine:"
if ! tui_available; then
    pass "tui_available() = false (sem gum, esperado no sandbox/CI)"
else
    fail "tui_available deveria ser false sem gum"
fi
engine=$(_tui_engine)
if [ "$engine" = "read" ]; then
    pass "engine = read (fallback)"
else
    fail "engine" "read" "$engine"
fi

# --- 1. tui_choose: EOF -> default ---
echo "- tui_choose em EOF:"
result=""
tui_choose result "Escolha" "alpha" "alpha" "beta" "gamma" </dev/null >/dev/null 2>&1 || true
if [ "$result" = "alpha" ]; then
    pass "default 'alpha' atribuido em EOF"
else
    fail "tui_choose EOF default" "alpha" "$result"
fi

# default diferente do primeiro.
result=""
tui_choose result "Escolha" "gamma" "alpha" "beta" "gamma" </dev/null >/dev/null 2>&1 || true
if [ "$result" = "gamma" ]; then
    pass "default 'gamma' (nao-primeiro) atribuido em EOF"
else
    fail "tui_choose EOF default gamma" "gamma" "$result"
fi

# --- 2. tui_confirm: EOF ---
echo "- tui_confirm em EOF:"
# default Y -> retorna 0 (yes).
rc=0
tui_confirm "Confirma?" "Y" </dev/null >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "default Y -> yes (rc=0)"
else
    fail "tui_confirm default Y" "0" "$rc"
fi

# default N -> retorna 1 (no).
rc=0
tui_confirm "Confirma?" "N" </dev/null >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
    pass "default N -> no (rc=1)"
else
    fail "tui_confirm default N" "1" "$rc"
fi

# --- 3. tui_input: EOF -> default ---
echo "- tui_input em EOF:"
val=""
tui_input val "Digite algo" "meu-default" </dev/null >/dev/null 2>&1 || true
if [ "$val" = "meu-default" ]; then
    pass "default 'meu-default' atribuido em EOF"
else
    fail "tui_input EOF default" "meu-default" "$val"
fi

# default vazio.
val="preset"
tui_input val "Digite" "" </dev/null >/dev/null 2>&1 || true
if [ "$val" = "" ]; then
    pass "default vazio atribuido em EOF"
else
    fail "tui_input EOF empty default" "" "$val"
fi

# --- 4. tui_checklist: EOF -> defaults ---
echo "- tui_checklist em EOF:"
csv=""
tui_checklist csv "Selecione extras" "beta" "alpha" "beta" "gamma" </dev/null >/dev/null 2>&1 || true
if [ "$csv" = "beta" ]; then
    pass "default CSV 'beta' atribuido em EOF"
else
    fail "tui_checklist EOF default" "beta" "$csv"
fi

# defaults multiplos.
csv=""
tui_checklist csv "Selecione" "alpha,gamma" "alpha" "beta" "gamma" </dev/null >/dev/null 2>&1 || true
if [ "$csv" = "alpha,gamma" ]; then
    pass "default CSV 'alpha,gamma' (multiplos) atribuido em EOF"
else
    fail "tui_checklist EOF multi default" "alpha,gamma" "$csv"
fi

# --- 5. tui_filter: EOF -> nao-zero ---
echo "- tui_filter em EOF:"
if printf 'a\nb\nc\n' | tui_filter "busca" >/dev/null 2>&1; then
    fail "tui_filter deveria falhar em EOF (sem selecao)"
else
    pass "tui_filter retorna nao-zero em EOF"
fi

# lista vazia -> nao-zero.
if printf '' | tui_filter "busca" >/dev/null 2>&1; then
    fail "tui_filter com lista vazia deveria falhar"
else
    pass "tui_filter com lista vazia -> nao-zero"
fi

# --- 6. tui_choose: input via stdin numerico (fallback path) ---
echo "- tui_choose com input numerado (simula usuario digitando):"
# Aqui simulamos um usuario que digita "2" e Enter.
result=""
# shellcheck disable=SC2154  # r é atribuída via printf -v dentro de tui_choose
result=$(printf '2\n' | { tui_choose r "Escolha" "alpha" "alpha" "beta" "gamma" >&2; echo "$r"; } 2>/dev/null || true)
if [ "$result" = "beta" ]; then
    pass "selecao numerada '2' -> beta"
else
    fail "tui_choose numerado" "beta" "$result"
fi

# --- 6b. tui_choose: input INVALIDO (numero fora da faixa) -> default ---
echo "- tui_choose com input invalido (numero fora da faixa):"
# Input "99" (fora da faixa) deve cair no default, nao ser atribuido como valor.
result=""
result=$(printf '99\n' | { tui_choose r "Escolha" "alpha" "alpha" "beta" "gamma" >&2; echo "$r"; } 2>/dev/null || true)
if [ "$result" = "alpha" ]; then
    pass "input '99' (fora da faixa) -> default 'alpha'"
else
    fail "tui_choose input invalido 99" "alpha" "$result"
fi

# --- 6c. tui_choose: input INVALIDO (texto nao-listado) -> default ---
echo "- tui_choose com input invalido (texto nao-listado):"
result=""
result=$(printf 'nao-existe\n' | { tui_choose r "Escolha" "alpha" "alpha" "beta" "gamma" >&2; echo "$r"; } 2>/dev/null || true)
if [ "$result" = "alpha" ]; then
    pass "input 'nao-existe' (nao-listado) -> default 'alpha'"
else
    fail "tui_choose input texto invalido" "alpha" "$result"
fi

# --- 6d. tui_choose: input texto valido (match exato com opcao) ---
echo "- tui_choose com input texto (match exato):"
result=""
result=$(printf 'gamma\n' | { tui_choose r "Escolha" "alpha" "alpha" "beta" "gamma" >&2; echo "$r"; } 2>/dev/null || true)
if [ "$result" = "gamma" ]; then
    pass "input 'gamma' (match exato) -> gamma"
else
    fail "tui_choose texto match" "gamma" "$result"
fi

# --- 7. Checklist fallback com opções multi-palavra (catálogo tModLoader) ---
echo "- tui_checklist fallback com opções multi-palavra (toggle + confirmar):"
# O catálogo real do tModLoader tem nomes com espaço ("Calamity Mod"); o toggle
# numerado precisa marcar/desmarcar corretamente e o resultado sair na ordem
# das opções (aqui: só "Calamity Mod", marcada via input '1' e confirmada com '0').
result=""
result=$(printf '1\n0\n' | { tui_checklist csv "Selecione mods" "" "Calamity Mod" "Thorium Mod" >&2; echo "$csv"; } 2>/dev/null || true)
if [ "$result" = "Calamity Mod" ]; then
    pass "tui_checklist multi-palavra (toggle 1 + confirmar 0) -> 'Calamity Mod'"
else
    fail "tui_checklist multi-palavra" "Calamity Mod" "$result"
fi

# --- 8. Caminho gum (fake gum): shadowing de variável-alvo do caller ---
# Regressão v1.2.1: `local selected_csv` interno do tui_checklist sombreava a
# var-alvo do caller; o printf -v escrevia na cópia interna (morta no return) e
# o caller via "unbound variable" na linha seguinte (install.sh:620). Força-se
# o caminho gum com um fake gum determinístico; as out-vars usam de propósito
# os nomes que colidiam com as internas antigas (selected_csv/choice/value).
echo "- tui_* caminho gum (fake gum) com out-vars que colidiam com internas:"
FAKE_GUM_DIR="$(mktemp -d)"
cat > "$FAKE_GUM_DIR/gum" <<'GUMEOF'
#!/bin/bash
# Fake gum: printa seleções fixas no stdout (exit 0).
case "$1" in
    choose)
        if [ "$2" = "--no-limit" ]; then
            printf 'Calamity Mod\nThorium Mod\n'
        else
            printf 'beta\n'
        fi
        ;;
    input)
        printf 'valor-digitado\n'
        ;;
    *)
        printf '\n'
        ;;
esac
exit 0
GUMEOF
chmod +x "$FAKE_GUM_DIR/gum"

_TUI_AVAILABLE_ORIG="$(declare -f tui_available)"
tui_available() { return 0; }
PATH="$FAKE_GUM_DIR:$PATH"

selected_csv=""
tui_checklist selected_csv "Selecione os mods" "" "Calamity Mod" "Thorium Mod" "Magic Storage" >/dev/null 2>&1
if [ "${selected_csv:-UNSET}" = "Calamity Mod,Thorium Mod" ]; then
    pass "tui_checklist (gum) atribui out-var 'selected_csv' (ex-shadowing)"
else
    fail "tui_checklist (gum) selected_csv" "Calamity Mod,Thorium Mod" "${selected_csv:-UNSET}"
fi

choice=""
tui_choose choice "Escolha" "alpha" "alpha" "beta" "gamma" >/dev/null 2>&1
if [ "${choice:-UNSET}" = "beta" ]; then
    pass "tui_choose (gum) atribui out-var 'choice' (ex-interna)"
else
    fail "tui_choose (gum) choice" "beta" "${choice:-UNSET}"
fi

value=""
tui_input value "Digite algo" "meu-default" >/dev/null 2>&1
if [ "${value:-UNSET}" = "valor-digitado" ]; then
    pass "tui_input (gum) atribui out-var 'value' (ex-interna)"
else
    fail "tui_input (gum) value" "valor-digitado" "${value:-UNSET}"
fi

# Restaura engine real e PATH.
eval "$_TUI_AVAILABLE_ORIG"
PATH="${PATH#"$FAKE_GUM_DIR:"}"
rm -rf "$FAKE_GUM_DIR"

echo ""
echo "[tui-fallback-test] PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
