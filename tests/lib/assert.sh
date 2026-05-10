#!/bin/bash
set -euo pipefail

assert_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "[assert] Arquivo esperado nao encontrado: $path" >&2
        exit 1
    fi
}

assert_executable() {
    local path="$1"
    if [ ! -x "$path" ]; then
        echo "[assert] Arquivo esperado nao esta executavel: $path" >&2
        exit 1
    fi
}

assert_grep() {
    local pattern="$1"
    local path="$2"

    assert_file "$path"

    if ! grep -Eq "$pattern" "$path"; then
        echo "[assert] Padrao nao encontrado em $path: $pattern" >&2
        exit 1
    fi
}

assert_not_grep() {
    local pattern="$1"
    local path="$2"

    assert_file "$path"

    if grep -Eq "$pattern" "$path"; then
        echo "[assert] Padrao inesperado encontrado em $path: $pattern" >&2
        exit 1
    fi
}

assert_grep_fixed() {
    local pattern="$1"
    local path="$2"

    assert_file "$path"

    if ! grep -Fq "$pattern" "$path"; then
        echo "[assert] Texto literal nao encontrado em $path: $pattern" >&2
        exit 1
    fi
}

assert_not_grep_fixed() {
    local pattern="$1"
    local path="$2"

    assert_file "$path"

    if grep -Fq "$pattern" "$path"; then
        echo "[assert] Texto literal inesperado em $path: $pattern" >&2
        exit 1
    fi
}

assert_bash_syntax() {
    local path="$1"
    bash -n "$path"
}

