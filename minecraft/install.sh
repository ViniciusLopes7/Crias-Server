#!/bin/bash
# minecraft/install.sh
#
# Minecraft stack installer using shared/lib/stack-installer.sh framework.

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$MODULE_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/hardware-profile.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/system-tuning.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/minecraft-tuning.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/downloads.sh"
# shellcheck source=/dev/null
# tui.sh para prompts consistentes com o wizard do install.sh raiz (gum com
# fallback read-based); carregar aqui também cobre execução standalone.
source "$ROOT_DIR/shared/lib/tui.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/stack-installer.sh"

# ---------------------------------------------------------------------------
# Stack config (env variables with defaults).
# ---------------------------------------------------------------------------
MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_SERVER_DIR="${MINECRAFT_SERVER_DIR:-/opt/minecraft-server}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"
MINECRAFT_ONLINE_MODE="${MINECRAFT_ONLINE_MODE:-true}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-26.3}"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
MINECRAFT_INSTALL_MODPACK="${MINECRAFT_INSTALL_MODPACK:-true}"
MINECRAFT_ADRENALINE_VERSION="${MINECRAFT_ADRENALINE_VERSION:-}"
MINECRAFT_INSTALL_QOL_MODS="${MINECRAFT_INSTALL_QOL_MODS:-true}"
MINECRAFT_MOTD="${MINECRAFT_MOTD:-§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r}"
# QoL mods and modpack source config.
# CSV of Modrinth slugs as "file_name:slug,file_name:slug,...".
# E.g.: "chunky:chunky,essential-commands:essential-commands"
MINECRAFT_QOL_MODS="${MINECRAFT_QOL_MODS:-chunky:chunky,essential-commands:essential-commands,universal-graves:universal-graves,tabtps:tabtps,styled-chat:styled-chat,polymer:polymer,placeholder-api:placeholder-api}"
# Individual user mods (CSV of Modrinth slugs) applied on top of modpack/QoL.
MINECRAFT_EXTRA_MODS="${MINECRAFT_EXTRA_MODS:-}"
# Modpack source: "adrenaline" (default) or "modrinth" (generic).
MINECRAFT_MODPACK_SOURCE="${MINECRAFT_MODPACK_SOURCE:-adrenaline}"
MINECRAFT_MODPACK_SLUG="${MINECRAFT_MODPACK_SLUG:-adrenaline}"
MINECRAFT_MODPACK_FILE="${MINECRAFT_MODPACK_FILE:-}"
MINECRAFT_MODPACK_URL="${MINECRAFT_MODPACK_URL:-}"
# mrpack-install version pin.
MRPACK_INSTALL_VERSION="${MRPACK_INSTALL_VERSION:-v0.23.0}"
# Deadline for mrpack-install (modpack or clean loader), in seconds (default: 60 min).
MINECRAFT_INSTALL_TIMEOUT_SECONDS="${MINECRAFT_INSTALL_TIMEOUT_SECONDS:-3600}"
# (CR-17) strict: pendencias de mods transformam-se em falha da instalacao.
MINECRAFT_MODS_STRICT="${MINECRAFT_MODS_STRICT:-false}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-false}"
DRY_RUN="${DRY_RUN:-false}"
MINECRAFT_SERVER_DIR_PREEXISTED="${MINECRAFT_SERVER_DIR_PREEXISTED:-false}"
MINECRAFT_INSTALL_SUCCEEDED="${MINECRAFT_INSTALL_SUCCEEDED:-false}"

# ---------------------------------------------------------------------------
# (CR-18) "Sem modpack" = servidor base LIMPO: a escolha explicita de
# MINECRAFT_INSTALL_MODPACK=false desliga QoL e extras — antes a flag so
# pulava a base e os hooks seguintes instalavam mods de qualquer jeito,
# contradizendo a leitura de "servidor apenas base". Para loader+mods SEM
# modpack, use MINECRAFT_MODPACK_SOURCE=vanilla com INSTALL_MODPACK=true.
# ---------------------------------------------------------------------------
if ! is_true "$MINECRAFT_INSTALL_MODPACK"; then
    if is_true "$MINECRAFT_INSTALL_QOL_MODS"; then
        print_step "MINECRAFT_INSTALL_MODPACK=false: mods QoL desativados (servidor base limpo — CR-18)."
        MINECRAFT_INSTALL_QOL_MODS="false"
    fi
    if [ -n "${MINECRAFT_EXTRA_MODS:-}" ]; then
        print_step "MINECRAFT_INSTALL_MODPACK=false: mods extras desativados (servidor base limpo — CR-18)."
        MINECRAFT_EXTRA_MODS=""
    fi
fi

# ---------------------------------------------------------------------------
# stack-installer framework config. Variables read by shared/lib/stack-installer.sh.
# shellcheck disable=SC2034  # variables used by stack-installer.sh
# ---------------------------------------------------------------------------
STACK_NAME="minecraft"
STACK_USER="$MINECRAFT_USER"
STACK_SERVER_DIR="$MINECRAFT_SERVER_DIR"
STACK_SERVICE_TEMPLATE="$MODULE_DIR/minecraft.service"
# (EXP-34) Scripts de RUNTIME ficam no diretorio do jogo (executam com o
# privilegio do proprio jogo). Scripts ADMINISTRATIVOS (manager, setup-cron —
# executados via sudo/root) vao para /usr/local/libexec/crias via
# STACK_ADMIN_SCRIPTS; nunca mais no diretorio gravavel pelo jogo.
STACK_RUNTIME_SCRIPTS=(
    "$MODULE_DIR/start-server.sh"
    "$MODULE_DIR/backup-cron.sh"
)
STACK_ADMIN_SCRIPTS=(
    "$MODULE_DIR/mc-manager.sh"
    "$MODULE_DIR/setup-cron.sh"
)
STACK_SHARED_LIBS=(
    "$ROOT_DIR/shared/lib/common.sh"
    "$ROOT_DIR/shared/lib/manager-common.sh"
    "$ROOT_DIR/shared/lib/config-parser.sh"
    "$ROOT_DIR/shared/lib/hardware-profile.sh"
    "$ROOT_DIR/shared/lib/minecraft-tuning.sh"
    "$ROOT_DIR/shared/lib/downloads.sh"
    "$ROOT_DIR/shared/lib/backup-engine.sh"
    "$ROOT_DIR/shared/lib/setup-cron.sh"
)

