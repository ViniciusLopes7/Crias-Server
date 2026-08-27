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

        if http_code=$(curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 10 \
            --max-time 300 \
            -w '%{http_code}' \
            -o "$output" \
            "$url" 2>/dev/null); then
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

    tmpfile=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f -- "$tmpfile"' RETURN
    mkdir -p "$(dirname "$dest")"

    if ! _curl_with_retry "$url" "$tmpfile"; then
        print_error "Falha ao baixar $url"
        rm -f "$tmpfile"
        return 1
    fi

    install -m 0644 "$tmpfile" "$dest"
    rm -f "$tmpfile"
    return 0
}

# Download a Modrinth mod with retry. Wraps API query + file download.
# Usage: download_modrinth_mod <slug> <loader> <game_version> <dest_dir> <file_name>
# Returns 0 on success, 1 on failure.
#
# Delega para mc_fetch_modrinth_project_versions (mc-manifests.sh) que usa
# mc_curl_get (com User-Agent obrigatório) e jq -c -n para URL encoding correto.
download_modrinth_mod() {
    local slug="$1"
    local loader="$2"
    local game_version="$3"
    local dest_dir="$4"
    local file_name="$5"

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
    local json mod_url
    json=$(mc_fetch_modrinth_project_versions "$slug" "$loader" "$game_version") || true

    if [ -z "$json" ] || [ "$json" = "[]" ]; then
        # Fallback: busca sem filtro de game_version (só loader).
        json=$(mc_fetch_modrinth_project_versions "$slug" "$loader" "") || true
    fi

    # Extrai URL do primeiro arquivo da primeira versão.
    mod_url=$(printf '%s' "$json" | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)

    if [ -z "$mod_url" ]; then
        print_warning "Nao foi possivel baixar o mod: $file_name"
        return 1
    fi

    mkdir -p "$dest_dir"
    if ! download_file "$mod_url" "$dest_dir/${file_name}.jar"; then
        print_warning "Falha ao baixar mod: ${file_name}, pulando."
        return 1
    fi

    print_success "Mod instalado: ${file_name}.jar"
    return 0
}
