#!/bin/bash
# tests/mutation-test.sh
#
# Mutation testing para shared/lib/tui.sh, shared/lib/mc-manifests.sh, e
# minecraft/install.sh. Aplica bugs deliberados e checa se os testes detectam.
#
# Usa python3 para aplicar mutações via arquivos temporários (heredoc com
# <<'PYEOF' evita interpolação do bash, suportando patterns com $, {}, () etc).
#
# Uso: bash tests/mutation-test.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERRO: python3 necessario para mutation testing." >&2
    exit 2
fi

KILLED=0
SURVIVED=0
SKIPPED=0
SURVIVED_MUTATIONS=()

# run_mutation <arquivo> <desc> <pattern> <replacement> <test_cmd> <esperado_passar>
# pattern e replacement sao lidos como HEREDOC (sem interpolação do bash).
run_mutation() {
    local file="$1"
    local desc="$2"
    local pattern="$3"
    local replacement="$4"
    local test_cmd="$5"
    local esperado_passar="${6:-0}"

    local abs_file="$ROOT_DIR/$file"
    if [ ! -f "$abs_file" ]; then
        echo "  SKIP (arquivo nao encontrado): $file"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    local bak="$abs_file.mutation-bak"
    cp -a "$abs_file" "$bak"

    # Aplica mutação via python. Usa str.replace (literal) em vez de re.sub
    # para evitar problemas de escaping de (, ), [, *, etc.
    # Converte \n (literal) em newline real dentro do python.
    python3 - "$abs_file" "$pattern" "$replacement" <<'PYEOF'
import sys
path, pattern, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
# Converte \n (literal de aspas simples do bash) em newline real.
pattern = pattern.replace('\\n', '\n')
replacement = replacement.replace('\\n', '\n')
with open(path, 'r') as f:
    content = f.read()
# str.replace faz match literal, sem regex.
idx = content.find(pattern)
if idx == -1:
    sys.exit(1)
new_content = content.replace(pattern, replacement, 1)
with open(path, 'w') as f:
    f.write(new_content)
sys.exit(0)
PYEOF
    local apply_rc=$?

    if [ "$apply_rc" -ne 0 ]; then
        echo "  SKIP (pattern nao casou): $desc"
        cp -a "$bak" "$abs_file"
        rm -f "$bak"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    # Sintaxe check.
    if ! bash -n "$abs_file" 2>/dev/null; then
        echo "  SKIP (mutacao quebrou sintaxe): $desc"
        cp -a "$bak" "$abs_file"
        rm -f "$bak"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    # Roda o teste.
    local test_log
    test_log="$(mktemp)"
    local test_rc=0
    bash -c "set -uo pipefail; $test_cmd" > "$test_log" 2>&1 || test_rc=$?

    # Restaura.
    cp -a "$bak" "$abs_file"
    rm -f "$bak" "$test_log"

    if [ "$esperado_passar" = "1" ]; then
        if [ "$test_rc" -eq 0 ]; then
            echo "  PASS (neutral sanity): $desc"
            KILLED=$((KILLED + 1))
        else
            echo "  FAIL (neutral quebrou teste - falso positivo!): $desc"
            SURVIVED=$((SURVIVED + 1))
            SURVIVED_MUTATIONS+=("$desc [NEUTRAL-FALSE-POS]")
        fi
        return 0
    fi

    if [ "$test_rc" -ne 0 ]; then
        echo "  KILLED: $desc"
        KILLED=$((KILLED + 1))
    else
        echo "  SURVIVED: $desc  <-- teste fraco, gap de cobertura"
        SURVIVED=$((SURVIVED + 1))
        SURVIVED_MUTATIONS+=("$desc")
    fi
}

echo "=== Mutation Testing — Crias-Server v1.2.0 ==="
echo ""

# Para evitar escaping, definimos patterns em variaveis com aspas simples.
# Dentro de aspas simples, bash NAO interpola $, {}, etc.

# ===========================================================================
# mc-manifests.sh mutations
# ===========================================================================
echo "--- mc-manifests.sh ---"

run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M1: mojang release->snapshot filter" \
    'select(.type == "release") | .id' \
    'select(.type == "snapshot") | .id' \
    "bash tests/mc-manifests-test.sh" \
    0

run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M2: fabric select(.stable) -> select(.stable | not)" \
    'select(.stable) | .version' \
    'select(.stable | not) | .version' \
    "bash tests/mc-manifests-test.sh" \
    0

# M3: mesma-minor head -1 -> tail -1 (2a ocorrencia; a 1a e match exato, insensivel)
run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M3: suggest same-minor head -1 -> tail -1" \
    'grep -E "^${w_major}\.${w_minor}\." | head -1' \
    'grep -E "^${w_major}\.${w_minor}\." | tail -1' \
    "bash tests/mc-manifests-test.sh" \
    0

