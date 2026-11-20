#!/bin/bash
# crias-bootstrap.sh
#
# Bootstrap mínimo do Crias-Server. Baixa a release do GitHub, verifica SHA256
# (fail-closed), extrai e (se no host instalado) roda install.sh.
#
# NOTA (DOC-09): a ISO customizada foi descontinuada — o caminho com /mnt abaixo
# é compatibilidade com mídias antigas que ainda embutem este script. O fluxo
# suportado atualmente é o fallback em host já instalado:
#   curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash
#   # detecta target=/ , extrai em /opt/crias-server/ e roda install.sh
#
# Fluxo legado (live ISO antiga, se /mnt montado por archinstall):
#   1. Boot da ISO → root autologin no tty1
#   2. archinstall (instala Arch no disco em /mnt)
#   3. crias-bootstrap          # este script: baixa+verifica+extrai em /mnt/opt/
#   4. reboot e seguir o fallback acima
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
    local auth_hdr_file=""
    api_url="$(crias_api_url)"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        # (EXP-64) Token fora do argv do curl: linhas de comando sao
        # observaveis via /proc/<pid>/cmdline em hosts com procfs aberto.
        # -H @arquivo le o header de um arquivo privado 0600 (curl >= 7.55).
        auth_hdr_file="$(mktemp /tmp/crias-auth.XXXXXX)" || return 1
        chmod 600 "$auth_hdr_file"
        printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$auth_hdr_file"
        curl_auth=(-H "@${auth_hdr_file}")
    fi
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
        --connect-timeout 10 --max-time 60 \
        "${curl_auth[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url" 2>/dev/null || true)
    # (EXP-64) Remove o arquivo de header imediatamente apos o uso.
    if [ -n "$auth_hdr_file" ]; then
        rm -f "$auth_hdr_file"
    fi

    # (EXP-40) Transparencia da release: registrar tag e commit-alvo da
    # release consultada — main pode estar a frente da latest, e o operador
    # precisa saber O QUE esta instalando antes de rodar install.sh.
    CRIAS_RELEASE_TAG_NAME="$(printf '%s' "$response" | jq -r '.tag_name // "desconhecida"' 2>/dev/null || echo desconhecida)"
    CRIAS_RELEASE_TARGET="$(printf '%s' "$response" | jq -r '.target_commitish // "desconhecido"' 2>/dev/null || echo desconhecido)"
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
    CRIAS_ZIP_URL="$zip_url"
    CRIAS_SHA_URL="$sha_url"
}

# Verifica SHA256 do zip contra sha256sums.txt.
# Formato do sha256sums.txt: "<hash>  <filename>"
# Fail-closed (CR-17): checksum ausente/nao listado/ferramenta indisponivel
# ABORTEM o bootstrap — antes cada um desses casos virava `warn + return 0`
# e o zip nao-verificado era extraido e executado. HTTPS protege a
# transmissao, nao a integridade do asset publicado.
crias_verify_sha256() {
    local zip_file="$1" sha_file="$2" asset_name="$3"
    if [ ! -f "$sha_file" ]; then
        err "sha256sums.txt ausente; a integridade do download NAO pode ser verificada."
        err "Verifique a release manualmente em https://github.com/$CRIAS_REPO/releases"
        return 1
    fi
    local expected_hash actual_hash
    expected_hash=$(grep -E "[[:space:]]+(\./)?${asset_name}\$" "$sha_file" | awk '{print $1}' | head -n1 || true)
    if [ -z "$expected_hash" ]; then
        err "Hash de '$asset_name' não encontrado em sha256sums.txt."
        err "A release publicada pode estar incompleta. Abortando."
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        err "sha256sum não encontrado no sistema; nao e possivel verificar a integridade."
        err "Instale coreutils (ou equivalente) e rode o bootstrap novamente."
        return 1
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

# Extrai o zip e instala de forma TRANSACIONAL (CR-16): a nova versao vai
# para um diretorio versionado em <install_dir>.releases/<timestamp>; a
# troca final e um symlink atomico. Uma atualizacao interrompida nunca
# deixa /opt/crias-server com mistura de versoes — a versao antiga fica
# intacta em .releases/ ate a limpeza (mantem as 3 mais recentes).
# Suporta 2 formatos de zip:
#   1. CI release zip: arquivos na raiz (install.sh, config.env, shared/, ...)
#   2. GitHub auto zip: diretório top-level (Crias-Server-<tag>/) com arquivos dentro
crias_extract_to() {
    local zip_file="$1" install_dir="$2"
    local extract_dir
    extract_dir="$(mktemp -d /tmp/crias-extract.XXXXXX)" || return 1
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

    # Determina de onde copiar: raiz do extract_dir ou diretório top-level
    local src_dir="$extract_dir"
    if [ ! -f "$extract_dir/install.sh" ]; then
        # install.sh não está na raiz — procura num diretório top-level
        local toplevel
        toplevel=$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d -exec test -f '{}/install.sh' \; -print -quit 2>/dev/null || true)
        if [ -n "$toplevel" ]; then
            src_dir="$toplevel"
        else
            err "install.sh não encontrado no zip (estrutura não reconhecida)."
            ls -la "$extract_dir/" >&2
            rm -rf "$extract_dir"
            return 1
        fi
    fi

    # (CR-16) Deploy versionado + symlink atomico.
    local releases_root="${install_dir}.releases"
    local new_dir legacy_dir=""
    mkdir -p "$releases_root"
    new_dir="$(mktemp -d "$releases_root/release.XXXXXXXX")"

    if ! cp -a "$src_dir/." "$new_dir/"; then
        err "Falha ao copiar a nova versao para $new_dir."
        rm -rf "$new_dir" "$extract_dir"
        return 1
    fi
    rm -rf "$extract_dir"

    chmod 0755 "$new_dir/install.sh" 2>/dev/null || true
    find "$new_dir" -name '*.sh' -type f -exec chmod 0755 {} +

    # Migracao: install_dir real (nao-symlink) legado vira uma release.
    if [ -d "$install_dir" ] && [ ! -L "$install_dir" ]; then
        legacy_dir="$(mktemp -d "$releases_root/legacy.XXXXXXXX")"
        rmdir "$legacy_dir"
        if ! mv "$install_dir" "$legacy_dir"; then
            err "Falha ao arquivar a instalacao legada ($install_dir)."
            rm -rf "$new_dir"
            return 1
        fi
        ok "Instalacao legada arquivada em $legacy_dir"
    fi

    # Symlink atomico: cria em temporario e renomeia por cima.
    local tmp_link="$releases_root/.crias-link.$$"
    rm -f "$tmp_link"
    if ! ln -s "$new_dir" "$tmp_link"; then
        err "Falha ao criar symlink temporario."
        rm -rf "$new_dir"
        _crias_restore_legacy "$install_dir" "$legacy_dir" || true
        return 1
    fi
    if ! mv -T "$tmp_link" "$install_dir"; then
        err "Falha ao publicar o symlink $install_dir."
        rm -f "$tmp_link"
        rm -rf "$new_dir"
        # (AUDIT-A P3-9) A instalacao antiga foi arquivada em legacy-* acima;
        # devolve o diretorio real para nao deixar o host sem /opt/crias-server.
        _crias_restore_legacy "$install_dir" "$legacy_dir" || true
        return 1
    fi

    # Limpeza: mantem as 3 versoes mais recentes em .releases (rollback).
    # (AUDIT-A P3-10) O destino ATUAL do symlink nunca entra na lista de
    # remocao — um rollback manual do symlink para uma release antiga nao
    # pode perder a versao em uso na proxima atualizacao.
    local current_target
    current_target="$(readlink -f "$install_dir" 2>/dev/null || true)"
    local old_release kept=0
    while IFS= read -r old_release; do
        [ -z "$old_release" ] && continue
        [ "$(readlink -f "$old_release")" = "$current_target" ] && continue
        kept=$((kept + 1))
        [ "$kept" -le 2 ] && continue
        rm -rf -- "$old_release" 2>/dev/null || true
    done < <(ls -1dt "$releases_root"/release.* "$releases_root"/[0-9]* "$releases_root"/legacy.* "$releases_root"/legacy-* 2>/dev/null || true)

    return 0
}

