#!/bin/bash
# shared/lib/tmodloader.sh
#
# Biblioteca para instalação do tModLoader (Terraria com mods) e download de
# mods via SteamCMD. Implementa:
#   - Fetch dinâmico de versões do tModLoader via GitHub Releases API.
#   - Catálogo curado de mods populares (Workshop IDs do Steam).
#   - Download de mods via SteamCMD (anônimo, App ID 1281930).
#   - Geração de enabled.json (formato esperado pelo tModLoader).
#
# Design (espelha mc-manifests.sh):
#   - Funções tml_fetch_* fazem chamadas de rede (curl) e devolvem JSON cru.
#   - Funções tml_parse_* transformam JSON em listas (uma versão por linha).
#   - Catálogo é estático (CSV) em tml_mod_catalog().
#   - User-Agent obrigatório (GitHub API bloqueia UA genérico após 60 req/h anon).
#
# Referências oficiais:
#   - tModLoader releases: https://github.com/tModLoader/tModLoader/releases
#   - GitHub API: https://api.github.com/repos/tModLoader/tModLoader/releases
#   - SteamCMD App ID: 1281930 (tModLoader no Steam)
#   - Workshop download: steamcmd +login anonymous +workshop_download_item 1281930 <id>
#
# tModLoader é self-contained para .NET 8 (LaunchUtils/InstallDotNet.sh instala
# .NET na primeira execução se faltar). Não precisa de Mono (legacy 1.3 only).

# User-Agent consistente com mc-manifests.sh.
TML_USER_AGENT="${MODRINTH_USER_AGENT:-crias-server-installer/1.2.0 (https://github.com/ViniciusLopes7/Crias-Server)}"
TML_API_CONNECT_TIMEOUT="${MC_API_CONNECT_TIMEOUT:-10}"
TML_API_MAX_TIME="${MC_API_MAX_TIME:-30}"

# Steam App ID do tModLoader (free, anon workshop download permitido).
TML_STEAM_APP_ID="1281930"

# ===========================================================================
# FETCH (rede) — devolvem JSON cru.
# ===========================================================================

# GitHub Releases: lista todas as releases do tModLoader (inclui pre-releases).
# JSON array de { tag_name, name, prerelease, assets[].browser_download_url, ... }.
tml_fetch_releases() {
    curl -fsSL \
        --connect-timeout "$TML_API_CONNECT_TIMEOUT" \
        --max-time "$TML_API_MAX_TIME" \
        -H "User-Agent: $TML_USER_AGENT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/tModLoader/tModLoader/releases?per_page=30" 2>/dev/null
}

# ===========================================================================
# PARSE (JSON) — devolvem listas (uma versão por linha).
# Funções puras, sem rede — para teste com fixtures.
# ===========================================================================

# Parse das releases do GitHub. Devolve uma versão por linha.
# Filtro: include_prereleases controla se pre-releases entram.
# Formato: "<tag_name>" (stable) ou "<tag_name> (pre-release)" (se incluído).
# Uso: tml_parse_releases <json> <include_prereleases:0|1>
tml_parse_releases() {
    local json="$1"
    local include_prereleases="${2:-0}"
    if [ -z "$json" ]; then
        return 0
    fi
    if [ "$include_prereleases" = "1" ]; then
        printf '%s' "$json" | jq -r '
            .[]
            | if .prerelease then "\(.tag_name) (pre-release)" else .tag_name end
        ' 2>/dev/null
    else
        printf '%s' "$json" | jq -r '.[] | select(.prerelease | not) | .tag_name' 2>/dev/null
    fi
}

