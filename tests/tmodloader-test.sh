#!/bin/bash
# tests/tmodloader-test.sh
#
# Testa shared/lib/tmodloader.sh: parsing de releases do GitHub, extração de
# URL de download, catálogo de mods, mapeamento display_name -> workshop_id,
# e geração de enabled.json / install.txt.
#
# Usa fixtures JSON em tests/fixtures/ (sem rede — pure parsing).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/tmodloader.sh"

FIXTURES="$ROOT_DIR/tests/fixtures"
PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1" >&2
    [ -n "${2:-}" ] && echo "       expected: $2" >&2
    [ -n "${3:-}" ] && echo "       got:      $3" >&2
    FAIL=$((FAIL + 1))
}

echo "[tmodloader-test] Testando parsing de releases + catálogo (sem rede)..."

# --- 1. Parse releases (stable only) ---
echo "- GitHub releases (stable only):"
json=$(cat "$FIXTURES/tmodloader-releases.json")
out=$(tml_parse_releases "$json" 0)
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 2 ]; then
    pass "2 releases estáveis parseadas"
else
    fail "2 releases esperadas" "2" "$count"
fi
if printf '%s\n' "$out" | grep -qFx "v2026.06.3.6"; then
    pass "v2026.06.3.6 presente"
else
    fail "v2026.06.3.6 ausente"
fi
if printf '%s\n' "$out" | grep -qF "preview"; then
    fail "pre-release não deveria aparecer (stable only)"
else
    pass "pre-release excluído (stable only)"
fi

# --- 2. Parse releases (com pre-releases) ---
echo "- GitHub releases (com pre-releases):"
out=$(tml_parse_releases "$json" 1)
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 3 ]; then
    pass "3 releases (2 stable + 1 pre-release)"
else
    fail "3 releases esperadas" "3" "$count"
fi
if printf '%s\n' "$out" | grep -qF "v2026.07.2.5-preview (pre-release)"; then
    pass "pre-release marcado visualmente"
else
    fail "pre-release marcado ausente"
fi

# --- 3. extract_download_url ---
echo "- Extração de URL de download:"
url=$(tml_extract_download_url "$json" "v2026.06.3.6")
if [ "$url" = "https://github.com/tModLoader/tModLoader/releases/download/v2026.06.3.6/tModLoader.zip" ]; then
    pass "URL correta para v2026.06.3.6"
else
    fail "URL para v2026.06.3.6" "https://github.com/tModLoader/tModLoader/releases/download/v2026.06.3.6/tModLoader.zip" "$url"
fi

url=$(tml_extract_download_url "$json" "v2026.05.1.0")
if [ "$url" = "https://github.com/tModLoader/tModLoader/releases/download/v2026.05.1.0/tModLoader.zip" ]; then
    pass "URL correta para v2026.05.1.0"
else
    fail "URL para v2026.05.1.0" "" "$url"
fi

url=$(tml_extract_download_url "$json" "v_inexistente")
if [ -z "$url" ]; then
    pass "tag inexistente -> vazio"
else
    fail "tag inexistente deveria devolver vazio" "" "$url"
fi

# --- 4. Catálogo curado ---
echo "- Catálogo de mods:"
cat_count=$(tml_mod_catalog | grep -c . || true)
if [ "$cat_count" -ge 4 ]; then
    pass "catálogo tem $cat_count mods (>=4)"
else
    fail "catálogo muito pequeno" ">=4" "$cat_count"
fi

# Verifica Calamity no catálogo.
if tml_mod_catalog | grep -q "^2824688072|CalamityMod|Calamity Mod|"; then
    pass "Calamity no catálogo (workshop_id=2824688072)"
else
    fail "Calamity ausente do catálogo"
fi

# Verifica Thorium no catálogo.
if tml_mod_catalog | grep -q "^2909886416|ThoriumMod|Thorium Mod|"; then
    pass "Thorium no catálogo (workshop_id=2909886416)"
else
    fail "Thorium ausente do catálogo"
fi

