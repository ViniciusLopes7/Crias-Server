#!/usr/bin/env bash
# tests/manager-safety-test.sh
#
# Contraprovas da fronteira root x jogo (EXP-33/EXP-34):
#   1. manager_path_is_root_safe: só root:root sem escrita g+w/o+w é seguro;
#   2. O gerador de aliases do install.sh NUNCA produz `source` de caminhos
#      dentro do diretório do jogo (o perfil global carrega em shells de
#      login administrativos);
#   3. Os aliases apontam para /usr/local/libexec/crias (root:root), não
#      para o diretório gravável pelo jogo;
#   4. Managers resolvem libs do libexec primeiro;
#   5. O deploy do installer remove as cópias legadas do game dir.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/manager-common.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR" || true' EXIT

fail_count=0

# ------------------------------------------------------------------
# 1. manager_path_is_root_safe (unit test da guarda EXP-34).
# ------------------------------------------------------------------
current_user="$(id -un)"

make_file() {
    local path="$1" owner="$2" perms="$3"
    echo "# stub" > "$path"
    chown "$owner" "$path" 2>/dev/null || true
    chmod "$perms" "$path"
}

# root:root 0644 => seguro (quando rodando como root; se nao-root, o chown
# falha e o dono nao e root => inseguro — testa AMBOS os ramos).
f_root_safe="$TMP_DIR/root_safe.sh"
make_file "$f_root_safe" "root:root" 0644 2>/dev/null || true
f_root_gw="$TMP_DIR/root_gw.sh"
make_file "$f_root_gw" "root:root" 0664 2>/dev/null || true
# A execução root precisa testar um arquivo realmente pertencente a não-root.
# Antes, current_user=root tornava o fixture root:root e gerava falso FAIL.
nonroot_owner="$current_user"
if [ "$(id -u)" -eq 0 ]; then
    if id -u nobody >/dev/null 2>&1; then
        nonroot_owner="nobody"
    else
        echo "FAIL: falta usuario nao-root para fixture de seguranca" >&2
        exit 1
    fi
fi
f_user="$TMP_DIR/user_owned.sh"
make_file "$f_user" "$nonroot_owner:" 0644
if [ "$(stat -c '%U' "$f_user")" = root ]; then
    echo "FAIL: fixture usuario nao-root permaneceu root-owned" >&2
    exit 1
fi

actual_owner="$(stat -c '%U' "$f_root_safe")"
if [ "$actual_owner" = "root" ]; then
    if manager_path_is_root_safe "$f_root_safe"; then
        echo "OK: root:root 0644 = seguro"
    else
        echo "FAIL: root:root 0644 deveria ser seguro (EXP-34)"
        fail_count=$((fail_count + 1))
    fi
    if manager_path_is_root_safe "$f_root_gw"; then
        echo "FAIL: root:root 0664 (group-writable) deveria ser INSEGURO (EXP-34)"
        fail_count=$((fail_count + 1))
    else
        echo "OK: root:root 0664 = inseguro"
    fi
else
    # Sem root no ambiente de teste: valida apenas o ramo dono != root.
    echo "SKIP: rodando sem root — caso root:root validado apenas por inspeção"
fi

if manager_path_is_root_safe "$f_user"; then
    echo "FAIL: arquivo de não-root deveria ser INSEGURO para execução como root (EXP-34)"
    fail_count=$((fail_count + 1))
else
    echo "OK: dono não-root = inseguro"
fi

if manager_path_is_root_safe "$TMP_DIR/arquivo-que-nao-existe"; then
    echo "FAIL: path inexistente deveria ser inseguro (stat falha)"
    fail_count=$((fail_count + 1))
else
    echo "OK: path inexistente = inseguro (fail-closed)"
fi

