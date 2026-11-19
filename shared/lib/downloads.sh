#!/bin/bash
# shared/lib/downloads.sh
#
# Download helper with retry/backoff and DRY_RUN support.

# Skip network in DRY_RUN.
should_skip_network() {
    if is_true "${DRY_RUN:-false}"; then
        return 0
    fi
    return 1
}

# Executa `curl "$@"` sob spinner do gum quando o stderr é um TTY interativo,
# ou curl puro com stderr suprimido quando não (CI/logs não podem receber os
# escapes ANSI do spinner). O gum spin renderiza em stderr, propaga o exit code
# do curl e, com --show-output, devolve o stdout do comando ao término — por isso
# o `-w '%{http_code}'` continua capturável via $(). O meter nativo do curl não
# polui a tela: o -s (em -fsSL) já o suprime; erros do -S seguem no stderr e são
# a única coisa que o usuário vê quando o download falha.
curl_with_progress() {
    local title="$1"
    shift
    if command -v gum >/dev/null 2>&1 && [ -t 2 ]; then
        gum spin --spinner dot --show-output --title "$title" -- \
            curl "$@"
    else
        curl "$@" 2>/dev/null
    fi
}

# curl with exponential backoff for 429/5xx and sane timeouts.
_curl_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts="${DOWNLOAD_MAX_ATTEMPTS:-4}"
    local base_delay="${DOWNLOAD_BASE_DELAY:-2}"
    local attempt=1
    local delay="$base_delay"
    local http_code

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            print_warning "Tentativa $attempt/$max_attempts apos ${delay}s (backoff)..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        if http_code=$(curl_with_progress "Baixando ${url##*/}..." \
            -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 10 \
            --max-time 300 \
            -w '%{http_code}' \
            -o "$output" \
            "$url"); then
            return 0
        fi

        case "$http_code" in
            429|500|502|503|504)
                print_warning "HTTP $http_code em tentativa $attempt (retryable)"
                ;;
            0|"")
                print_warning "Erro de rede em tentativa $attempt"
                ;;
            *)
                print_error "HTTP $http_code (nao-retryable); abortando."
                return 1
                ;;
        esac

        attempt=$((attempt + 1))
    done

    print_error "Falha apos $max_attempts tentativas: $url"
    return 1
}

# Download a file with retry. Creates parent directory if needed.
# Usage: download_file <url> <dest>
# Returns: 0=success, 1=failure
download_file() {
    local url="$1"
    local dest="$2"
    local tmpfile

    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download de $url"
        return 0
    fi

    tmpfile=$(mktemp_crias_file)
    mkdir -p "$(dirname "$dest")"

    if ! _curl_with_retry "$url" "$tmpfile"; then
        print_error "Falha ao baixar $url"
        return 1
    fi

    install -m 0644 "$tmpfile" "$dest"
    return 0
}