# ---------------------------------------------------------------------------
# Framework hooks.
# ---------------------------------------------------------------------------

# Validate inputs.
stack_validate_inputs() {
    validate_minecraft_inputs
    validate_minecraft_eula
}

validate_minecraft_inputs() {
    case "$MINECRAFT_LOADER" in
        fabric|quilt|vanilla|forge|neoforge)
            ;;
        paper)
            print_error "MINECRAFT_LOADER='paper' nao suportado desde v1.2.0."
            print_error "Use: fabric, quilt, vanilla, forge ou neoforge."
            exit 1
            ;;
        *)
            print_error "MINECRAFT_LOADER invalido: $MINECRAFT_LOADER"
            print_error "Use: fabric, quilt, vanilla, forge ou neoforge."
            exit 1
            ;;
    esac

    if ! [[ "$MINECRAFT_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+[a-z0-9]*)?$|^[0-9]+w[0-9]+[a-z]$ ]]; then
        print_error "MINECRAFT_VERSION invalido: $MINECRAFT_VERSION"
        print_error "Use formato semantico (ex.: 1.21.11) ou snapshot (ex.: 22w14a)."
        exit 1
    fi

    if is_true "$MINECRAFT_INSTALL_MODPACK"; then
        case "$MINECRAFT_MODPACK_SOURCE" in
            arquivo)
                if [[ "$MINECRAFT_MODPACK_FILE" != /* ]] || [ ! -f "$MINECRAFT_MODPACK_FILE" ] || [ ! -r "$MINECRAFT_MODPACK_FILE" ]; then
                    print_error "Informe um arquivo .mrpack local absoluto e legivel; monte o pendrive antes."
                    exit 1
                fi
                ;;
            link)
                if ! _valid_custom_pack_url "$MINECRAFT_MODPACK_URL"; then
                    print_error "Informe uma URL HTTPS direta valida, sem aspas, barras invertidas ou quebras de linha."
                    exit 1
                fi
                ;;
        esac
    fi

    if ! validate_port_number "MINECRAFT_PORT" "$MINECRAFT_PORT"; then
        exit 1
    fi

    # O aviso de troca para fabric so faz sentido para o Adrenaline (otimizado
    # para fabric). Modpacks genericos (source=modrinth) ja vieram do wizard
    # com versao compativel com o loader escolhido (filtro server-side na API
    # do Modrinth) — sugerir trocar o loader aqui com default Y quebraria a
    # instalacao de modpacks forge/neoforge/quilt.
    if is_true "$MINECRAFT_INSTALL_MODPACK" \
        && [ "${MINECRAFT_MODPACK_SOURCE:-adrenaline}" = "adrenaline" ] \
        && [ "$MINECRAFT_LOADER" != "fabric" ]; then
        print_warning "Adrenaline e otimizado para Fabric. Loader atual: $MINECRAFT_LOADER"
        if is_true "${NON_INTERACTIVE:-false}"; then
            print_warning "Mantendo loader informado por estar em modo non-interactive."
        else
            if tui_confirm "Trocar loader para fabric para maximizar compatibilidade do modpack?" "Y"; then
                MINECRAFT_LOADER="fabric"
            fi
        fi
    fi
}

validate_minecraft_eula() {
    # Require explicit EULA acceptance even in DRY_RUN.
    if is_true "${NON_INTERACTIVE:-false}"; then
        if ! is_true "${ACCEPT_EULA:-false}"; then
            print_error "ACCEPT_EULA must be set to true in non-interactive mode to accept Mojang EULA. Aborting."
            exit 1
        fi
        return 0
    fi

    echo "Para mais informacoes sobre a EULA da Mojang, visite:"
    echo "https://account.mojang.com/documents/minecraft_eula"
    echo ""
    if ! tui_confirm "Aceitar EULA da Mojang?" "N"; then
        print_error "EULA nao aceita. Instalacao abortada."
        exit 1
    fi
}

stack_install_dependencies() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao de dependencias do Minecraft."
        return 0
    fi

    print_step "Instalando dependencias do Minecraft..."

    # (EXP-36) Java exigido pela versao do jogo: MC 26.x exige Java 25
    # (anuncio oficial da Mojang para 26.1+); o pin anterior (jdk21) fazia o
    # servidor padrao (26.3) falhar no boot com UnsupportedClassVersionError.
    MINECRAFT_JAVA_MAJOR="$(required_java_major "$MINECRAFT_VERSION")"
    local jdk_pkg="jdk${MINECRAFT_JAVA_MAJOR}-openjdk"
    print_step "Java exigido para MC $MINECRAFT_VERSION: $MINECRAFT_JAVA_MAJOR ($jdk_pkg)"
    pacman -S --needed --noconfirm \
        "$jdk_pkg" \
        htop \
        iotop-c \
        nano \
        curl \
        wget \
        tar \
        gzip \
        unzip \
        zstd \
        gettext \
        logrotate \
        zram-generator \
        cpupower \
        lm_sensors \
        jq
}

install_mrpack_install() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do mrpack-install."
        return 0
    fi

    print_step "Instalando mrpack-install (versao pinada: $MRPACK_INSTALL_VERSION)..."

    # (EXP-41) O pin MRPACK_INSTALL_VERSION e um CONTRATO de CLI: so usa o
    # pacote do repositorio se a versao BATER com o pin. Versao divergente no
    # repo (atrasada/adiantada) pode ter CLI incompativel — nesse caso instala
    # o .pkg.tar.zst da release pinada.
    if pacman -Si mrpack-install >/dev/null 2>&1; then
        local repo_ver
        repo_ver="$(pacman -Si mrpack-install 2>/dev/null | awk -F': ' '/^Version/{print $2; exit}')"
        if [ "${repo_ver%%-*}" = "${MRPACK_INSTALL_VERSION#v}" ]; then
            print_step "Pacote mrpack-install $repo_ver (bate com o pin). Instalando via pacman..."
            pacman -S --needed --noconfirm mrpack-install
            _verify_mrpack_version || return 1
            return 0
        fi
        print_warning "mrpack-install do repo ($repo_ver) diverge do pin $MRPACK_INSTALL_VERSION; instalando versao pinada."
    fi

    local arch_pkg_url="https://github.com/nothub/mrpack-install/releases/download/${MRPACK_INSTALL_VERSION}/mrpack-install_${MRPACK_INSTALL_VERSION#v}_linux_amd64.pkg.tar.zst"
    local mrpack_tmp_dir
    mrpack_tmp_dir="$(mktemp_crias_dir)"
    local arch_pkg_local="${mrpack_tmp_dir}/mrpack-install.pkg.tar.zst"

    if curl_with_progress "Baixando mrpack-install ${MRPACK_INSTALL_VERSION}..." -fsSL --connect-timeout 10 --max-time 60 -o "$arch_pkg_local" "$arch_pkg_url"; then
        if pacman -U --noconfirm "$arch_pkg_local"; then
            _verify_mrpack_version || return 1
            print_success "mrpack-install instalado via pacman -U (.pkg.tar.zst)"
            return 0
        fi
        print_warning "pacman -U falhou para .pkg.tar.zst."
    fi

    print_error "Falha ao instalar mrpack-install $MRPACK_INSTALL_VERSION"
    print_error "URL tentada: $arch_pkg_url"
    print_error "Verifique MRPACK_INSTALL_VERSION em config.env."
    exit 1
}

# (EXP-41) Confere a versao do binario instalado contra o pin. Falhar aqui e
# falhar a instalacao: CLI divergente do pin quebraria os comandos seguintes.
_verify_mrpack_version() {
    local installed_ver
    installed_ver="$(mrpack-install version 2>/dev/null || mrpack-install --version 2>/dev/null || true)"
    if [ -z "$installed_ver" ]; then
        print_error "Nao foi possivel verificar a versao do mrpack-install."
        return 1
    fi
    if ! printf '%s' "$installed_ver" | grep -Fq "${MRPACK_INSTALL_VERSION#v}"; then
        print_error "mrpack-install instalado ($installed_ver) diverge do pin $MRPACK_INSTALL_VERSION."
        print_error "Corrija MRPACK_INSTALL_VERSION em config.env ou remova o pacote divergente."
        exit 1
    fi
    print_step "mrpack-install $installed_ver confere com o pin."
}

# A single timeout for all mrpack-install paths, including local packs and
# clean loader installation. Large modpacks and slow networks may exceed 5 min.
# GNU timeout: 124 = deadline reached; 137 may indicate forced SIGKILL.
run_mrpack_install_with_timeout() {
    local seconds="${MINECRAFT_INSTALL_TIMEOUT_SECONDS:-3600}"
    if ! [[ "$seconds" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$seconds" -gt 86400 ]; then
        print_error "MINECRAFT_INSTALL_TIMEOUT_SECONDS invalido: $seconds (use 1 a 86400 segundos)."
        return 2
    fi
    print_step "mrpack-install: prazo de ate ${seconds}s para instalacao."
    local result=0
    timeout --signal=TERM --kill-after=30s "${seconds}s" mrpack-install "$@" || result=$?
    if [ "$result" -eq 124 ]; then
        print_error "mrpack-install excedeu ${seconds}s; aumente MINECRAFT_INSTALL_TIMEOUT_SECONDS ou verifique a rede."
    elif [ "$result" -ne 0 ]; then
        print_error "mrpack-install falhou (codigo $result); veja o erro acima. Se houve desconexao, verifique a rede e tente novamente."
    fi
    return "$result"
}

stack_download_and_install() {
    print_step "Instalando base do servidor Minecraft..."

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao base do Minecraft."
        return 0
    fi

    install_mrpack_install

    cd "$MINECRAFT_SERVER_DIR" || exit 1

    # MINECRAFT_INSTALL_MODPACK=false honrado (CR-20): instala apenas o
    # servidor base (loader + versao do jogo), equivalente a source=vanilla —
    # antes a flag era lida na validacao mas ignorada na instalacao, e o
    # modpack da fonte selecionada era instalado de qualquer jeito.
    if ! is_true "$MINECRAFT_INSTALL_MODPACK"; then
        print_step "MINECRAFT_INSTALL_MODPACK=false: instalando apenas o servidor base (sem modpack)."
        _install_minecraft_server_base
        echo "eula=true" > "$MINECRAFT_SERVER_DIR/eula.txt"
        return 0
    fi

    # Modpack source selectable via config.
    # (AUDIT-B N7) O nome do server-file deriva do loader em TODOS os ramos:
    # Quilt usa mc.jar (o launcher interno do Quilt ocupa server.jar) —
    # valendo tambem para packs quilt via source=modrinth.
    local modpack_server_file="server.jar"
    if [ "$MINECRAFT_LOADER" = "quilt" ]; then
        modpack_server_file="mc.jar"
    fi
    MINECRAFT_SERVER_FILE="$modpack_server_file"

    case "$MINECRAFT_MODPACK_SOURCE" in
        adrenaline)
            if [ -n "$MINECRAFT_ADRENALINE_VERSION" ]; then
                run_mrpack_install_with_timeout adrenaline "$MINECRAFT_ADRENALINE_VERSION" --server-dir "$MINECRAFT_SERVER_DIR" --server-file "$modpack_server_file"
            else
                timeout 300 mrpack-install adrenaline --server-dir "$MINECRAFT_SERVER_DIR" --server-file "$modpack_server_file"
            fi
            ;;
        modrinth)
            # Generic modpack via Modrinth slug. A versao selecionada no wizard
            # (guardada em MINECRAFT_ADRENALINE_VERSION, nome legacy) e passada
            # como argumento posicional — sem ela o mrpack-install instalaria a
            # mais recente, ignorando a escolha do usuario (bug: a doc promete
            # "mrpack-install <slug> [version]").
            local slug="${MINECRAFT_MODPACK_SLUG:-adrenaline}"
            if [ -n "${MINECRAFT_ADRENALINE_VERSION:-}" ]; then
                timeout 300 mrpack-install "$slug" "$MINECRAFT_ADRENALINE_VERSION" --server-dir "$MINECRAFT_SERVER_DIR" --server-file "$modpack_server_file"
            else
                timeout 300 mrpack-install "$slug" --server-dir "$MINECRAFT_SERVER_DIR" --server-file "$modpack_server_file"
            fi
            ;;
        arquivo|link)
            local custom_pack="$MINECRAFT_MODPACK_FILE"
            if [ "$MINECRAFT_MODPACK_SOURCE" = link ]; then
                if ! _valid_custom_pack_url "$MINECRAFT_MODPACK_URL"; then
                    print_error "URL de modpack invalida."
                    return 1
                fi
                local curl_cfg
                custom_pack="$(mktemp_crias_file)"
                curl_cfg="$(mktemp_crias_file)"
                chmod 600 "$curl_cfg"
                printf 'url = "%s"\n' "$MINECRAFT_MODPACK_URL" > "$curl_cfg"
                print_step "Baixando o modpack pelo link HTTPS..."
                if ! curl --config "$curl_cfg" --proto '=https' --proto-redir '=https' --location --fail --silent --show-error --connect-timeout 20 --max-time 900 --max-filesize 2147483648 --output "$custom_pack"; then
                    rm -f "$curl_cfg"
                    print_error "Falha ao baixar o arquivo; confirme que o link e direto e publico."
                    return 1
                fi
                rm -f "$curl_cfg"
            fi
            if ! _validate_custom_mrpack "$custom_pack"; then return 1; fi
            timeout 300 mrpack-install "$custom_pack" --server-dir "$MINECRAFT_SERVER_DIR" --server-file "$modpack_server_file"
            ;;
        vanilla)
            _install_minecraft_server_base
            ;;
        *)
            print_error "MINECRAFT_MODPACK_SOURCE invalido: $MINECRAFT_MODPACK_SOURCE (use: adrenaline, modrinth, arquivo, link, vanilla)"
            exit 1
            ;;
    esac

    # (EXP-42 / AUDIT-B N4) Versao efetiva do jogo/loader: SOMENTE nos ramos
    # de MODPACK (adrenaline/modrinth) — o mrpack-install escolhe a versao do
    # PACK, que pode divergir da MINECRAFT_VERSION configurada. No ramo
    # vanilla/no-modpack a base instalada E a versao configurada; consultar o
    # slug default aqui sobrescreveria a versao correta com a do adrenaline.
    if [ "$MINECRAFT_MODPACK_SOURCE" = "adrenaline" ] || [ "$MINECRAFT_MODPACK_SOURCE" = "modrinth" ] || [ "$MINECRAFT_MODPACK_SOURCE" = "arquivo" ] || [ "$MINECRAFT_MODPACK_SOURCE" = "link" ]; then
        _resolve_modpack_effective_versions || return 1
        _reconcile_effective_java
    fi

    echo "eula=true" > "$MINECRAFT_SERVER_DIR/eula.txt"
}

# (EXP-37/39) Instalacao do servidor base via subcomando `server` da CLI
# v0.23.0: `mrpack-install server <loader> --minecraft-version <versao>`.
# A forma antiga (`mrpack-install <loader> <versao>`) tratava o loader como
# NOME DE MODPACK e falhava ou instalava o pack errado. Quilt usa
# --server-file mc.jar: o launcher do Quilt ocupa server.jar internamente.
_install_minecraft_server_base() {
    local server_file="server.jar"
    if [ "$MINECRAFT_LOADER" = "quilt" ]; then
        server_file="mc.jar"
    fi
    timeout 300 mrpack-install server "$MINECRAFT_LOADER" \
        --minecraft-version "$MINECRAFT_VERSION" \
        --server-dir "$MINECRAFT_SERVER_DIR" \
        --server-file "$server_file"
    MINECRAFT_SERVER_FILE="$server_file"
}

_valid_custom_pack_url() {
    local url="$1"
    [[ "$url" == https://* && "$url" != *[[:cntrl:]]* && "$url" != *"\""* && "$url" != *\\* ]]
}

# Verify the archive and the Modrinth pack format before running the installer.
_validate_custom_mrpack() {
    local archive="$1" index_count
    if [ ! -f "$archive" ] || [ ! -r "$archive" ] || ! unzip -tq "$archive" >/dev/null 2>&1; then
        print_error "Arquivo .mrpack ausente, ilegivel ou corrompido."
        return 1
    fi
    index_count="$(unzip -Z -1 "$archive" | grep -c '^modrinth[.]index[.]json$' || true)"
    if [ "$index_count" != 1 ] || ! unzip -p "$archive" modrinth.index.json | jq -e '.formatVersion == 1 and .game == "minecraft" and (.dependencies.minecraft | type == "string" and length > 0)' >/dev/null 2>&1; then
        print_error "Arquivo nao contem um indice .mrpack valido para Minecraft."
        return 1
    fi
}

# (AUDIT-B N5) A versao EFETIVA do pack alimenta o JDK e o runtime.env: se o
# pack mira MC diferente da configurada (ex.: pack 26.x com config 1.21.1), o
# jdk21 instalado pela versao configurada nao subiria o servidor
# (UnsupportedClassVersionError — ressuscitaria o EXP-36 justamente no
# cenario de divergencia). Instala o JDK exigido pela versao efetiva e
# promove a efetiva a versao oficial do runtime.
_reconcile_effective_java() {
    if [ -z "${MC_EFFECTIVE_VERSION:-}" ] || [ "$MC_EFFECTIVE_VERSION" = "$MINECRAFT_VERSION" ]; then
        return 0
    fi
    local required_major
    required_major="$(required_java_major "$MC_EFFECTIVE_VERSION")"
    if [ "$required_major" != "$MINECRAFT_JAVA_MAJOR" ]; then
        print_warning "Pack mira MC $MC_EFFECTIVE_VERSION (Java $required_major); instalando jdk${required_major}-openjdk (configurado era $MINECRAFT_VERSION/Java $MINECRAFT_JAVA_MAJOR)."
        if ! pacman -S --needed --noconfirm "jdk${required_major}-openjdk"; then
            print_error "Falha ao instalar jdk${required_major}-openjdk exigido pelo modpack."
            exit 1
        fi
        MINECRAFT_JAVA_MAJOR="$required_major"
    fi
    # A versao efetiva vira a versao oficial do servidor: runtime.env,
    # start-server (validacao Java) e resumos passam a usa-la.
    print_warning "MINECRAFT_VERSION promovida para a versao do pack: $MC_EFFECTIVE_VERSION."
    MINECRAFT_VERSION="$MC_EFFECTIVE_VERSION"
}

# mrpack-install v0.23 writes packstate.json from the actual installed archive.
# Never infer the installed loader or game version from unrelated API ordering.
_resolve_modpack_effective_versions() {
    local state="$MINECRAFT_SERVER_DIR/packstate.json" version loader_count loader server_file
    if [ ! -f "$state" ] || ! command -v jq >/dev/null 2>&1; then
        print_error "Nao foi possivel confirmar as dependencias do modpack instalado ($state)."
        return 1
    fi
    version="$(jq -er '.dependencies.minecraft | select(type == "string" and length > 0)' "$state")" || return 1
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+[a-z0-9]*)?$|^[0-9]+w[0-9]+[a-z]$ ]]; then
        print_error "Versao Minecraft invalida no packstate: $version"
        return 1
    fi
    loader_count="$(jq -er '[.dependencies | .["fabric-loader"], .["quilt-loader"], .forge, .neoforge | select(type == "string" and length > 0)] | length' "$state")" || return 1
    if [ "$loader_count" -gt 1 ]; then
        print_error "Modpack possui multiplos loaders; nao e possivel decidir com seguranca."
        return 1
    fi
    loader="$(jq -r '.dependencies | if (.["fabric-loader"] // "") != "" then "fabric" elif (.["quilt-loader"] // "") != "" then "quilt" elif (.forge // "") != "" then "forge" elif (.neoforge // "") != "" then "neoforge" else "vanilla" end' "$state")" || return 1
    server_file="$(jq -r '.["server-file"].path // empty' "$state")" || return 1
    if [ -n "$server_file" ]; then
        case "$server_file" in */*|.*|-*) print_error "Caminho de servidor invalido no packstate."; return 1 ;; esac
        MINECRAFT_SERVER_FILE="$server_file"
    fi
    MC_EFFECTIVE_VERSION="$version"
    MC_EFFECTIVE_LOADER="$loader"
    MINECRAFT_LOADER="$loader"
    print_step "Modpack instalado: Minecraft $version, loader $loader."
}

# (CR-17) Pendencias coletadas pelos hooks de mods; o modo strict decide o
# que fazer com elas no final (stack_install_finalize).
MINECRAFT_PENDING_MODS=()

# QoL mods via CSV in config.env (MINECRAFT_QOL_MODS).
stack_install_qol_mods() {
    install_minecraft_qol_mods
}

# (CR-17) Politica strict: com MINECRAFT_MODS_STRICT=true, mods pendentes
# transformam a instalacao em FALHA (o stack-installer aciona o rollback).
# Default (false) mantem o contrato best-effort com relatorio de pendencias.
stack_install_finalize() {
    if [ "${#MINECRAFT_PENDING_MODS[@]}" -gt 0 ]; then
        print_warning "RESUMO — mods pendentes (${#MINECRAFT_PENDING_MODS[@]}): ${MINECRAFT_PENDING_MODS[*]}"
        if is_true "$MINECRAFT_MODS_STRICT"; then
            print_error "MINECRAFT_MODS_STRICT=true e ha mods pendentes; instalacao considerada FALHA (CR-17)."
            return 1
        fi
        print_warning "MINECRAFT_MODS_STRICT=false: instalacao concluida em modo best-effort."
    fi
    return 0
}

# Mods individuais do usuário (MINECRAFT_EXTRA_MODS, CSV de slugs Modrinth),
# aplicados POR CIMA do modpack: o QoL acima pula quando mods/ já tem arquivos
# (os do modpack), então extras têm fluxo próprio sem esse gate, não restringem
# loader (a filtragem loader+versão é server-side na API) e pulam arquivos já
# baixados (idempotente em re-runs).
stack_install_extra_mods() {
    if [ -z "${MINECRAFT_EXTRA_MODS:-}" ]; then
        return 0
    fi

    if [ "$MINECRAFT_LOADER" = "vanilla" ]; then
        print_warning "Mods extras pulados: loader vanilla nao carrega .jar de mods."
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao dos mods extras do Minecraft."
        return 0
    fi

    print_step "Instalando mods extras..."
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"

    local entry slug
    local IFS=','
    local pending_mods=()
    set -f
    for entry in $MINECRAFT_EXTRA_MODS; do
        slug="${entry#"${entry%%[![:space:]]*}"}"
        slug="${slug%"${slug##*[![:space:]]}"}"
        [ -z "$slug" ] && continue

        if [[ "$slug" == *..* ]] || [[ "$slug" == */* ]]; then
            print_error "Mod extra rejeitado (possível path traversal): '$slug'"
            continue
        fi

        # Identify the known tools by their declared mod ID, even when a
        # launcher renamed the JAR. Fall back to well-known versioned names.
        local existing= file metadata modid
        case "$slug" in
            spark|chunky|skinrestorer)
                while IFS= read -r -d '' file; do
                    [ -f "$file" ] || continue
                    metadata=$(unzip -p "$file" META-INF/mods.toml 2>/dev/null | awk '/^[[:space:]]*\[\[mods\]\]/{inmods=1; next} /^[[:space:]]*\[/{inmods=0} inmods {print}' || true)
                    if printf '%s\n' "$metadata" | grep -Eiq "^[[:space:]]*modId[[:space:]]*=[[:space:]]*[\"']${slug}[\"']"; then
                        existing=$file
                    else
                        modid=$(unzip -p "$file" fabric.mod.json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
                        if [ "$modid" = "$slug" ]; then existing=$file; fi
                    fi
                    if [ -z "$existing" ]; then
                        case "${file##*/}" in
                            [Ss][Pp][Aa][Rr][Kk]-*) if [ "$slug" = spark ]; then existing=$file; fi ;;
                            [Cc][Hh][Uu][Nn][Kk][Yy]-*) if [ "$slug" = chunky ]; then existing=$file; fi ;;
                            [Ss][Kk][Ii][Nn][Rr][Ee][Ss][Tt][Oo][Rr][Ee][Rr]-*) if [ "$slug" = skinrestorer ]; then existing=$file; fi ;;
                        esac
                    fi
                    [ -z "$existing" ] || break
                done < <(find "$MINECRAFT_SERVER_DIR/mods" -maxdepth 1 -type f -name '*.jar' -print0) ;;
        esac
        if [ -n "$existing" ]; then
            print_step "Mod extra ja presente: ${existing##*/} (pulando)."
            continue
        fi

        if [ -f "$MINECRAFT_SERVER_DIR/mods/${slug}.jar" ]; then
            print_step "Mod extra ja presente: ${slug}.jar (pulando)."
            continue
        fi

        # CR-21: falha nao mata a instalacao (best-effort), mas entra no
        # relatorio de pendencias em vez de passar em silencio.
        # (EXP-42) downloads seguem a versao EFETIVA (pack pode divergir da
        # configurada).
        if ! download_modrinth_mod "$slug" "$MINECRAFT_LOADER" "${MC_EFFECTIVE_VERSION:-$MINECRAFT_VERSION}" "$MINECRAFT_SERVER_DIR/mods" "$slug"; then
            pending_mods+=("$slug")
        fi
    done
    set +f

    if [ "${#pending_mods[@]}" -gt 0 ]; then
        print_warning "Mods extras PENDENTES (download falhou): ${pending_mods[*]}"
        print_warning "Instale manualmente em $MINECRAFT_SERVER_DIR/mods/ ou reexecute o installer."
        MINECRAFT_PENDING_MODS+=("${pending_mods[@]}")
    fi
}

