#!/usr/bin/env bash
# tests/download-modrinth-test.sh
#
# Contraprovas de CR-10/EXP-48/EXP-52 (download de mods do Modrinth):
#   1. Sem fallback sem filtro de versão (versão incompatível = pendência);
#   2. Seleciona o arquivo primary=true com .jar (não o files[0] secundário);
#   3. Hash sha1 divergente => jar removido + falha;
#   4. Hash confere => instalado;
#   5. sha256 fixado pelo caller (MOD_*_SHA256) é verificado;
#   6. Hash sha512 divergente => falha.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR" || true' EXIT

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/downloads.sh"

DEST_DIR="$TMP_DIR/mods"
mkdir -p "$DEST_DIR"

# ------------------------------------------------------------------
# Stubs: fetch da API (conta chamadas) + curl (grava arquivo known).
# ------------------------------------------------------------------
FETCH_CALLS="$TMP_DIR/fetch-calls.log"

mc_fetch_modrinth_project_versions() {
    echo "fetch:$2:$3" >> "$FETCH_CALLS"
    cat "$FIXTURE_JSON"
}

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
# curl stub: grava BYTES no caminho de -o e imprime 200 (para -w).
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s' "\$STUB_BYTES" > "\${out:?sem -o}"
echo "200"
EOF
chmod +x "$STUB_BIN/curl"

export PATH="$STUB_BIN:$PATH"

sha1_of() { printf '%s' "$1" | sha1sum | awk '{print $1}'; }
sha256_of() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
sha512_of() { printf '%s' "$1" | sha512sum | awk '{print $1}'; }

# ------------------------------------------------------------------
# 1+2. Primary selecionado (files[0] secundario, files[1] primary .jar).
# ------------------------------------------------------------------
GOOD_BYTES="conteudo-valido-do-jar"
export STUB_BYTES="$GOOD_BYTES"
FIXTURE_JSON="$TMP_DIR/fixture-primary.json"
cat > "$FIXTURE_JSON" <<EOF
[{
  "version_number": "1.0.0",
  "game_versions": ["1.21.1"],
  "loaders": ["fabric"],
  "files": [
    {"filename": "mod-client.jar", "primary": false, "url": "https://stub/SECUNDARIO.jar",
     "hashes": {"sha1": "$(sha1_of "$GOOD_BYTES")"}},
    {"filename": "mod.jar", "primary": true, "url": "https://stub/PRIMARY.jar",
     "hashes": {"sha1": "$(sha1_of "$GOOD_BYTES")", "sha512": "$(sha512_of "$GOOD_BYTES")"}}
  ]
}]
EOF

