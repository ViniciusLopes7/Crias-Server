#!/bin/bash

# Helper para downloads com verificação SHA256 opcional.
# Uso: download_and_verify <url> <dest> <sha_env_var>
# Se <sha_env_var> estiver vazio ou não definida, faz o download e emite um WARNING.

download_and_verify() {
    local url="$1"
    local dest="$2"
    local sha_env_var="$3"
    local tmpfile

    tmpfile=$(mktemp)

    if ! curl -fsSL --connect-timeout 10 --max-time 300 -o "$tmpfile" "$url"; then
        print_error "Falha ao baixar $url"
        rm -f "$tmpfile"
        return 1
    fi

    if [ -n "$sha_env_var" ] && [ -n "${!sha_env_var:-}" ]; then
        local expected
        expected="${!sha_env_var}"
        local actual
        actual=$(sha256sum "$tmpfile" | awk '{print $1}')
        if [ "$expected" != "$actual" ]; then
            print_error "Checksum SHA256 inválido para $url"
            print_error "esperado: $expected"
            print_error "obtido:   $actual"
            rm -f "$tmpfile"
            return 2
        fi
    else
        print_warning "Nenhum checksum SHA256 fornecido para $url; procedendo sem verificação"
    fi

    mv "$tmpfile" "$dest"
    return 0
}