# Legacy name kept for tests/quick-script-tests.sh compatibility.
install_minecraft_qol_mods() {
    if ! is_true "$MINECRAFT_INSTALL_QOL_MODS"; then
        return 0
    fi

    if [ "$MINECRAFT_LOADER" != "fabric" ] && [ "$MINECRAFT_LOADER" != "quilt" ]; then
        print_warning "Mods QoL pulados para loader $MINECRAFT_LOADER"
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao dos mods QoL do Minecraft."
        return 0
    fi

    # (CR-21) Sem skip coletivo do diretorio mods/: a checagem e POR SLUG.
    # O modpack pode popular mods/ e mesmo assim um mod QoL ausente deve ser
    # baixado; o skip antigo ("mods/ nao-vazio -> pula tudo") deixava a lista
    # divergir silenciosamente do que o usuario pediu.
    print_step "Instalando mods QoL..."
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"

    # Parse CSV "file_name:slug,file_name:slug,...".
    # set -f prevents glob expansion (defensive).
    local entry file_name slug
    local pending_qol=()
    local IFS=','
    set -f
    for entry in $MINECRAFT_QOL_MODS; do
        file_name="${entry%%:*}"
        slug="${entry#*:}"
        # Fallback: if no ":", file_name == slug.
        if [ -z "$slug" ] || [ "$slug" = "$entry" ]; then
            slug="$file_name"
        fi

        # Validate file_name and slug against path traversal.
        # Sem check de NUL: variáveis bash não carregam NUL (descartado no
        # assignment) e o padrão *$'\0'* expande para ** (casa com TUDO) —
        # rejeitava qualquer mod.
        local _bad_part=""
        if [[ "$file_name" == *..* ]] || [[ "$file_name" == */* ]]; then
            _bad_part="file_name='$file_name'"
        elif [[ "$slug" == *..* ]] || [[ "$slug" == */* ]]; then
            _bad_part="slug='$slug'"
        fi
        if [ -n "$_bad_part" ]; then
            print_error "Mod QoL rejeitado (possível path traversal): $_bad_part"
            continue
        fi

        # The curated mods commonly arrive with versioned names in mrpacks.
        # Avoid installing a second copy over a pack's existing version.
        local existing= file
        case "$slug" in
            spark|chunky|skinrestorer)
                while IFS= read -r -d '' file; do
                    [ -f "$file" ] || continue
                    case "${file##*/}" in
                        [Ss][Pp][Aa][Rr][Kk]-*.jar|[Cc][Hh][Uu][Nn][Kk][Yy]-*.jar|[Ss][Kk][Ii][Nn][Rr][Ee][Ss][Tt][Oo][Rr][Ee][Rr]-*.jar)
                            case "${file##*/}" in
                                [Ss][Pp][Aa][Rr][Kk]-*) if [ "$slug" = spark ]; then existing=$file; fi ;;
                                [Cc][Hh][Uu][Nn][Kk][Yy]-*) if [ "$slug" = chunky ]; then existing=$file; fi ;;
                                *) if [ "$slug" = skinrestorer ]; then existing=$file; fi ;;
                            esac ;;
                    esac
                done ;;
        esac
        if [ -n "$existing" ]; then
            print_step "Mod extra ja presente: ${existing##*/} (pulando)."
            continue
        fi

        if [ -f "$MINECRAFT_SERVER_DIR/mods/${slug}.jar" ]; then
            print_step "Mod QoL ja presente: ${slug}.jar (pulando)."
            continue
        fi

        if ! download_qol_mod "$file_name" "$slug"; then
            pending_qol+=("$slug")
        fi
    done
    set +f

    if [ "${#pending_qol[@]}" -gt 0 ]; then
        print_warning "Mods QoL PENDENTES (download falhou): ${pending_qol[*]}"
        print_warning "Instale manualmente em $MINECRAFT_SERVER_DIR/mods/ ou reexecute o installer."
        MINECRAFT_PENDING_MODS+=("${pending_qol[@]}")
    fi
}