# Extrai a URL de download do asset tModLoader.zip de uma release específica.
# Uso: tml_extract_download_url <json> <tag_name>
# Devolve a browser_download_url do asset "tModLoader.zip", ou vazio se não encontrado.
tml_extract_download_url() {
    local json="$1"
    local tag_name="$2"
    if [ -z "$json" ] || [ -z "$tag_name" ]; then
        return 0
    fi
    printf '%s' "$json" | jq -r --arg tag "$tag_name" '
        .[] | select(.tag_name == $tag) | .assets[]
        | select(.name == "tModLoader.zip") | .browser_download_url
    ' 2>/dev/null | head -1
}

# ===========================================================================
# Catálogo curado de mods (Workshop IDs do Steam, App 1281930).
# Formato CSV: "workshop_id|internal_name|display_name|description"
# internal_name é o que vai em enabled.json (NÃO é o Workshop ID).
# ===========================================================================

# Devolve o catálogo no stdout (uma linha por mod).
tml_mod_catalog() {
    cat << 'EOF'
2824688072|CalamityMod|Calamity Mod|Mod de conteúdo massivo (bosses, biomas, itens)
2824688266|CalamityModMusic|Calamity Mod Music|Trilha sonora complementar do Calamity
2909886416|ThoriumMod|Thorium Mod|Mod de conteúdo equilibrado (bosses, classes)
2563309347|MagicStorage|Magic Storage|Sistema de armazenamento mágico
2619954303|RecipeBrowser|Recipe Browser|Navegador de receitas in-game
EOF
}

# Lista mods do catálogo formatados para TUI: "display_name | internal_name | desc"
tml_mod_catalog_formatted() {
    tml_mod_catalog | while IFS='|' read -r wid iname dname desc; do
        printf '%s | %s | %s\n' "$dname" "$iname" "$desc"
    done
}

# Extrai o Workshop ID de uma linha do catálogo.
# Uso: wid=$(tml_extract_workshop_id "Calamity Mod | CalamityMod | ...")
# NOTA: o caller passa a linha formatada (não a cru). Mapeia display_name -> wid.
tml_extract_workshop_id_by_displayname() {
    local display_name="$1"
    tml_mod_catalog | while IFS='|' read -r wid iname dname desc; do
        if [ "$dname" = "$display_name" ]; then
            printf '%s\n' "$wid"
            return 0
        fi
    done
}

# Extrai o internal_name de uma linha formatada "display_name | internal_name | desc".
tml_extract_mod_internal_name() {
    local line="$1"
    # Pega o campo entre o primeiro " | " e o segundo " | ".
    local after_first="${line#* | }"
    printf '%s' "${after_first%% | *}" | tr -d '[:space:]'
}

# ===========================================================================
# SteamCMD: download de mods via Workshop.
# ===========================================================================

# Verifica se steamcmd está instalado.
tml_steamcmd_available() {
    command -v steamcmd >/dev/null 2>&1
}

# Baixa mods via SteamCMD. Recebe lista de Workshop IDs (um por linha ou CSV).
# Uso: tml_download_mods <steamcmd_install_dir> <workshop_ids_csv>
# steamcmd_install_dir = diretório base (-force_install_dir); mods vão para
#   <dir>/steamapps/workshop/content/1281930/<workshop_id>/
# Retorna 0 se todos baixaram, 1 se algum falhou (continua tentando os outros).
tml_download_mods() {
    local install_dir="$1"
    local workshop_ids_csv="$2"

    if [ -z "$install_dir" ] || [ -z "$workshop_ids_csv" ]; then
        return 1
    fi

    if ! tml_steamcmd_available; then
        return 1
    fi

    # Constrói argumentos +workshop_download_item para cada ID.
    local cmd_args=()
    cmd_args+=("+force_install_dir" "$install_dir" "+login" "anonymous")
    local IFS=','
    local wid
    for wid in $workshop_ids_csv; do
        [ -z "$wid" ] && continue
        cmd_args+=("+workshop_download_item" "$TML_STEAM_APP_ID" "$wid")
    done
    unset IFS
    cmd_args+=("+quit")

    # Executa steamcmd (pode demorar; sem timeout fixo para permitir downloads grandes).
    steamcmd "${cmd_args[@]}" >/dev/null 2>&1
}