# Download a Modrinth mod with retry. Wraps API query + file download.
# Usage: download_modrinth_mod <slug> <loader> <game_version> <dest_dir> <file_name> [expected_sha256_var]
# Returns 0 on success, 1 on failure.
#
# Delega para mc_fetch_modrinth_project_versions (mc-manifests.sh) que usa
# mc_curl_get (com User-Agent obrigatório) e jq -c -n para URL encoding correto.
#
# (CR-10) Nao existe mais fallback sem filtro de versao: a busca anterior
# caia para "qualquer versao com o loader" e baixava mod incompativel com a
# versao em execucao. Versao incompativel = pendencia relatada, nao download
# as cegas.
#
# (EXP-52) Seleciona o arquivo marcado primary=true com extensao .jar (o
# files[0] podia pegar arquivo secundario/cliente). (EXP-48) Verifica o hash
# sha1/sha512 do arquivo contra o manifesto da API e o sha256 opcional
# fixado pelo caller via MOD_*_SHA256 — download truncado/adulterado nao
# vira mod "instalado".
download_modrinth_mod() {
    local slug="$1"
    local loader="$2"
    local game_version="$3"
    local dest_dir="$4"
    local file_name="$5"
    local expected_sha_var="${6:-}"

    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download do mod $slug"
        return 0
    fi

    # Usa mc_fetch_modrinth_project_versions (mc-manifests.sh) que inclui
    # User-Agent e URL encoding correto. Se a lib não estiver carregada, source.
    if ! declare -F mc_fetch_modrinth_project_versions >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$(dirname "${BASH_SOURCE[0]}")/mc-manifests.sh"
    fi

    # Busca versões compatíveis (server-side filter por loader + game_version).
    local json
    json=$(mc_fetch_modrinth_project_versions "$slug" "$loader" "$game_version") || true

    if [ -z "$json" ] || [ "$json" = "[]" ]; then
        print_warning "Mod '$slug': nenhuma versao compativel com $loader $game_version (sem fallback de versao — CR-10)."
        return 1
    fi

    # (EXP-52) Arquivo primary=true com .jar; fallback: primeiro .jar da versao.
    local file_json mod_url expected_sha1 expected_sha512
    file_json=$(printf '%s' "$json" | jq -c '
        .[0].files
        | (map(select(.primary == true and (.filename | endswith(".jar")))) | .[0])
          // (map(select(.filename | endswith(".jar"))) | .[0])
        // empty
    ' 2>/dev/null || true)

    if [ -z "$file_json" ]; then
        print_warning "Mod '$slug': nenhum arquivo .jar na versao retornada."
        return 1
    fi

    mod_url=$(printf '%s' "$file_json" | jq -r '.url // empty' 2>/dev/null || true)
    expected_sha1=$(printf '%s' "$file_json" | jq -r '.hashes.sha1 // empty' 2>/dev/null || true)
    expected_sha512=$(printf '%s' "$file_json" | jq -r '.hashes.sha512 // empty' 2>/dev/null || true)

    if [ -z "$mod_url" ]; then
        print_warning "Nao foi possivel baixar o mod: $file_name"
        return 1
    fi

    mkdir -p "$dest_dir"
    if ! download_file "$mod_url" "$dest_dir/${file_name}.jar"; then
        print_warning "Falha ao baixar mod: ${file_name}, pulando."
        return 1
    fi

    # (EXP-48) Verificacao de integridade do JAR baixado contra os hashes da
    # API. Falha remove o arquivo — um jar truncado nao pode permanecer em
    # mods/ como se fosse um mod instalado.
    local dest_file="$dest_dir/${file_name}.jar"
    if [ -n "$expected_sha1" ] && command -v sha1sum >/dev/null 2>&1; then
        local actual_sha1
        actual_sha1="$(sha1sum "$dest_file" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_sha1" != "$expected_sha1" ]; then
            print_warning "Mod '$file_name': sha1 divergente (esperado ${expected_sha1:0:12}..., obtido ${actual_sha1:0:12}...); removendo."
            rm -f "$dest_file"
            return 1
        fi
    fi
    if [ -n "$expected_sha512" ] && command -v sha512sum >/dev/null 2>&1; then
        local actual_sha512
        actual_sha512="$(sha512sum "$dest_file" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_sha512" != "$expected_sha512" ]; then
            print_warning "Mod '$file_name': sha512 divergente; removendo."
            rm -f "$dest_file"
            return 1
        fi
    fi

    # (EXP-48) Hash sha256 opcional fixado pelo caller (MOD_*_SHA256 no
    # config.env) — pin forte do operador.
    if [ -n "$expected_sha_var" ] && [ -n "${!expected_sha_var:-}" ]; then
        local expected_sha256="${!expected_sha_var}"
        local actual_sha256=""
        if command -v sha256sum >/dev/null 2>&1; then
            actual_sha256="$(sha256sum "$dest_file" 2>/dev/null | awk '{print $1}')"
        fi
        if [ -z "$actual_sha256" ] || [ "$actual_sha256" != "$expected_sha256" ]; then
            print_warning "Mod '$file_name': sha256 fixado ($expected_sha_var) divergente; removendo."
            rm -f "$dest_file"
            return 1
        fi
    fi

    print_success "Mod instalado: ${file_name}.jar (hash verificado)"
    return 0
}