# Legacy name kept for tests/quick-script-tests.sh compatibility.
download_qol_mod() {
    local file_name="$1"
    local slug="$2"
    local mod_sha_var
    # Normalize mod name: hyphens -> underscores to derive valid env var.
    local file_name_norm
    file_name_norm="${file_name//-/_}"
    mod_sha_var="MOD_${file_name_norm^^}_SHA256"

    # CR-21: propaga a falha (o caller coleta pendencias); o warning
    # especifico ja foi emitido dentro do helper. (EXP-42) versao efetiva.
    if ! download_modrinth_mod "$slug" "$MINECRAFT_LOADER" "${MC_EFFECTIVE_VERSION:-$MINECRAFT_VERSION}" "$MINECRAFT_SERVER_DIR/mods" "$file_name" "$mod_sha_var"; then
        return 1
    fi
    return 0
}

stack_configure_runtime() {
    print_step "Aplicando tuning automatico para Minecraft..."

    detect_hardware_profile "$MINECRAFT_SERVER_DIR" "$FORCE_HARDWARE_TIER"
    compute_minecraft_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER" "$HW_AVAILABLE_RAM_MB"

    # STACK_SERVICE_MEMORY_MAX_MB read by install_stack_service (stack-installer.sh).
    # shellcheck disable=SC2034
    STACK_SERVICE_MEMORY_MAX_MB="$MC_SERVICE_MEMORY_MAX_MB"
    STACK_SERVICE_MEMORY_HIGH_MB="$MC_SERVICE_MEMORY_HIGH_MB"

    write_minecraft_runtime_env "$MINECRAFT_SERVER_DIR/runtime.env"
    write_minecraft_server_properties "$MINECRAFT_SERVER_DIR/server.properties" "$MINECRAFT_PORT" "$MINECRAFT_ONLINE_MODE" "$MINECRAFT_MOTD"
    write_minecraft_tuning_state "$MINECRAFT_SERVER_DIR/hardware-profile.env"

    write_minecraft_extra_configs

    print_success "Tier detectado: $HW_DETECTED_TIER | Tier aplicado: $HW_TIER"
    print_success "Heap aplicado: $MC_MIN_RAM -> $MC_MAX_RAM"
}