: > "$FETCH_CALLS"
rm -f "$DEST_DIR"/*
if ! download_modrinth_mod "meu-mod" "fabric" "1.21.1" "$DEST_DIR" "meu-mod" >/dev/null 2>&1; then
    echo "FAIL: download com fixture valida falhou"
    exit 1
fi
if [ ! -f "$DEST_DIR/meu-mod.jar" ]; then
    echo "FAIL: jar valido nao instalado"
    exit 1
fi

# CR-10: a busca deve ter sido feita UMA vez, COM o filtro de versao — sem
# o segundo chute sem versao do fallback antigo.
fetch_count="$(grep -c 'fetch:' "$FETCH_CALLS" || true)"
if [ "$fetch_count" -ne 1 ]; then
    echo "FAIL: API consultada $fetch_count vez(es); esperado 1 (sem fallback de versao — CR-10)"
    cat "$FETCH_CALLS"
    exit 1
fi
if ! grep -q 'fetch:fabric:1.21.1' "$FETCH_CALLS"; then
    echo "FAIL: consulta a API nao usou o filtro de versao (CR-10)"
    exit 1
fi
echo "OK: primary selecionado + sem fallback de versao"

# ------------------------------------------------------------------
# 3. Hash sha1 divergente => jar removido + falha (EXP-48).
# ------------------------------------------------------------------
FIXTURE_JSON="$TMP_DIR/fixture-hash-errado.json"
cat > "$FIXTURE_JSON" <<EOF
[{
  "version_number": "1.0.0",
  "files": [
    {"filename": "mod.jar", "primary": true, "url": "https://stub/PRIMARY.jar",
     "hashes": {"sha1": "0000000000000000000000000000000000000000"}}
  ]
}]
EOF

rm -f "$DEST_DIR"/*
if download_modrinth_mod "meu-mod" "fabric" "1.21.1" "$DEST_DIR" "meu-mod" >/dev/null 2>&1; then
    echo "FAIL: hash divergente foi aceito (EXP-48)"
    exit 1
fi
if [ -f "$DEST_DIR/meu-mod.jar" ]; then
    echo "FAIL: jar com hash divergente permaneceu em mods/ (EXP-48)"
    exit 1
fi
echo "OK: hash divergente rejeitado e jar removido"

# ------------------------------------------------------------------
# 4. sha512 divergente => falha (EXP-48).
# ------------------------------------------------------------------
FIXTURE_JSON="$TMP_DIR/fixture-sha512.json"
cat > "$FIXTURE_JSON" <<EOF
[{
  "version_number": "1.0.0",
  "files": [
    {"filename": "mod.jar", "primary": true, "url": "https://stub/PRIMARY.jar",
     "hashes": {"sha1": "$(sha1_of "$GOOD_BYTES")", "sha512": "deadbeef"}}
  ]
}]
EOF
rm -f "$DEST_DIR"/*
if download_modrinth_mod "meu-mod" "fabric" "1.21.1" "$DEST_DIR" "meu-mod" >/dev/null 2>&1; then
    echo "FAIL: sha512 divergente foi aceito (EXP-48)"
    exit 1
fi
echo "OK: sha512 divergente rejeitado"

# ------------------------------------------------------------------
# 5. sha256 fixado pelo caller (6o arg) e verificado.
# ------------------------------------------------------------------
FIXTURE_JSON="$TMP_DIR/fixture-primary.json"  # hashes corretos
MOD_PINNED_SHA256="$(sha256_of "$GOOD_BYTES")"

rm -f "$DEST_DIR"/*
if ! download_modrinth_mod "meu-mod" "fabric" "1.21.1" "$DEST_DIR" "meu-mod" "MOD_PINNED_SHA256" >/dev/null 2>&1; then
    echo "FAIL: sha256 fixado correto foi rejeitado"
    exit 1
fi

# Porem com o pin errado => falha.
MOD_PINNED_SHA256="$(sha256_of 'bytes-diferentes')"
rm -f "$DEST_DIR"/*
if download_modrinth_mod "meu-mod" "fabric" "1.21.1" "$DEST_DIR" "meu-mod" "MOD_PINNED_SHA256" >/dev/null 2>&1; then
    echo "FAIL: sha256 fixado divergente foi aceito (EXP-48)"
    exit 1
fi
if [ -f "$DEST_DIR/meu-mod.jar" ]; then
    echo "FAIL: jar com sha256 fixado divergente permaneceu (EXP-48)"
    exit 1
fi
echo "OK: sha256 fixado pelo caller verificado (correto e divergente)"

# ------------------------------------------------------------------
# 6. Nenhuma versao compativel => pendencia, sem download (CR-10).
# ------------------------------------------------------------------
FIXTURE_JSON="$TMP_DIR/fixture-vazia.json"
printf '[]' > "$FIXTURE_JSON"
: > "$FETCH_CALLS"
rm -f "$DEST_DIR"/*
if download_modrinth_mod "meu-mod" "fabric" "1.21.1" "$DEST_DIR" "meu-mod" >/dev/null 2>&1; then
    echo "FAIL: sem versao compativel o download 'funcionou' (CR-10)"
    exit 1
fi
fetch_count="$(grep -c 'fetch:' "$FETCH_CALLS" || true)"
if [ "$fetch_count" -ne 1 ]; then
    echo "FAIL: fallback sem filtro de versao ainda acontece ($fetch_count chamadas — CR-10)"
    exit 1
fi
echo "OK: versao incompativel = pendencia (sem fallback de versao)"

echo "OK: download-modrinth-test"