# M4: remove fallback versions[0]
run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M4: suggest remove fallback versions[0]" \
    '    # 4. Fallback: primeira da lista (mais recente).
    printf '"'"'%s\n'"'"' "${versions[0]}"' \
    '    # 4. Fallback MUTATED (return 0 = nada).
    return 0' \
    "bash tests/mc-manifests-test.sh" \
    0

run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M5: neoforge -ge 20 -> -gt 20" \
    '[[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 20 ]' \
    '[[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -gt 20 ]' \
    "bash tests/mc-manifests-test.sh" \
    0

run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M6: forge mc_ver line%%-* -> line%%.*" \
    'mc_ver="${line%%-*}"' \
    'mc_ver="${line%%.*}"' \
    "bash tests/mc-manifests-test.sh" \
    0

# M7: extract_slug (1a ocorrencia do printf com ${line%% *})
run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M7: extract_slug %% * -> ## *" \
    'printf '"'"'%s'"'"' "${line%% *}" | tr -d '"'"'[:space:]'"'"'' \
    'printf '"'"'%s'"'"' "${line##* }" | tr -d '"'"'[:space:]'"'"'' \
    "bash tests/mc-manifests-test.sh" \
    0

run_mutation \
    "shared/lib/mc-manifests.sh" \
    "M8-neutral: troca comentario" \
    '# Biblioteca para busca' \
    '# MOD Biblioteca para busca' \
    "bash tests/mc-manifests-test.sh" \
    1

# ===========================================================================
# tui.sh mutations
# ===========================================================================
echo ""
echo "--- tui.sh ---"

# M10: tui_choose fallback deve validar input contra lista.
# Mutacao: remover o loop de validacao (atribui input direto sem checar).
run_mutation \
    "shared/lib/tui.sh" \
    "M10: tui_choose remove validacao de input contra lista (regressao)" \
    '    # Se digitou texto, valida que corresponde a uma das opções (match exato).
    local opt
    for opt in "${options[@]}"; do
        if [ "$opt" = "$answer" ]; then
            printf -v "$var_out" '"'"'%s'"'"' "$answer"
            return 0
        fi
    done
    # Input invalido (numero fora da faixa ou texto nao-listado): usa default.
    print_warning "Opcao invalida: '"'"'$answer'"'"'. Usando default: '"'"'$default'"'"'"
    printf -v "$var_out" '"'"'%s'"'"' "$default"' \
    '    # MUTATED: atribui input sem validar (regressao).
    printf -v "$var_out" '"'"'%s'"'"' "$answer"' \
    "bash tests/tui-fallback-test.sh" \
    0

# M11: tui_confirm inverte retorno em EOF (Y->1)
run_mutation \
    "shared/lib/tui.sh" \
    "M11: tui_confirm EOF inverte default Y->return 1" \
    '        # EOF/SIGINT: honra o default (paridade com tui_input/tui_choose).
        if [ "${default_ans^^}" = "Y" ]; then
            return 0
        fi
        return 1' \
    '        # EOF/SIGINT MUTATED (inverte).
        if [ "${default_ans^^}" = "Y" ]; then
            return 1
        fi
        return 0' \
    "bash tests/tui-fallback-test.sh" \
    0

# M12: tui_input remove pre-set do default.
# NOTA: o ask_value (common.sh) ATRIBUI o default em EOF (via if [ -z "$answer" ]),
# entao o pre-set do tui_input e REDUNDANTE (defesa em profundidade). Esta mutacao
# nao muda comportamento observavel — marcada como esperada sobreviver.
run_mutation \
    "shared/lib/tui.sh" \
    "M12: tui_input remove printf -v default pre-set (redundante)" \
    '    printf -v "$var_out" '"'"'%s'"'"' "$default"
    ask_value "$prompt" "$default" "$var_out" || true' \
    '    ask_value "$prompt" "$default" "$var_out" || true' \
    "bash tests/tui-fallback-test.sh" \
    1

# ===========================================================================
# minecraft/install.sh mutations
# ===========================================================================
echo ""
echo "--- minecraft/install.sh ---"

run_mutation \
    "minecraft/install.sh" \
    "M13: re-adiciona paper aos loaders aceitos" \
    'fabric|quilt|vanilla|forge|neoforge)' \
    'fabric|quilt|paper|vanilla|forge|neoforge)' \
    "bash tests/install-contracts.sh" \
    0

# ===========================================================================
# Resumo
# ===========================================================================
echo ""
echo "=== Resumo do Mutation Testing ==="
echo "  KILLED (teste detectou o bug):    $KILLED"
echo "  SURVIVED (teste NAO detectou):     $SURVIVED"
echo "  SKIPPED (mutacao nao aplicou):     $SKIPPED"
echo ""

if [ "${#SURVIVED_MUTATIONS[@]}" -gt 0 ]; then
    echo "Mutations que SOBREVIVERAM (testes fracos — gaps de cobertura):"
    for m in "${SURVIVED_MUTATIONS[@]}"; do
        echo "  - $m"
    done
    echo ""
fi

if [ "$SURVIVED" -gt 0 ]; then
    exit 1
fi
exit 0