# ------------------------------------------------------------------
# 2. Gerador de aliases do install.sh: nada de source do game dir (EXP-33).
# ------------------------------------------------------------------
# Extrai as funções de perfil do install.sh em um subshell isolado.
(
    export SERVER_TYPE="minecraft"
    export MINECRAFT_SERVER_DIR="/opt/minecraft-server"
    export TERRARIA_SERVER_DIR="/opt/terraria-server"

    # Source SOMENTE as funções necessárias: captura o bloco de perfil.
    sed -n '/^CRIAS_PROFILE_BLOCK_BEGIN=/,/^strip_legacy_alias_source_lines()/p' "$ROOT_DIR/install.sh" > "$TMP_DIR/profile_funcs.sh"

    # stubs das dependencias das funcoes extraidas
    is_true() { case "$1" in 1|true|yes|y|sim|s|on|enabled) return 0;; *) return 1;; esac; }
    print_step() { :; }
    print_success() { :; }
    print_warning() { :; }
    print_error() { :; }
    mkdir() { command mkdir "$@"; }
    chmod() { command chmod "$@"; }
    chown() { :; }
    mktemp_crias_file() { mktemp; }
    grep() { command grep "$@"; }
    awk() { command awk "$@"; }
    printf() { command printf "$@"; }
    cat() { command cat "$@"; }

    # shellcheck source=/dev/null
    source "$TMP_DIR/profile_funcs.sh" 2>/dev/null || true

    if ! declare -F stack_profile_alias_lines >/dev/null 2>&1; then
        echo "FAIL: stack_profile_alias_lines não extraível do install.sh"
        exit 1
    fi

    aliases="$(stack_profile_alias_lines)"

    # CONTRATO EXP-33: nenhum alias pode dar source/executar algo do game dir.
    if printf '%s\n' "$aliases" | grep -E "source|\\.[[:space:]]|comandos\.sh" | grep -v '^\s*#'; then
        echo "FAIL: aliases do perfil referenciam source/comandos.sh (EXP-33)"
        exit 1
    fi

    # Todos os aliases de manager apontam para o libexec.
    if printf '%s\n' "$aliases" | grep 'manager.sh' | grep -vq '/usr/local/libexec/crias/'; then
        echo "FAIL: alias de manager fora do libexec (EXP-34)"
        exit 1
    fi

    echo "aliases-mc-ok"
    export SERVER_TYPE="terraria"
    aliases_tt="$(stack_profile_alias_lines)"
    if printf '%s\n' "$aliases_tt" | grep 'manager.sh' | grep -vq '/usr/local/libexec/crias/'; then
        echo "FAIL: alias tt-manager fora do libexec (EXP-34)"
        exit 1
    fi
    echo "aliases-tt-ok"
) || fail_count=$((fail_count + 1))

# ------------------------------------------------------------------
# 3. Managers resolvem libs do libexec primeiro (EXP-34, estático).
# ------------------------------------------------------------------
for manager in minecraft/mc-manager.sh terraria/tt-manager.sh; do
    if ! grep -q 'CRIS_LIBEXEC_LIB_DIR="/usr/local/libexec/crias/lib"' "$ROOT_DIR/$manager"; then
        echo "FAIL: $manager não resolve libs do libexec (EXP-34)"
        fail_count=$((fail_count + 1))
    fi
    if ! grep -q 'manager_assert_root_safe' "$ROOT_DIR/$manager"; then
        echo "FAIL: $manager não aplica a guarda de ownership root (EXP-34)"
        fail_count=$((fail_count + 1))
    fi
done
echo "OK: managers resolvem libexec + guarda root"

# ------------------------------------------------------------------
# 4. Deploy do installer remove cópias legadas do game dir (EXP-34).
# ------------------------------------------------------------------
# (o rm no installer e multi-linha com continuacao; casa pelo trecho literal)
if ! grep -q 'rm -f "$STACK_SERVER_DIR/mc-manager.sh' "$ROOT_DIR/shared/lib/stack-installer.sh" \
    || ! grep -q '"$STACK_SERVER_DIR/.shared/manager-common.sh"' "$ROOT_DIR/shared/lib/stack-installer.sh"; then
    echo "FAIL: deploy não remove managers legados do game dir (EXP-34)"
    fail_count=$((fail_count + 1))
else
    echo "OK: deploy remove cópias legadas do game dir"
fi

# ------------------------------------------------------------------
# 5. Unit do agente sem CapabilityBoundingSet vazio (CR-02).
# ------------------------------------------------------------------
if grep -q '^CapabilityBoundingSet=$' "$ROOT_DIR/install.sh"; then
    echo "FAIL: unit do agente ainda tem CapabilityBoundingSet vazio (CR-02)"
    fail_count=$((fail_count + 1))
else
    echo "OK: unit do agente sem bounding set vazio"
fi

if [ "$fail_count" -ne 0 ]; then
    echo "FAIL: $fail_count verificação(ões) de segurança falharam"
    exit 1
fi

echo "OK: manager-safety-test"