# ===========================================================================
# enabled.json: arquivo que diz ao tModLoader quais mods carregar.
# Formato: array JSON de internal_names (NÃO workshop IDs).
# ===========================================================================

# Gera enabled.json a partir de uma lista CSV de internal_names.
# Uso: tml_write_enabled_json <mods_dir> <internal_names_csv>
tml_write_enabled_json() {
    local mods_dir="$1"
    local internal_names_csv="$2"

    if [ -z "$mods_dir" ]; then
        return 1
    fi

    mkdir -p "$mods_dir"

    # Constrói array JSON compacto (single-line) a partir do CSV.
    local json_array="[]"
    if [ -n "$internal_names_csv" ]; then
        json_array=$(printf '%s' "$internal_names_csv" | jq -c -R 'split(",")' 2>/dev/null || echo '[]')
    fi

    printf '%s\n' "$json_array" > "$mods_dir/enabled.json"
    chmod 0644 "$mods_dir/enabled.json"
}

# Gera install.txt (lista de Workshop IDs, um por linha) para referência/auditoria.
# Uso: tml_write_install_txt <mods_dir> <workshop_ids_csv>
tml_write_install_txt() {
    local mods_dir="$1"
    local workshop_ids_csv="$2"

    if [ -z "$mods_dir" ]; then
        return 1
    fi

    mkdir -p "$mods_dir"
    : > "$mods_dir/install.txt"
    if [ -n "$workshop_ids_csv" ]; then
        local IFS=','
        local wid
        for wid in $workshop_ids_csv; do
            [ -z "$wid" ] && continue
            printf '%s\n' "$wid" >> "$mods_dir/install.txt"
        done
        unset IFS
    fi
    chmod 0644 "$mods_dir/install.txt"
}

# ===========================================================================
# Orquestrador: busca versões do tModLoader (releases estáveis por default).
# Devolve uma versão por linha no stdout. Retorna 0 em sucesso, 1 se fetch falhou.
# Uso: tml_get_versions <include_prereleases:0|1>
# ===========================================================================
tml_get_versions() {
    local include_prereleases="${1:-0}"
    local json
    json=$(tml_fetch_releases) || return 1
    tml_parse_releases "$json" "$include_prereleases"
    return 0
}

