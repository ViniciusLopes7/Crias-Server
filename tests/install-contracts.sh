#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Helper safe_cleanup_dir sourced from tests/lib/cleanup.sh (DRY)
source "$ROOT_DIR/tests/lib/cleanup.sh"

TMP_TEST_DIR="$(mktemp -d /tmp/crias-ci-install-contracts-XXXXXX)"
trap 'safe_cleanup_dir "$TMP_TEST_DIR" || true' EXIT

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/config-parser.sh"
assert_expected_failure() {
    local config_file="$1"
    local log_file="$2"
    local scenario="$3"

    set +e
    # env -u limpa variaveis que podem vazar de testes anteriores
    # (apply_config_with_env_precedence da prioridade ao ambiente sobre config)
    env -u ACCEPT_EULA -u SERVER_TYPE CONFIG_FILE="$config_file" bash ./install.sh > "$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "[install-contracts] Falha esperada nao ocorreu: $scenario" >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q 'SERVER_TYPE precisa ser definido como minecraft ou terraria' "$log_file"; then
        echo "[install-contracts] Mensagem esperada nao encontrada para: $scenario" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

# (EXP-35) Base aninhada para os dirs de servidor dos contratos: a
# politica de instalacao exige subdiretorio dedicado (profundidade >= 2
# sob /tmp) — /tmp/<dir> direto e rejeitado.
mkdir -p /tmp/crias-contracts/eula-ci /tmp/crias-contracts/invalid-port-ci /tmp/crias-contracts/paper-ci

run_missing_server_type_contract() {
    local cfg_file="$TMP_TEST_DIR/missing-server-type.env"
    local log_file="$TMP_TEST_DIR/missing-server-type.log"

    cat > "$cfg_file" << 'EOF'
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
EOF

    assert_expected_failure "$cfg_file" "$log_file" "SERVER_TYPE ausente em NON_INTERACTIVE"
}

run_invalid_server_type_contract() {
    local cfg_file="$TMP_TEST_DIR/invalid-server-type.env"
    local log_file="$TMP_TEST_DIR/invalid-server-type.log"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="invalido"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
EOF

    assert_expected_failure "$cfg_file" "$log_file" "SERVER_TYPE invalido em NON_INTERACTIVE"
}

run_env_override_precedence_contract() {
    local cfg_file="$TMP_TEST_DIR/env-precedence.env"
    local resolved_server_type=""
    local mc_dir="$TMP_TEST_DIR/minecraft"
    local tt_dir="$TMP_TEST_DIR/terraria"

    cat > "$cfg_file" << EOF
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_USER="minecraft-ci"
MINECRAFT_SERVER_DIR="$mc_dir"
MINECRAFT_PORT=45165
MINECRAFT_ONLINE_MODE="false"
MINECRAFT_VERSION="1.21.11"
MINECRAFT_LOADER="fabric"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_INSTALL_QOL_MODS="false"
TERRARIA_USER="terraria-ci"
TERRARIA_SERVER_DIR="$tt_dir"
TERRARIA_PORT=47777
TERRARIA_WORLD_NAME="world"
TERRARIA_MOTD="Contrato CI"
TERRARIA_DOWNLOAD_URL="https://example.invalid/terraria.zip"
EOF

    (
        SERVER_TYPE="terraria"

        apply_config_with_env_precedence "$cfg_file"

        resolved_server_type="$SERVER_TYPE"

        if [ "$resolved_server_type" != "terraria" ]; then
            echo "[install-contracts] SERVER_TYPE nao preservou precedencia do ambiente." >&2
            exit 1
        fi

        if [ "$MINECRAFT_USER" != "minecraft-ci" ]; then
            echo "[install-contracts] Config do Minecraft nao foi carregada corretamente." >&2
            exit 1
        fi

        if [ "$TERRARIA_USER" != "terraria-ci" ]; then
            echo "[install-contracts] Config do Terraria nao foi carregada corretamente." >&2
            exit 1
        fi
    )
}

run_config_parsing_contract() {
    local cfg_file="$TMP_TEST_DIR/config-parsing.env"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_MOTD="Servidor Crias com espacos"
TERRARIA_MOTD='Terraria com aspas simples e espacos'
TERRARIA_WORLD_NAME="Mundo do Crias"
EOF

    (
        unset MINECRAFT_MOTD
        unset TERRARIA_MOTD
        unset TERRARIA_WORLD_NAME

        apply_config_with_env_precedence "$cfg_file"

        if [ "$MINECRAFT_MOTD" != "Servidor Crias com espacos" ]; then
            echo "[install-contracts] MOTD do Minecraft nao preservou espacos/aspas." >&2
            exit 1
        fi

        if [ "$TERRARIA_MOTD" != "Terraria com aspas simples e espacos" ]; then
            echo "[install-contracts] MOTD do Terraria nao preservou aspas simples." >&2
            exit 1
        fi

        if [ "$TERRARIA_WORLD_NAME" != "Mundo do Crias" ]; then
            echo "[install-contracts] Nome do mundo do Terraria nao preservou espacos." >&2
            exit 1
        fi
    )
}

run_eula_contract() {
    local cfg_file="$TMP_TEST_DIR/eula-contract.env"
    local log_file="$TMP_TEST_DIR/eula-contract.log"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_USER="minecraft-ci"
MINECRAFT_SERVER_DIR="/tmp/crias-contracts/eula-ci/minecraft"
MINECRAFT_PORT=45165
MINECRAFT_ONLINE_MODE="false"
MINECRAFT_VERSION="1.21.11"
MINECRAFT_LOADER="fabric"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_INSTALL_QOL_MODS="false"
ACCEPT_EULA="false"
EOF

    set +e
    # env -u ACCEPT_EULA garante que apenas o config file (com false) seja usado
    env -u ACCEPT_EULA CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "[install-contracts] Falha esperada nao ocorreu: ACCEPT_EULA obrigatorio em NON_INTERACTIVE" >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q 'ACCEPT_EULA must be set to true in non-interactive mode' "$log_file"; then
        echo "[install-contracts] Mensagem esperada nao encontrada para ACCEPT_EULA" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

run_invalid_minecraft_port_contract() {
    local cfg_file="$TMP_TEST_DIR/invalid-minecraft-port.env"
    local log_file="$TMP_TEST_DIR/invalid-minecraft-port.log"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_USER="minecraft-ci"
MINECRAFT_SERVER_DIR="/tmp/crias-contracts/invalid-port-ci/minecraft"
MINECRAFT_PORT=70000
MINECRAFT_ONLINE_MODE="false"
MINECRAFT_VERSION="1.21.11"
MINECRAFT_LOADER="fabric"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_INSTALL_QOL_MODS="false"
ACCEPT_EULA="true"
EOF

    set +e
    env -u ACCEPT_EULA CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "[install-contracts] Falha esperada nao ocorreu: MINECRAFT_PORT fora da faixa" >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q 'MINECRAFT_PORT invalida' "$log_file"; then
        echo "[install-contracts] Mensagem esperada nao encontrada para MINECRAFT_PORT" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

run_invalid_terraria_port_contract() {
    local cfg_file="$TMP_TEST_DIR/invalid-terraria-port.env"
    local log_file="$TMP_TEST_DIR/invalid-terraria-port.log"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="terraria"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
TERRARIA_USER="terraria-ci"
TERRARIA_SERVER_DIR="/tmp/crias-contracts/invalid-port-ci/terraria"
TERRARIA_PORT=70000
TERRARIA_WORLD_NAME="world"
TERRARIA_MOTD="Contrato CI"
TERRARIA_DOWNLOAD_URL="https://example.invalid/terraria.zip"
EOF

    set +e
    env -u ACCEPT_EULA CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "[install-contracts] Falha esperada nao ocorreu: TERRARIA_PORT fora da faixa" >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q 'TERRARIA_PORT invalida' "$log_file"; then
        echo "[install-contracts] Mensagem esperada nao encontrada para TERRARIA_PORT" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

# v1.2.0: paper loader foi removido. Valida que o instalador rejeita paper.
run_paper_loader_rejected_contract() {
    local cfg_file="$TMP_TEST_DIR/paper-loader.env"
    local log_file="$TMP_TEST_DIR/paper-loader.log"

    cat > "$cfg_file" << 'EOF'
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
DRY_RUN="true"
INSTALL_TAILSCALE="false"
APPLY_SYSTEM_TUNING="false"
CLEANUP_OTHER_STACK="false"
MINECRAFT_USER="minecraft-ci"
MINECRAFT_SERVER_DIR="/tmp/crias-contracts/paper-ci/minecraft"
MINECRAFT_PORT=45165
MINECRAFT_ONLINE_MODE="false"
MINECRAFT_VERSION="1.21.11"
MINECRAFT_LOADER="paper"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_INSTALL_QOL_MODS="false"
ACCEPT_EULA="true"
EOF

    set +e
    env -u ACCEPT_EULA CONFIG_FILE="$cfg_file" bash ./install.sh > "$log_file" 2>&1
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "[install-contracts] Falha esperada nao ocorreu: paper loader deveria ser rejeitado (v1.2.0)" >&2
        cat "$log_file" >&2
        exit 1
    fi

    if ! grep -q "paper' nao suportado" "$log_file"; then
        echo "[install-contracts] Mensagem de rejeicao do paper nao encontrada" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

# v1.3.x: a versao do modpack escolhida no wizard (MINECRAFT_ADRENALINE_VERSION,
# nome legacy) precisa chegar ao mrpack-install como argumento posicional em
# TODAS as fontes que instalam modpack — bug historico: source=modrinth
# ignorava a versao e instalava sempre a mais recente.
run_modpack_version_passthrough_contract() {
    local bin_dir="$TMP_TEST_DIR/modpack-stub-bin"
    local args_log="$TMP_TEST_DIR/mrpack-args.log"
    local server_dir="$TMP_TEST_DIR/mc-modpack-server"

    mkdir -p "$bin_dir" "$server_dir"
    printf '%s\n' '{"schema":1,"dependencies":{"minecraft":"26.3","fabric-loader":"0.1"},"server-file":{"path":"server.jar"}}' > "$server_dir/packstate.json"

    # Stub de mrpack-install: registra os argumentos recebidos (um por linha).
    cat > "$bin_dir/mrpack-install" << EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$args_log"
exit 0
EOF
    chmod +x "$bin_dir/mrpack-install"

    # Stub do timeout: ignora as opcoes GNU e a duracao, mas preserva
    # TODOS os argumentos enviados ao mrpack-install.
    cat > "$bin_dir/timeout" << 'EOF'
#!/bin/bash
while [[ "${1:-}" == --* ]]; do shift; done
shift # duration (e.g. 3600s)
exec "$@"
EOF
    chmod +x "$bin_dir/timeout"

    (
        export PATH="$bin_dir:$PATH"
        export DRY_RUN="false"
        export MINECRAFT_SERVER_DIR="$server_dir"
        export MINECRAFT_INSTALL_QOL_MODS="false"
        export MINECRAFT_EXTRA_MODS=""
        export MINECRAFT_LOADER="fabric"
        export MINECRAFT_VERSION="26.3"

        # shellcheck source=/dev/null
        source "$ROOT_DIR/shared/lib/common.sh" >/dev/null 2>&1 || true
        # shellcheck source=/dev/null
        source "$ROOT_DIR/minecraft/install.sh" >/dev/null 2>&1

        # stack_download_and_install chama install_mrpack_install (pacman) —
        # stubamos para isolar o teste do contrato de argumentos.
        install_mrpack_install() { :; }

        # Caso 1: source=modrinth COM versao -> versao como 2o argumento posicional.
        : > "$args_log"
        MINECRAFT_MODPACK_SOURCE="modrinth"
        MINECRAFT_MODPACK_SLUG="fabulously-optimized"
        MINECRAFT_ADRENALINE_VERSION="v6.2.0"
        stack_download_and_install
        if ! grep -qFx 'fabulously-optimized' "$args_log" \
            || ! grep -qFx 'v6.2.0' "$args_log" \
            || ! grep -qFx -- '--server-dir' "$args_log"; then
            echo "[install-contracts] source=modrinth COM versao: argumentos errados:" >&2
            cat "$args_log" >&2
            exit 1
        fi

        # Caso 2: source=modrinth SEM versao -> so o slug (mais recente).
        : > "$args_log"
        MINECRAFT_MODPACK_SOURCE="modrinth"
        MINECRAFT_MODPACK_SLUG="adrenaline"
        MINECRAFT_ADRENALINE_VERSION=""
        stack_download_and_install
        if grep -qFx 'adrenaline' "$args_log" && [ "$(grep -cFx 'adrenaline' "$args_log")" -ne 1 ]; then
            echo "[install-contracts] source=modrinth SEM versao: argumentos inesperados:" >&2
            cat "$args_log" >&2
            exit 1
        fi
        if ! grep -qFx 'adrenaline' "$args_log"; then
            echo "[install-contracts] source=modrinth SEM versao: slug ausente:" >&2
            cat "$args_log" >&2
            exit 1
        fi

        # Caso 3: source=adrenaline COM versao (comportamento pre-existente preservado).
        : > "$args_log"
        MINECRAFT_MODPACK_SOURCE="adrenaline"
        MINECRAFT_ADRENALINE_VERSION="1.6.1"
        stack_download_and_install
        if ! grep -qFx 'adrenaline' "$args_log" || ! grep -qFx '1.6.1' "$args_log"; then
            echo "[install-contracts] source=adrenaline COM versao: argumentos errados:" >&2
            cat "$args_log" >&2
            exit 1
        fi

        # Caso 4: source=vanilla -> loader + versao MC (sem slug de modpack).
        : > "$args_log"
        MINECRAFT_MODPACK_SOURCE="vanilla"
        stack_download_and_install
        if ! grep -qFx 'fabric' "$args_log" || ! grep -qFx '26.3' "$args_log"; then
            echo "[install-contracts] source=vanilla: argumentos errados:" >&2
            cat "$args_log" >&2
            exit 1
        fi
    )
}

# Contratos do timeout com o comando GNU real: retorno 124 ao esgotar prazo,
# propagacao de erros do instalador e validacao de entradas.
run_mrpack_timeout_contract() {
    local bin_dir="$TMP_TEST_DIR/timeout-stub-bin"
    local log_file="$TMP_TEST_DIR/timeout-contract.log"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/mrpack-install" <<'EOF'
#!/bin/bash
case "${1:-}" in
    slow) sleep 3 ;;
    fail) exit 23 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/mrpack-install"
    (
        export PATH="$bin_dir:$PATH"
        export DRY_RUN=true
        # shellcheck source=/dev/null
        source "$ROOT_DIR/minecraft/install.sh"
        MINECRAFT_INSTALL_TIMEOUT_SECONDS=1
        local rc
        if run_mrpack_install_with_timeout slow > "$log_file" 2>&1; then
            echo "[install-contracts] Timeout de 1s nao foi respeitado" >&2
            exit 1
        else
            rc=$?
        fi
        [ "$rc" -eq 124 ] && grep -q 'excedeu 1s' "$log_file" || {
            echo "[install-contracts] Timeout: retorno/diagnostico inesperados ($rc)" >&2
            cat "$log_file" >&2
            exit 1
        }
        MINECRAFT_INSTALL_TIMEOUT_SECONDS=3600
        run_mrpack_install_with_timeout ok > "$log_file" 2>&1
        if run_mrpack_install_with_timeout fail > "$log_file" 2>&1; then
            echo "[install-contracts] Erro de mrpack-install foi ignorado" >&2
            exit 1
        else
            rc=$?
        fi
        [ "$rc" -eq 23 ] || { echo "[install-contracts] Erro 23 nao propagado" >&2; exit 1; }
        MINECRAFT_INSTALL_TIMEOUT_SECONDS=invalid
        if run_mrpack_install_with_timeout ok > "$log_file" 2>&1; then
            echo "[install-contracts] Timeout invalido foi aceito" >&2
            exit 1
        else
            rc=$?
        fi
        [ "$rc" -eq 2 ] && grep -q 'MINECRAFT_INSTALL_TIMEOUT_SECONDS invalido' "$log_file"
    )
    # Exercita a entrada direta (e nao apenas 'source' do instalador).
    NON_INTERACTIVE=true ACCEPT_EULA=true DRY_RUN=true \
        MINECRAFT_SERVER_DIR=/tmp/crias-contracts/direct-install \
        MINECRAFT_INSTALL_MODPACK=false \
        bash "$ROOT_DIR/minecraft/install.sh" > "$log_file" 2>&1 || {
            echo "[install-contracts] Entrada direta do instalador falhou" >&2
            cat "$log_file" >&2
            exit 1
        }
}

echo "[install-contracts] Validando falha rapida para configuracoes invalidas..."
run_missing_server_type_contract
run_invalid_server_type_contract

echo "[install-contracts] Validando precedencia de variaveis de ambiente..."
run_env_override_precedence_contract

echo "[install-contracts] Validando parse de valores com espacos e aspas..."
run_config_parsing_contract

echo "[install-contracts] Validando aceite explicito de EULA..."
run_eula_contract

echo "[install-contracts] Validando portas invalidas..."
run_invalid_minecraft_port_contract
run_invalid_terraria_port_contract

echo "[install-contracts] Validando rejeicao do loader paper (v1.2.0)..."
run_paper_loader_rejected_contract

echo "[install-contracts] Validando repasse da versao do modpack ao mrpack-install..."
run_modpack_version_passthrough_contract

echo "[install-contracts] Validando prazo real de instalacao e entrada direta..."
run_mrpack_timeout_contract

echo "[install-contracts] OK"