# --- 5. extract_workshop_id_by_displayname ---
echo "- Mapeamento display_name -> workshop_id:"
wid=$(tml_extract_workshop_id_by_displayname "Calamity Mod")
if [ "$wid" = "2824688072" ]; then
    pass "Calamity Mod -> 2824688072"
else
    fail "Calamity Mod -> workshop_id" "2824688072" "$wid"
fi

wid=$(tml_extract_workshop_id_by_displayname "Thorium Mod")
if [ "$wid" = "2909886416" ]; then
    pass "Thorium Mod -> 2909886416"
else
    fail "Thorium Mod -> workshop_id" "2909886416" "$wid"
fi

wid=$(tml_extract_workshop_id_by_displayname "Mod Inexistente")
if [ -z "$wid" ]; then
    pass "display_name inexistente -> vazio"
else
    fail "display_name inexistente deveria devolver vazio" "" "$wid"
fi

# --- 6. extract_mod_internal_name ---
echo "- Extração de internal_name:"
iname=$(tml_extract_mod_internal_name "Calamity Mod | CalamityMod | Mod de conteúdo massivo")
if [ "$iname" = "CalamityMod" ]; then
    pass "internal_name = CalamityMod"
else
    fail "internal_name" "CalamityMod" "$iname"
fi

iname=$(tml_extract_mod_internal_name "Thorium Mod | ThoriumMod | Mod equilibrado")
if [ "$iname" = "ThoriumMod" ]; then
    pass "internal_name = ThoriumMod"
else
    fail "internal_name" "ThoriumMod" "$iname"
fi

# --- 7. write_enabled_json + write_install_txt ---
echo "- Geração de enabled.json e install.txt:"
TMP_MODS_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_MODS_DIR"' EXIT

# Caso: mods selecionados.
tml_write_enabled_json "$TMP_MODS_DIR" "CalamityMod,ThoriumMod"
if [ -f "$TMP_MODS_DIR/enabled.json" ]; then
    content=$(cat "$TMP_MODS_DIR/enabled.json")
    expected='["CalamityMod","ThoriumMod"]'
    if [ "$content" = "$expected" ]; then
        pass "enabled.json com 2 mods (formato correto)"
    else
        fail "enabled.json conteúdo" "$expected" "$content"
    fi
else
    fail "enabled.json não criado"
fi

# install.txt com workshop IDs.
tml_write_install_txt "$TMP_MODS_DIR" "2824688072,2909886416"
if [ -f "$TMP_MODS_DIR/install.txt" ]; then
    install_content=$(cat "$TMP_MODS_DIR/install.txt")
    if printf '%s\n' "$install_content" | grep -qFx "2824688072" && printf '%s\n' "$install_content" | grep -qFx "2909886416"; then
        pass "install.txt com 2 workshop IDs"
    else
        fail "install.txt conteúdo não contém os IDs esperados"
    fi
else
    fail "install.txt não criado"
fi

# Caso: sem mods (CSV vazio).
tml_write_enabled_json "$TMP_MODS_DIR/empty" ""
if [ -f "$TMP_MODS_DIR/empty/enabled.json" ]; then
    content=$(cat "$TMP_MODS_DIR/empty/enabled.json")
    if [ "$content" = "[]" ]; then
        pass "enabled.json vazio = []"
    else
        fail "enabled.json vazio" "[]" "$content"
    fi
else
    fail "enabled.json vazio não criado"
fi

# --- 8. Empty inputs ---
echo "- Inputs vazios:"
out=$(tml_parse_releases "" 0)
if [ -z "$out" ]; then
    pass "releases empty -> vazio"
else
    fail "releases empty"
fi

out=$(tml_parse_releases "" 1)
if [ -z "$out" ]; then
    pass "releases empty (pre-releases) -> vazio"
else
    fail "releases empty (pre-releases)"
fi

url=$(tml_extract_download_url "" "v1.0")
if [ -z "$url" ]; then
    pass "extract_download_url json vazio -> vazio"
else
    fail "extract_download_url json vazio"
fi

url=$(tml_extract_download_url "$json" "")
if [ -z "$url" ]; then
    pass "extract_download_url tag vazia -> vazio"
else
    fail "extract_download_url tag vazia"
fi

echo ""
echo "[tmodloader-test] PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