# ===========================================================================
# Self-test (executável standalone): valida funções de parse com fixtures.
# Roda: bash shared/lib/tmodloader.sh selftest
# ===========================================================================
_tmodloader_selftest() {
    local fails=0
    local out

    # --- Fixture GitHub releases (2 stable + 1 pre-release) ---
    local releases='[{"tag_name":"v2026.06.3.6","name":"v2026.06.3.6","prerelease":false,"assets":[{"name":"tModLoader.zip","browser_download_url":"https://github.com/tModLoader/tModLoader/releases/download/v2026.06.3.6/tModLoader.zip"}]},{"tag_name":"v2026.05.1.0","name":"v2026.05.1.0","prerelease":false,"assets":[{"name":"tModLoader.zip","browser_download_url":"https://github.com/tModLoader/tModLoader/releases/download/v2026.05.1.0/tModLoader.zip"}]},{"tag_name":"v2026.07.2.5-preview","name":"v2026.07.2.5-preview","prerelease":true,"assets":[{"name":"tModLoader.zip","browser_download_url":"https://github.com/tModLoader/tModLoader/releases/download/v2026.07.2.5-preview/tModLoader.zip"}]}]'

    out=$(tml_parse_releases "$releases" 0)
    local count
    count=$(printf '%s\n' "$out" | grep -c . || true)
    if [ "$count" -eq 2 ]; then
        echo "[tmodloader] releases parse (stable only): OK (2 versoes)"
    else
        echo "[tmodloader] releases parse FAIL: esperado 2, got $count" >&2
        fails=$((fails+1))
    fi
    if printf '%s\n' "$out" | grep -qFx "v2026.06.3.6"; then
        echo "[tmodloader] release v2026.06.3.6 presente: OK"
    else
        echo "[tmodloader] v2026.06.3.6 ausente" >&2
        fails=$((fails+1))
    fi
    if ! printf '%s\n' "$out" | grep -qF "preview"; then
        echo "[tmodloader] pre-release excluido (stable only): OK"
    else
        echo "[tmodloader] pre-release nao deveria aparecer" >&2
        fails=$((fails+1))
    fi

    out=$(tml_parse_releases "$releases" 1)
    if printf '%s\n' "$out" | grep -qF "v2026.07.2.5-preview (pre-release)"; then
        echo "[tmodloader] pre-release marcado (include_prereleases=1): OK"
    else
        echo "[tmodloader] pre-release marcado ausente" >&2
        fails=$((fails+1))
    fi

    # --- extract_download_url ---
    local url
    url=$(tml_extract_download_url "$releases" "v2026.06.3.6")
    if [ "$url" = "https://github.com/tModLoader/tModLoader/releases/download/v2026.06.3.6/tModLoader.zip" ]; then
        echo "[tmodloader] extract_download_url: OK"
    else
        echo "[tmodloader] extract_download_url FAIL: got '$url'" >&2
        fails=$((fails+1))
    fi

    url=$(tml_extract_download_url "$releases" "v_inexistente")
    if [ -z "$url" ]; then
        echo "[tmodloader] extract_download_url tag inexistente -> vazio: OK"
    else
        echo "[tmodloader] tag inexistente deveria devolver vazio" >&2
        fails=$((fails+1))
    fi

    # --- catálogo ---
    local cat_count
    cat_count=$(tml_mod_catalog | grep -c . || true)
    if [ "$cat_count" -ge 4 ]; then
        echo "[tmodloader] catalogo tem $cat_count mods: OK"
    else
        echo "[tmodloader] catalogo muito pequeno: $cat_count" >&2
        fails=$((fails+1))
    fi

    # Verifica Calamity no catálogo.
    if tml_mod_catalog | grep -q "^2824688072|CalamityMod|"; then
        echo "[tmodloader] Calamity no catalogo: OK"
    else
        echo "[tmodloader] Calamity ausente do catalogo" >&2
        fails=$((fails+1))
    fi

    # --- extract_workshop_id_by_displayname ---
    local wid
    wid=$(tml_extract_workshop_id_by_displayname "Calamity Mod")
    if [ "$wid" = "2824688072" ]; then
        echo "[tmodloader] extract_workshop_id (Calamity Mod): OK"
    else
        echo "[tmodloader] extract_workshop_id FAIL: got '$wid'" >&2
        fails=$((fails+1))
    fi

    # --- extract_mod_internal_name ---
    local iname
    iname=$(tml_extract_mod_internal_name "Calamity Mod | CalamityMod | Mod de conteúdo massivo")
    if [ "$iname" = "CalamityMod" ]; then
        echo "[tmodloader] extract_mod_internal_name: OK"
    else
        echo "[tmodloader] extract_mod_internal_name FAIL: got '$iname'" >&2
        fails=$((fails+1))
    fi

    # --- empty inputs ---
    out=$(tml_parse_releases "" 0)
    if [ -z "$out" ]; then
        echo "[tmodloader] empty input -> vazio: OK"
    else
        echo "[tmodloader] empty FAIL" >&2
        fails=$((fails+1))
    fi

    if [ "$fails" -gt 0 ]; then
        echo "[tmodloader] selftest: $fails falha(s)" >&2
        return 1
    fi
    echo "[tmodloader] selftest: todos passaram"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        selftest) _tmodloader_selftest ;;
        *)
            echo "Uso: source este arquivo OU rode 'bash $0 selftest'"
            ;;
    esac
fi
