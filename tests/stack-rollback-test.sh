#!/usr/bin/env bash
# tests/stack-rollback-test.sh
#
# CR-08 (contrato): numa REINSTALACAO sobre diretorio preexistente que FALHA,
# o rollback deve RESTAURAR os artefatos originais (runtime.env, scripts,
# .shared) em vez de apaga-los; e NUNCA apagar mundos/mods do usuario.
#
# Estrutura: um bash interno roda run_stack_install com hook de download que
# falha; o EXIT trap dispara o rollback; o script externo assertiona o estado
# final dos arquivos.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir" || true' EXIT

server_dir="$tmp_dir/server"
mkdir -p "$server_dir/world" "$server_dir/mods" "$server_dir/.shared"

# Estado preexistente (o que deve ser restaurado apos o rollback).
printf 'MIN_RAM=1024M\nMAX_RAM=2048M\n' > "$server_dir/runtime.env"
printf '#!/bin/bash\necho original\n' > "$server_dir/start-server.sh"
printf '#!/bin/bash\necho original-manager\n' > "$server_dir/mc-manager.sh"
printf 'common-lib-original\n' > "$server_dir/.shared/common.sh"
printf 'dados do mundo\n' > "$server_dir/world/level.dat"
printf 'jar do usuario\n' > "$server_dir/mods/meu-mod.jar"

# Scripts "novos" que o installer tentaria implantar (conteudo diferente).
new_scripts_dir="$tmp_dir/new-scripts"
mkdir -p "$new_scripts_dir"
printf '#!/bin/bash\necho NOVO-COM-BUG\n' > "$new_scripts_dir/start-server.sh"
printf '#!/bin/bash\necho NOVO-MANAGER\n' > "$new_scripts_dir/mc-manager.sh"

# Stubs para comandos que exigem root/systemd.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
for tool in systemctl useradd chown; do
    cat > "$stub_bin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$stub_bin/$tool"
done
cat > "$stub_bin/id" <<'EOF'
#!/usr/bin/env bash
echo "0(root) root"
EOF
chmod +x "$stub_bin/id"

# Bash interno: instala e falha no download; EXIT trap roda o rollback.
INNER_RC=0
PATH="$stub_bin:$PATH" \
STACK_NAME="minecraft" \
STACK_USER="minecraft" \
STACK_SERVER_DIR="$server_dir" \
STACK_SERVICE_TEMPLATE="$ROOT_DIR/minecraft/minecraft.service" \
bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "'"$ROOT_DIR"'/shared/lib/stack-installer.sh"

    STACK_RUNTIME_SCRIPTS=(
        "'"$new_scripts_dir"'/start-server.sh"
        "'"$new_scripts_dir"'/mc-manager.sh"
    )
    STACK_SHARED_LIBS=()

    # Nao há DRY_RUN: o snapshot precisa rodar de verdade.
    DRY_RUN=false
    export DRY_RUN

    stack_download_and_install() {
        # Falha simulada no meio da instalacao (apos o deploy de scripts).
        deploy_stack_scripts
        echo "falha injetada" >&2
        return 1
    }
    stack_rollback_extra_files() {
        return 0
    }

    run_stack_install
' || INNER_RC=$?

if [ "$INNER_RC" -eq 0 ]; then
    echo "FAIL: run_stack_install deveria falhar (falha injetada)"
    exit 1
fi

# CONTRATO 1: runtime.env restaurado com o conteudo ORIGINAL.
if ! grep -q 'MIN_RAM=1024M' "$server_dir/runtime.env" 2>/dev/null; then
    echo "FAIL: runtime.env nao foi restaurado pelo rollback (CR-08)"
    ls -la "$server_dir" >&2
    exit 1
fi

# CONTRATO 2: scripts restaurados com o conteudo ORIGINAL.
if ! grep -q 'echo original$' "$server_dir/start-server.sh" 2>/dev/null; then
    echo "FAIL: start-server.sh nao foi restaurado pelo rollback (CR-08)"
    exit 1
fi
if ! grep -q 'echo original-manager$' "$server_dir/mc-manager.sh" 2>/dev/null; then
    echo "FAIL: mc-manager.sh nao foi restaurado pelo rollback (CR-08)"
    exit 1
fi

# CONTRATO 3: .shared restaurado.
if ! grep -q 'common-lib-original' "$server_dir/.shared/common.sh" 2>/dev/null; then
    echo "FAIL: .shared nao foi restaurado pelo rollback (CR-08)"
    exit 1
fi

# CONTRATO 4: dados do usuario (mundo/mods) INTACTOS.
if ! grep -q 'dados do mundo' "$server_dir/world/level.dat" 2>/dev/null; then
    echo "FAIL: mundo do usuario foi apagado pelo rollback (CR-08)"
    exit 1
fi
if ! grep -q 'jar do usuario' "$server_dir/mods/meu-mod.jar" 2>/dev/null; then
    echo "FAIL: mods do usuario foram apagados pelo rollback (CR-08)"
    exit 1
fi

# CONTRATO 5: snapshot dir nao vaza em /tmp.
if ls "${TMPDIR:-/tmp}"/crias-stack-snapshot.* >/dev/null 2>&1; then
    echo "FAIL: diretorio de snapshot nao foi limpo apos o rollback"
    exit 1
fi

echo "OK: stack-rollback-test (artefatos restaurados, dados preservados)"