# (AUDIT-A P3-9) Restaura a instalacao legada arquivada quando a publicacao
# do symlink falha — o host nao pode ficar sem $install_dir.
_crias_restore_legacy() {
    local install_dir="$1" legacy_dir="$2"
    [ -n "$legacy_dir" ] || return 1
    if [ -d "$legacy_dir" ] && [ ! -e "$install_dir" ]; then
        if mv "$legacy_dir" "$install_dir"; then
            ok "Instalacao legada restaurada em $install_dir"
            return 0
        fi
    fi
    return 1
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

    # Reconecta stdin ao terminal (curl|bash não fornece TTY em stdin,
    # fazendo tui_available() falhar e todos os prompts auto-aceitarem defaults).
    # O 2>/dev/null precisa ficar restrito ao subshell de teste: redirecionamentos
    # em `exec` sem comando persistem no shell atual, e suprimir o stderr aqui
    # mataria o TUI do install.sh filho (o gum renderiza em stderr).
    if (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty || true
    fi

    # Instala jq, unzip e gum se faltando
    local missing_deps=""
    command -v jq >/dev/null 2>&1 || missing_deps="$missing_deps jq"
    command -v unzip >/dev/null 2>&1 || missing_deps="$missing_deps unzip"
    command -v gum >/dev/null 2>&1 || missing_deps="$missing_deps gum"
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
    local zip_url sha_url
    if ! crias_fetch_release_urls; then
        err "Não foi possível obter URLs dos assets da release."
        err "Fallback: git clone https://github.com/$CRIAS_REPO && cd Crias-Server && sudo ./install.sh"
        return 1
    fi

    # (EXP-40) Mostra O QUE vai ser instalado. main pode estar a frente da
    # release latest (correções no main só chegam ao curl|bash quando uma nova
    # release e publicada); para pinar, use CRIAS_RELEASE_TAG=<tag>.
    if [ -n "${CRIAS_RELEASE_TAG_NAME:-}" ]; then
        log "Release que sera instalada: ${CRIAS_RELEASE_TAG_NAME} (alvo: ${CRIAS_RELEASE_TARGET:-desconhecido})"
        warn "main pode estar AHEAD da release latest; veja https://github.com/$CRIAS_REPO/releases para pinar uma tag (CRIAS_RELEASE_TAG)."
    fi
    zip_url="$CRIAS_ZIP_URL"
    sha_url="$CRIAS_SHA_URL"
    log "Zip URL: $zip_url"

    local tmpdir
    tmpdir="$(mktemp -d /tmp/crias-bootstrap.XXXXXX)" || return 1
    trap 'rm -rf -- "$tmpdir"' RETURN

# O bootstrap nunca usa TMPDIR externo (pode ser um diretorio controlado
    # por outro usuario durante execucao privilegiada).
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
            # Fail-closed (CR-17): sem o sha256sums.txt o zip nao pode ser
            # verificado — abortar em vez de prosseguir sem verificacao.
            err "Falha ao baixar sha256sums.txt de $sha_url"
            err "Sem o checksum a integridade do zip nao pode ser verificada. Abortando."
            return 1
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
