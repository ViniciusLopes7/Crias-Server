#!/bin/bash

# Helper para downloads com verificação SHA256 (opcional por padrao).
# Uso: download_and_verify <url> <dest> <sha_env_var> [require_checksum]
# - <sha_env_var>: nome da variavel de ambiente contendo o SHA256 esperado.
# - require_checksum: "true" para falhar quando checksum estiver ausente.

download_and_verify() {
    local url="$1"
    local dest="$2"
    local sha_env_var="$3"
    local require_checksum="${4:-false}"
    local tmpfile

    tmpfile=$(mktemp)
    mkdir -p "$(dirname "$dest")"

    if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 300 -o "$tmpfile" "$url"; then
        print_error "Falha ao baixar $url"
        rm -f "$tmpfile"
        return 1
    fi

    if [ -z "$sha_env_var" ] || [ -z "${!sha_env_var:-}" ]; then
        if [ "$require_checksum" = "true" ]; then
            print_error "Checksum SHA256 obrigatorio nao fornecido para $url"
            print_error "Defina ${sha_env_var:-<SHA_ENV_VAR>} (64 hex) em config.env ou exporte no ambiente."
            rm -f "$tmpfile"
            return 3
        fi

        print_warning "Nenhum checksum SHA256 fornecido para $url; procedendo sem verificacao"
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