write_minecraft_extra_configs() {
    run_or_dry_run "Criando diretorios de configuracao do Minecraft" mkdir -p "$MINECRAFT_SERVER_DIR/config/essentialcommands" "$MINECRAFT_SERVER_DIR/config/universal_graves"

    if [ ! -f "$MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" ]; then
        write_file_or_dry_run "Gerando config do Essential Commands em $MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" "$MINECRAFT_SERVER_DIR/config/essentialcommands/config.toml" << 'EOF'
[teleportation]
allow_teleport_between_dimensions = true
teleport_request_timeout_seconds = 120
teleport_cost = 0

[home]
max_homes = 3
allow_home_in_any_dimension = true

[spawn]
allow_spawn_in_any_dimension = true

[back]
enable_back = true
save_back_on_death = true

[rtp]
enable_rtp = true
rtp_radius = 10000
rtp_min_radius = 1000

[nicknames]
enable_nicknames = true
nickname_prefix = "~"
EOF
    fi

    if [ ! -f "$MINECRAFT_SERVER_DIR/config/universal_graves/config.json" ]; then
        write_file_or_dry_run "Gerando config do Universal Graves em $MINECRAFT_SERVER_DIR/config/universal_graves/config.json" "$MINECRAFT_SERVER_DIR/config/universal_graves/config.json" << 'EOF'
{
  "protection_time": 300,
  "breaking_time": 1800,
  "drop_items_on_expiration": true,
  "message_on_grave_break": true,
  "message_on_grave_expire": true,
  "hologram": true,
  "title": true,
  "gui": true
}
EOF
    fi
}

