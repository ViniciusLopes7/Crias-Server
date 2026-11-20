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
# (CR-04) Extras preexistentes que o installer sobrescreve e o rollback deve
# RESTAURAR (o bug antigo os apagava mesmo em reinstalacao).
printf 'eula=true  # aceito pelo operador em 2025\n' > "$server_dir/eula.txt"
printf 'icone-original-png\n' > "$server_dir/server-icon.png"

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
# (EXP-34) deploy_stack_admin_tools instala em /usr/local/libexec (root);
# sem root no teste, os stubs simulam sucesso.
cat > "$stub_bin/install" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_bin/install"
cat > "$stub_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
# mkdir real, exceto caminhos de sistema que exigem root (simulado).
# /bin/mkdir absoluto: `command mkdir` resolveria para ESTE stub (recursao).
for a in "$@"; do
    case "$a" in
        -*) continue ;;
        /usr/local/*) continue ;;
        *) /bin/mkdir "$a" 2>/dev/null || true ;;
    esac
done
exit 0
EOF
chmod +x "$stub_bin/mkdir" 
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
CRIAS_TEST_SNAPSHOT_FILE="$tmp_dir/snapshot-path" \
bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "'"$ROOT_DIR"'/shared/lib/common.sh"
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
        # Guarda o nome aleatorio real para confirmar que EXIT removeu.
        printf "%s\n" "$STACK_SNAPSHOT_DIR" > "$CRIAS_TEST_SNAPSHOT_FILE"
        # Falha simulada no meio da instalacao (apos o deploy de scripts).
        deploy_stack_scripts
        # (CR-04) Simula o installer sobrescrevendo os extras declarados:
        # eula/icone pre-existentes e um server.jar NOVO (nao existia antes).
        printf 'eula=true\n' > "'"$server_dir"'/eula.txt"
        printf 'icone-NOVO\n' > "'"$server_dir"'/server-icon.png"
        printf 'jar-baixado\n' > "'"$server_dir"'/server.jar"
        echo "falha injetada" >&2
        return 1
    }
    # (CR-04) Extras declarados pelo stack: fotografa/restaura por manifesto.
    stack_snapshot_extra_paths() {
        cat << 'XEOF'
'"$server_dir"'/server-icon.png
'"$server_dir"'/eula.txt
'"$server_dir"'/server.jar
XEOF
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

# CONTRATO 4b (CR-04): extras PRE-EXISTENTES restaurados com conteudo original.
if ! grep -q 'aceito pelo operador em 2025' "$server_dir/eula.txt" 2>/dev/null; then
    echo "FAIL: eula.txt pre-existente nao foi restaurado pelo rollback (CR-04)"
    cat "$server_dir/eula.txt" >&2 || true
    exit 1
fi
if ! grep -q 'icone-original-png' "$server_dir/server-icon.png" 2>/dev/null; then
    echo "FAIL: server-icon.png pre-existente nao foi restaurado (CR-04)"
    exit 1
fi

# CONTRATO 4c (CR-04): extra que NAO existia antes (server.jar criado pela
# instalacao falha) e REMOVIDO — nao pode sobrar lixo de instalacao abortada.
if [ -e "$server_dir/server.jar" ]; then
    echo "FAIL: server.jar criado pela instalacao falha nao foi removido (CR-04)"
    exit 1
fi

# CONTRATO 5: o snapshot (novo modelo crias.XXXXXX) deve ser removido.
# Validar o caminho exato evita falsas aprovacoes quando o prefixo muda.
if [ ! -s "$tmp_dir/snapshot-path" ]; then
    echo "FAIL: caminho do snapshot nao foi registrado no teste" >&2
    exit 1
fi
snapshot_path="$(cat "$tmp_dir/snapshot-path")"
if [ -e "$snapshot_path" ] || [ -L "$snapshot_path" ]; then
    echo "FAIL: snapshot permaneceu apos rollback: $snapshot_path" >&2
    exit 1
fi

echo "OK: stack-rollback-test (artefatos restaurados, dados preservados)"
