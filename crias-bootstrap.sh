#!/bin/bash
# crias-bootstrap.sh
#
# Bootstrap mínimo embutido na ISO do Crias-Server. Baixa a release do GitHub,
# verifica SHA256, extrai e (se no host instalado) roda install.sh.
#
# Fluxo primário (live ISO):
#   1. Boot da ISO → root autologin no tty1 (drop-in getty@tty1.service.d)
#   2. archinstall (instala Arch no disco em /mnt)
#   3. crias-bootstrap          # este script: baixa+verifica+extrai em /mnt/opt/
#   4. reboot
#   5. login com usuário criado no archinstall
#   6. sudo /opt/crias-server/install.sh   # "o comando ao final"
#
# Fluxo fallback (host já instalado, sem ISO):
#   curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash
#   # detecta target=/ , extrai em /opt/crias-server/ e roda install.sh
#
# Variáveis de ambiente:
#   CRIAS_REPO          default: ViniciusLopes7/Crias-Server
#   CRIAS_RELEASE_TAG   default: (vazio = latest) tag específica da release
#   CRIAS_ASSET_ZIP     default: crias-server-slim.zip
#   GITHUB_TOKEN        default: (vazio) auth opcional p/ rate-limit
#   CRIAS_TARGET        default: (auto-detecção) /mnt se montado+Arch, senão /

CRIAS_REPO="${CRIAS_REPO:-ViniciusLopes7/Crias-Server}"
CRIAS_ASSET_ZIP="${CRIAS_ASSET_ZIP:-crias-server-slim.zip}"
CRIAS_ASSET_SHA="${CRIAS_ASSET_SHA:-sha256sums.txt}"

# Cores (respeitam contexto não-TTY via [ -t 2 ]).
if [ -t 2 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

log()  { printf "[CRIAS] %s\n" "$*"; }
ok()   { printf "${GREEN}[CRIAS] ✓ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}[CRIAS][AVISO] %s${NC}\n" "$*" >&2; }
err()  { printf "${RED}[CRIAS][ERRO] %s${NC}\n" "$*" >&2; }

# Detecta se /mnt é um sistema Arch instalado (pós-archinstall).
# Verifica os três marcadores: diretório existente, os-release, e /bin/bash.
# Aceita override via $1 ou CRIAS_TARGET.
crias_detect_target() {
    local override="${1:-${CRIAS_TARGET:-}}"
    if [ -n "$override" ]; then
        printf '%s' "$override"
        return 0
    fi
    if [ -d /mnt ] && [ -f /mnt/etc/os-release ] && [ -e /mnt/bin/bash ]; then
        printf '/mnt'
    else
        printf '/'
    fi
}

# Monta a URL da GitHub API (latest ou tag específica).
crias_api_url() {
    if [ -n "${CRIAS_RELEASE_TAG:-}" ]; then
        printf 'https://api.github.com/repos/%s/releases/tags/%s' "$CRIAS_REPO" "$CRIAS_RELEASE_TAG"
    else
        printf 'https://api.github.com/repos/%s/releases/latest' "$CRIAS_REPO"
    fi
}

# Consulta a GitHub API e extrai browser_download_url dos assets.
# Saída: "<zip_url> <sha_url>" (sha_url pode ser vazia se asset ausente).
crias_fetch_release_urls() {
    local api_url curl_auth=()
    api_url="$(crias_api_url)"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
        --connect-timeout 10 --max-time 60 \
        "${curl_auth[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url" 2>/dev/null || true)
    if [ -z "$response" ]; then
        err "Falha ao consultar GitHub API: $api_url"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        err "jq não encontrado (necessário para parsear a resposta da API)."
        return 1
    fi
    local zip_url sha_url
    zip_url=$(printf '%s' "$response" | jq -r --arg name "$CRIAS_ASSET_ZIP" \
        '.assets[]? | select(.name==$name) | .browser_download_url' | head -n1 || true)
    sha_url=$(printf '%s' "$response" | jq -r --arg name "$CRIAS_ASSET_SHA" \
        '.assets[]? | select(.name==$name) | .browser_download_url' | head -n1 || true)
    if [ -z "$zip_url" ]; then
        err "Asset '$CRIAS_ASSET_ZIP' não encontrado na release."
        err "Verifique https://github.com/$CRIAS_REPO/releases"
        return 1
    fi
    printf '%s %s' "$zip_url" "$sha_url"
}

# Verifica SHA256 do zip contra sha256sums.txt.
# Formato do sha256sums.txt: "<hash>  <filename>"
crias_verify_sha256() {
    local zip_file="$1" sha_file="$2" asset_name="$3"
    if [ ! -f "$sha_file" ]; then
        warn "sha256sums.txt ausente; pulando verificação de integridade."
        return 0
    fi
    local expected_hash actual_hash
    expected_hash=$(grep -E "[[:space:]]+${asset_name}\$" "$sha_file" | awk '{print $1}' | head -n1 || true)
    if [ -z "$expected_hash" ]; then
        warn "Hash de '$asset_name' não encontrado em sha256sums.txt; pulando verificação."
        return 0
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "sha256sum não encontrado; pulando verificação."
        return 0
    fi
    actual_hash=$(sha256sum "$zip_file" | awk '{print $1}')
    if [ "$expected_hash" != "$actual_hash" ]; then
        err "SHA256 mismatch!"
        err "  Esperado: $expected_hash"
        err "  Obtido:  $actual_hash"
        err "Arquivo pode estar corrompido ou comprometido. Abortando."
        return 1
    fi
    ok "SHA256 verificado: $actual_hash"
    return 0
}

