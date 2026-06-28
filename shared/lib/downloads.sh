#!/bin/bash
# shared/lib/downloads.sh
#
# Helper para downloads com verificação SHA256 (OBRIGATÓRIO por padrão),
# retry com backoff exponencial, e suporte a DRY_RUN.
#
# Itens do plano atendidos:
#   S2 - SHA256 obrigatório (require_checksum=true como default)
#   S4 - DRY_RUN previne requisições de rede
#   Supply chain - retry com backoff para 429/5xx
#
# Uso:
#   download_and_verify <url> <dest> <sha_env_var> [require_checksum]
#
#   - <sha_env_var>: nome da variável de ambiente contendo o SHA256 esperado.
#   - require_checksum: "true" (default) para falhar quando checksum ausente.
#                       "false" para permiter download sem verificação.

# ---------------------------------------------------------------------------
# Verifica se devemos pular rede em DRY_RUN.
# ---------------------------------------------------------------------------
should_skip_network() {
    if is_true "${DRY_RUN:-false}"; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Faz o curl com retry exponencial para 429/5xx e timeouts sane.
# Retorna 0 em sucesso, não-zero em falha definitiva.
# ---------------------------------------------------------------------------
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

        # -f: fail em HTTP 4xx/5xx (sem body de erro)
        # -S: show errors
        # -s: silent
        # -L: follow redirects
        # --retry: retry transient errors (DNS, timeout)
        # --retry-all-errors: inclui HTTP 5xx no retry interno do curl
        # --connect-timeout: limite para conectar
        # --max-time: limite total
        if http_code=$(curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 10 \
            --max-time 300 \
            -w '%{http_code}' \
            -o "$output" \
            "$url" 2>/dev/null); then
            # Sucesso
            return 0
        fi

        # Falha: distinguir 429/5xx (retry) de 4xx definitivo (aborta)
        case "$http_code" in
            429|500|502|503|504)
                # Retryable
                print_warning "HTTP $http_code em tentativa $attempt (retryable)"
                ;;
            0|"")
                # Erro de rede/DNS — curl já tentou internamente
                print_warning "Erro de rede em tentativa $attempt"
                ;;
            *)
                # 4xx não-retryable
                print_error "HTTP $http_code (nao-retryable); abortando."
                return 1
                ;;
        esac

        attempt=$((attempt + 1))
    done

    print_error "Falha apos $max_attempts tentativas: $url"
    return 1
}

# ---------------------------------------------------------------------------
# Função principal: baixa, verifica SHA256, move para destino.
# Retorna:
#   0 - sucesso
#   1 - falha de rede
#   2 - checksum inválido
#   3 - checksum obrigatório ausente
#   4 - checksum com formato inválido
# ---------------------------------------------------------------------------
download_and_verify() {
    local url="$1"
    local dest="$2"
    local sha_env_var="$3"
    local require_checksum="${4:-true}"
    local tmpfile

    # S4: DRY_RUN previne requisições de rede.
    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download de $url"
        # Não cria arquivo: callers em DRY_RUN devem checar DRY_RUN antes
        # de depender do arquivo. Esta função apenas sinaliza skip.
        return 0
    fi

    tmpfile=$(mktemp)
    mkdir -p "$(dirname "$dest")"

    if ! _curl_with_retry "$url" "$tmpfile"; then
        print_error "Falha ao baixar $url"
        rm -f "$tmpfile"
        return 1
    fi

    # S2: checksum é obrigatório por default.
    if [ -z "$sha_env_var" ] || [ -z "${!sha_env_var:-}" ]; then
        if [ "$require_checksum" = "true" ]; then
            print_error "Checksum SHA256 obrigatorio nao fornecido para $url"
            print_error "Defina ${sha_env_var:-<SHA_ENV_VAR>} (64 hex) em config.env ou exporte no ambiente."
            print_error "Para permitir download sem verificacao (NAO recomendado), passe require_checksum=false."
            rm -f "$tmpfile"
            return 3
        fi

        print_warning "Nenhum checksum SHA256 fornecido para $url; procedendo sem verificacao (NAO RECOMENDADO)"
        mv "$tmpfile" "$dest"
        return 0
    fi

    local expected
    expected="${!sha_env_var}"
    if ! [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]]; then
        print_error "Checksum SHA256 invalido em ${sha_env_var}: '$expected' (esperado: 64 hex)"
        rm -f "$tmpfile"
        return 4
    fi

    local actual
    actual=$(sha256sum "$tmpfile" | awk '{print $1}')
    if [ "${expected,,}" != "${actual,,}" ]; then
        print_error "Checksum SHA256 invalido para $url"
        print_error "esperado: $expected"
        print_error "obtido:   $actual"
        rm -f "$tmpfile"
        return 2
    fi

    mv "$tmpfile" "$dest"
    return 0
}

# ---------------------------------------------------------------------------
# Helper para baixar mod do Modrinth com retry.
# Encapsula a lógica de consulta à API + download do arquivo.
# Uso: download_modrinth_mod <slug> <loader> <game_version> <dest_dir> <file_name> [sha_env_var]
# Retorna 0 se baixou com sucesso, 1 caso contrário (caller pode continuar).
# ---------------------------------------------------------------------------
download_modrinth_mod() {
    local slug="$1"
    local loader="$2"
    local game_version="$3"
    local dest_dir="$4"
    local file_name="$5"
    local sha_env_var="${6:-}"

    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download do mod $slug"
        return 0
    fi

    local api_url
    local mod_url

    # Primeira tentativa: filtra por loader + game_version.
    api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22${loader}%22%5D&game_versions=%5B%22${game_version}%22%5D"
    mod_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)

    # Fallback: sem filtro de game_version.
    if [ -z "$mod_url" ]; then
        api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22${loader}%22%5D"
        mod_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)
    fi

    if [ -z "$mod_url" ]; then
        print_warning "Nao foi possivel baixar o mod: $file_name"
        return 1
    fi

    mkdir -p "$dest_dir"
    if ! download_and_verify "$mod_url" "$dest_dir/${file_name}.jar" "$sha_env_var"; then
        print_warning "Falha ao baixar/validar mod: ${file_name}, pulando."
        return 1
    fi

    print_success "Mod instalado: ${file_name}.jar"
    return 0
}