# Legacy name kept for tests/quick-script-tests.sh compatibility.
install_minecraft_logrotate_config() {
    stack_install_logrotate
}

stack_install_logrotate() {
    local logrotate_conf="/etc/logrotate.d/crias-minecraft"

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao de logrotate do Minecraft."
        return 0
    fi

    print_step "Configurando logrotate do Minecraft..."
    mkdir -p "$(dirname "$logrotate_conf")"

    cat > "$logrotate_conf" << EOF
$MINECRAFT_SERVER_DIR/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

stack_create_extra_dirs() {
    mkdir -p "$MINECRAFT_SERVER_DIR/mods"
}

stack_deploy_extra_assets() {
    # Deploy server icon if available.
    if [ -f "$ROOT_DIR/assets/images/branding/server-icon.png" ]; then
        run_or_dry_run "Copiando server icon para $MINECRAFT_SERVER_DIR/server-icon.png" cp "$ROOT_DIR/assets/images/branding/server-icon.png" "$MINECRAFT_SERVER_DIR/server-icon.png"
        if ! dry_run_enabled; then
            print_success "Server icon deploiement: $MINECRAFT_SERVER_DIR/server-icon.png"
        fi
    fi
}

# (EXP-33/34) comandos.sh fica no diretorio do jogo como conveniencia para
# o usuario do jogo — NINGUEM com privilegio faz source dele (o profile.d
# recebe aliases estaticos gerados pelo install.sh). Os aliases apontam para
# o manager root:root em /usr/local/libexec/crias.
stack_generate_aliases() {
    cat << EOF
#!/bin/bash
# Generated by Crias-Server installer - do not edit manually
# Aliases de conveniencia. O perfil global (/etc/profile.d/crias-server.sh)
# tem versao estatica destes mesmos aliases.
alias mcstart='sudo systemctl start minecraft'
alias mcstop='sudo systemctl stop minecraft'
alias mcrestart='sudo systemctl restart minecraft'
alias mcstatus='sudo /usr/local/libexec/crias/mc-manager.sh status'
alias mclogs='sudo journalctl -u minecraft -f'
alias mcconsole='sudo /usr/local/libexec/crias/mc-manager.sh console'
alias mcbackup='sudo /usr/local/libexec/crias/mc-manager.sh backup'
alias mcsetupcron='sudo /usr/local/libexec/crias/mc-manager.sh setup-cron'
alias mcdir='cd $MINECRAFT_SERVER_DIR'
alias mcprops='sudo nano $MINECRAFT_SERVER_DIR/server.properties'
alias mchw='sudo /usr/local/libexec/crias/mc-manager.sh hardware-report'
alias mcreconfig='sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware'
EOF
}

# (CR-04) Extras que o installer sobrescreve e o snapshot precisa fotografar
# em reinstalacoes: config do servidor, jar do servidor, icone e EULA. O
# rollback do stack-installer restaura/remova conforme o manifesto — nao
# existe mais lista cega de remocao (o bug antigo apagava eula.txt e icone
# pre-existentes mesmo em reinstalacao).
stack_snapshot_extra_paths() {
    cat << EOF
$MINECRAFT_SERVER_DIR/server-icon.png
$MINECRAFT_SERVER_DIR/eula.txt
$MINECRAFT_SERVER_DIR/server.properties
$MINECRAFT_SERVER_DIR/server.jar
$MINECRAFT_SERVER_DIR/mc.jar
EOF
}

# Alias preserving name used by root install.sh.
run_minecraft_install() {
    run_stack_install
    download_server_icon_if_set
}

# Aliases for backward compat with legacy test functions
# (tests/arch-dry-install.sh calls deploy_minecraft_scripts directly).
deploy_minecraft_scripts() {
    deploy_stack_scripts
}

rollback_minecraft_install() {
    rollback_stack_install
}

install_minecraft_service() {
    install_stack_service
}

apply_minecraft_system_tuning() {
    apply_stack_system_tuning
}

download_server_icon_if_set() {
    if [ -z "${MINECRAFT_SERVER_ICON_URL:-}" ]; then
        return 0
    fi

    if is_true "${DRY_RUN:-false}"; then
        print_step "[DRY_RUN] Pulando download do server-icon.png"
        return 0
    fi

    print_step "Baixando server-icon.png de $MINECRAFT_SERVER_ICON_URL ..."
    if ! download_file "$MINECRAFT_SERVER_ICON_URL" "$MINECRAFT_SERVER_DIR/server-icon.png"; then
        print_warning "Falha ao baixar server-icon. O servidor funciona sem ele."
        return 0
    fi
    print_success "server-icon.png instalado em $MINECRAFT_SERVER_DIR/server-icon.png"
    if command -v file >/dev/null 2>&1; then
        local icon_info
        icon_info=$(file "$MINECRAFT_SERVER_DIR/server-icon.png" 2>/dev/null || true)
        print_step "Tipo do arquivo: $icon_info"
    fi
}

# Direct entrypoint must come AFTER all function declarations. When this file is
# sourced by install.sh, no installation is started here.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_minecraft_install
fi