# Extrai o zip e sincroniza para o install_dir.
# O zip do GitHub tem um dir top-level (Crias-Server-<tag>/); achamos e copiamos conteúdo.
crias_extract_to() {
    local zip_file="$1" install_dir="$2"
    local extract_dir
    extract_dir=$(mktemp -d -t crias-extract.XXXXXX)
    if ! command -v unzip >/dev/null 2>&1; then
        err "unzip não encontrado (necessário para extrair o zip)."
        rm -rf "$extract_dir"
        return 1
    fi
    if ! unzip -q "$zip_file" -d "$extract_dir"; then
        err "Falha ao extrair o zip."
        rm -rf "$extract_dir"
        return 1
    fi
    local toplevel
    toplevel=$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -n1)
    if [ -z "$toplevel" ]; then
        toplevel="$extract_dir"
    fi
    mkdir -p "$install_dir"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$toplevel/" "$install_dir/"
    else
        cp -a "$toplevel/." "$install_dir/"
    fi
    chmod 0755 "$install_dir/install.sh" 2>/dev/null || true
    find "$install_dir" -name '*.sh' -type f -exec chmod 0755 {} +
    rm -rf "$extract_dir"
    return 0
}

# Lógica principal. Sourceable p/ testes (testa funções acima isoladamente).
crias_bootstrap_main() {
    local target
    target="$(crias_detect_target "${1:-}")"
    local install_dir="${target%/}/opt/crias-server"
    log "Target: $target"
    log "Install dir: $install_dir"

    if ! command -v curl >/dev/null 2>&1; then
        err "curl não encontrado. Instale: sudo pacman -S curl"
        return 1
    fi

    # Instala jq e unzip se faltando (necessários para parsear JSON + extrair zip)
    local missing_deps=""
    command -v jq >/dev/null 2>&1 || missing_deps="$missing_deps jq"
    command -v unzip >/dev/null 2>&1 || missing_deps="$missing_deps unzip"
    if [ -n "$missing_deps" ]; then
        log "Instalando dependências:$missing_deps ..."
        if [ "$(id -u)" -eq 0 ]; then
            pacman -S --needed --noconfirm $missing_deps >/dev/null 2>&1 || {
                err "Falha ao instalar:$missing_deps. Rode: sudo pacman -S$missing_deps"
                return 1
            }
        else
            sudo pacman -S --needed --noconfirm $missing_deps >/dev/null 2>&1 || {
                err "Falha ao instalar:$missing_deps. Rode: sudo pacman -S$missing_deps"
                return 1
            }
        fi
        ok "Dependências instaladas:$missing_deps"
    fi

    log "Verificando conectividade com github.com..."
    if ! curl -fsSL --connect-timeout 10 https://github.com >/dev/null 2>&1; then
        err "Sem internet. Conecte e tente novamente."
        return 1
    fi

    log "Consultando release no GitHub..."
    local urls zip_url sha_url
    if ! urls="$(crias_fetch_release_urls)"; then
        err "Não foi possível obter URLs dos assets da release."
        err "Fallback: git clone https://github.com/$CRIAS_REPO && cd Crias-Server && sudo ./install.sh"
        return 1
    fi
    zip_url="${urls%% *}"
    sha_url="${urls#* }"
    [ "$sha_url" = "$zip_url" ] && sha_url=""
    log "Zip URL: $zip_url"

    local tmpdir
    tmpdir=$(mktemp -d -t crias-bootstrap.XXXXXX)
    trap 'rm -rf -- "$tmpdir"' RETURN

    local zip_file="$tmpdir/$CRIAS_ASSET_ZIP"
    local sha_file="$tmpdir/$CRIAS_ASSET_SHA"

    log "Baixando $CRIAS_ASSET_ZIP..."
    if ! curl -fSL --retry 3 --retry-delay 2 --retry-all-errors \
        --connect-timeout 30 --max-time 300 \
        -o "$zip_file" "$zip_url"; then
        err "Falha ao baixar $zip_url"
        return 1
    fi

    if [ -n "$sha_url" ]; then
        log "Baixando $CRIAS_ASSET_SHA..."
        if ! curl -fSL --retry 3 --retry-delay 2 \
            --connect-timeout 30 --max-time 60 \
            -o "$sha_file" "$sha_url"; then
            warn "Falha ao baixar sha256sums.txt; pulando verificação."
        fi
    fi

    if ! crias_verify_sha256 "$zip_file" "$sha_file" "$CRIAS_ASSET_ZIP"; then
        return 1
    fi

    log "Extraindo para $install_dir..."
    if ! crias_extract_to "$zip_file" "$install_dir"; then
        return 1
    fi
    ok "Arquivos extraídos em $install_dir"

    if [ "$target" = "/mnt" ]; then
        # Live ISO com /mnt montado (archinstall ainda em andamento).
        # Não roda install.sh aqui — o usuário deve rebootar primeiro
        # e rodar o curl no sistema instalado.
        echo ""
        ok "Repo extraído em /mnt/opt/crias-server/."
        warn "Você está na live ISO com /mnt montado."
        warn "Reboot primeiro, faça login, e rode:"
        warn "  curl -fsSL https://raw.githubusercontent.com/$CRIAS_REPO/main/crias-bootstrap.sh | sudo bash"
        return 0
    fi

    # Host instalado (pós-reboot): roda install.sh direto.
    log "Rodando install.sh no host atual..."
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$install_dir/install.sh"
    else
        "$install_dir/install.sh"
    fi
}

# Só roda a main quando executado (não quando sourceado por testes).
# `return 0` só funciona em contexto de source; falha quando executado/piped.
# Funciona com: ./crias-bootstrap.sh, bash crias-bootstrap.sh, curl ... | bash
if ! (return 0 2>/dev/null); then
    set -euo pipefail
    crias_bootstrap_main "$@"
fi
