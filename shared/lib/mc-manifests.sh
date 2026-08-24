#!/bin/bash
# shared/lib/mc-manifests.sh
#
# Biblioteca para busca dinâmica de versões de Minecraft e modpacks via APIs
# públicas (Mojang version manifest, Fabric Meta, Quilt Meta, NeoForge/Forge
# maven-metadata.xml, Modrinth Labrinth API v2).
#
# Design:
#   - Funções mc_fetch_* fazem chamadas de rede (curl) e devolvem JSON cru.
#   - Funções mc_parse_* transformam JSON em listas utilizáveis (uma versão
#     por linha), separando a lógica de parsing da de rede para que testes
#     possam injetar fixtures JSON sem chamar a API.
#   - Funções mc_suggest_* implementam heurísticas (versão MC mais próxima).
#   - User-Agent obrigatório em todas as chamadas (Modrinth bloqueia UA
#     genérico; ver docs em https://docs.modrinth.com).
#
# Referências oficiais:
#   - Mojang: https://piston-meta.mojang.com/mc/game/version_manifest.json
#   - Fabric: https://meta.fabricmc.net/v2/versions/game
#   - Quilt:  https://meta.quiltmc.org/v3/versions/game
#   - NeoForge: https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml
#   - Forge: https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml
#   - Modrinth: https://api.modrinth.com/v2/  (endpoint /search, /project, /tag/game_version)
#     IMPORTANTE: o endpoint de game versions é /tag/game_version (underscore),
#     NÃO /tag/game-version (hífen) — este último retorna 404.

# ---------------------------------------------------------------------------
# User-Agent para todas as chamadas a APIs públicas.
# Modrinth exige UA não-genérico (bloqueia curl/python-requests puros).
# ---------------------------------------------------------------------------
MODRINTH_USER_AGENT="crias-server-installer/1.2.0 (https://github.com/ViniciusLopes7/Crias-Server)"
# Timeouts conservadores para não travar o installer em rede lenta.
MC_API_CONNECT_TIMEOUT="${MC_API_CONNECT_TIMEOUT:-10}"
MC_API_MAX_TIME="${MC_API_MAX_TIME:-30}"

# ---------------------------------------------------------------------------
# Verifica conectividade mínima com a internet.
# Retorna 0 se alcançou o host-alvo (https), 1 caso contrário.
# ---------------------------------------------------------------------------
mc_has_internet() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL --connect-timeout 5 --max-time 10 https://github.com >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Wrapper curl com UA + timeouts. Uso: mc_curl_get <url>
# Printa o corpo da resposta no stdout. Retorna 0 em sucesso.
# ---------------------------------------------------------------------------
mc_curl_get() {
    local url="$1"
    curl -fsSL \
        --connect-timeout "$MC_API_CONNECT_TIMEOUT" \
        --max-time "$MC_API_MAX_TIME" \
        -H "User-Agent: $MODRINTH_USER_AGENT" \
        "$url" 2>/dev/null
}

# ===========================================================================
# FETCH (rede) — devolvem JSON/XML cru.
# ===========================================================================

# Mojang version manifest. JSON com .versions[] = { id, type, ... }.
# type ∈ { release, snapshot, old_beta, old_alpha }.
mc_fetch_mojang_versions() {
    mc_curl_get "https://piston-meta.mojang.com/mc/game/version_manifest.json"
}

# Fabric: lista de { version, stable }.
mc_fetch_fabric_versions() {
    mc_curl_get "https://meta.fabricmc.net/v2/versions/game"
}

# Quilt: lista de { version, stable }.
mc_fetch_quilt_versions() {
    mc_curl_get "https://meta.quiltmc.org/v3/versions/game"
}

# NeoForge: maven-metadata.xml (XML, não JSON).
mc_fetch_neoforge_metadata() {
    mc_curl_get "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
}

# Forge: maven-metadata.xml (XML).
mc_fetch_forge_metadata() {
    mc_curl_get "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
}

# Modrinth: busca modpacks. index=downloads ordena por popularidade.
# query vazio + index=downloads = top N mais baixados.
# Uso: mc_fetch_modrinth_search_modpacks <query> <limit>
mc_fetch_modrinth_search_modpacks() {
    local query="$1"
    local limit="${2:-10}"
    local facets='[["project_type:modpack"]]'
    local encoded_facets encoded_query
    encoded_facets=$(printf '%s' "$facets" | jq -sR .)
    local url
    url="https://api.modrinth.com/v2/search?facets=${encoded_facets}&limit=${limit}"
    if [ -n "$query" ]; then
        encoded_query=$(printf '%s' "$query" | jq -sR . | sed 's/^"//;s/"$//')
        url="${url}&query=${encoded_query}"
    else
        url="${url}&index=downloads"
    fi
    mc_curl_get "$url"
}

# Modrinth: lista versões de um projeto (modpack), com filtro server-side por
# loader e game_version. Se ambos vazios, retorna todas as versões.
# Uso: mc_fetch_modrinth_project_versions <slug|id> <loader> <game_version>
mc_fetch_modrinth_project_versions() {
    local slug="$1"
    local loader="$2"
    local game_version="$3"
    local url="https://api.modrinth.com/v2/project/${slug}/version"
    local params=()
    if [ -n "$loader" ]; then
        params+=("loaders=$(printf '["%s"]' "$loader" | jq -sR . | sed 's/^"//;s/"$//')")
    fi
    if [ -n "$game_version" ]; then
        params+=("game_versions=$(printf '["%s"]' "$game_version" | jq -sR . | sed 's/^"//;s/"$//')")
    fi
    if [ "${#params[@]}" -gt 0 ]; then
        local joined
        joined=$(printf '%s&' "${params[@]}")
        url="${url}?${joined%&}"
    fi
    mc_curl_get "$url"
}

# Modrinth: lista todas as game versions disponíveis (tag/game_version).
# JSON array de { version, version_type, date, major }.
# version_type ∈ { release, snapshot, alpha, beta }.
mc_fetch_modrinth_game_versions() {
    mc_curl_get "https://api.modrinth.com/v2/tag/game_version"
}

# ===========================================================================
# PARSE (JSON/XML) — devolvem listas (uma versão por linha).
# Funções puras, sem rede — para teste com fixtures.
# ===========================================================================

# Parse do manifest Mojang. Devolve uma versão por linha.
# Filtro: include_snapshots controla se snapshots são incluídos.
# old_beta e old_alpha são SEMPRE excluídos (irrelevantes para servidores modernos).
# Formato da linha: "<version_id>" (releases) ou "<version_id> (snapshot)".
# Uso: mc_parse_mojang_versions <json> <include_snapshots:0|1>
mc_parse_mojang_versions() {
    local json="$1"
    local include_snapshots="${2:-0}"
    if [ -z "$json" ]; then
        return 0
    fi
    if [ "$include_snapshots" = "1" ]; then
        printf '%s' "$json" | jq -r '
            .versions[]
            | select(.type == "release" or .type == "snapshot")
            | if .type == "snapshot" then "\(.id) (snapshot)" else .id end
        ' 2>/dev/null
    else
        printf '%s' "$json" | jq -r '.versions[] | select(.type == "release") | .id' 2>/dev/null
    fi
}

# Parse do Fabric/Quilt (mesmo formato: array de {version, stable}).
# include_snapshots=1 inclui stable=false.
mc_parse_fabric_versions() {
    local json="$1"
    local include_snapshots="${2:-0}"
    if [ -z "$json" ]; then
        return 0
    fi
    if [ "$include_snapshots" = "1" ]; then
        printf '%s' "$json" | jq -r '
            .[]
            | if .stable then .version else "\(.version) (snapshot)" end
        ' 2>/dev/null
    else
        printf '%s' "$json" | jq -r '.[] | select(.stable) | .version' 2>/dev/null
    fi
}

# Alias: Quilt tem o mesmo formato do Fabric.
mc_parse_quilt_versions() {
    mc_parse_fabric_versions "$@"
}

# Parse do maven-metadata.xml do NeoForge.
# NeoForge versioning: major = MC major (20 = 1.20, 21 = 1.21, 22 = 1.22, ...).
# NeoForge só existe desde MC 1.20, então major >= 20 sempre.
# Regra: sempre prepend "1." (quando MC 2.0 existir, o formato mudará).
# Devolve versões MC únicas (sem duplicatas), preservando ordem do XML (desc).
# include_snapshots=1 inclui versões -beta/-dev/-rc.
mc_parse_neoforge_versions() {
    local xml="$1"
    local include_snapshots="${2:-0}"
    if [ -z "$xml" ]; then
        return 0
    fi
    local raw
    raw=$(printf '%s' "$xml" | grep -oE '<version>[^<]+</version>' \
        | sed 's/<\/\?version>//g' 2>/dev/null || true)
    if [ -z "$raw" ]; then
        return 0
    fi
    local line major minor mc_ver
    local -A seen=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Pula -beta/-dev/-rc se snapshots desligados.
        if [ "$include_snapshots" != "1" ]; then
            case "$line" in
                *-beta|*-dev|*-rc*) continue ;;
            esac
        fi
        # Pega major.minor da versão NeoForge (ex.: "21.0.143" -> major=21, minor=0).
        major="${line%%.*}"
        local rest="${line#*.}"
        minor="${rest%%.*}"
        if [ -z "$major" ] || [ -z "$minor" ]; then
            continue
        fi
        # NeoForge major >= 20 (MC 1.20+). Sempre prepend "1.".
        # Fallback defensivo para major < 20 (não deveria ocorrer).
        if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 20 ]; then
            mc_ver="1.${major}.${minor}"
        else
            mc_ver="${major}.${minor}"
        fi
        if [ -z "${seen[$mc_ver]:-}" ]; then
            seen["$mc_ver"]=1
            printf '%s\n' "$mc_ver"
        fi
    done <<< "$raw"
}

# Parse do maven-metadata.xml do Forge.
# Versões Forge têm formato "<MCversion>-<forgever>" (ex.: "1.21.8-58.0.3").
# Extraímos só a parte MC (antes do primeiro "-").
mc_parse_forge_versions() {
    local xml="$1"
    local include_snapshots="${2:-0}"
    if [ -z "$xml" ]; then
        return 0
    fi
    local raw
    raw=$(printf '%s' "$xml" | grep -oE '<version>[^<]+</version>' \
        | sed 's/<\/\?version>//g' 2>/dev/null || true)
    if [ -z "$raw" ]; then
        return 0
    fi
    local line mc_ver
    local -A seen=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$include_snapshots" != "1" ]; then
            case "$line" in
                *-beta|*-dev|*-rc*) continue ;;
            esac
        fi
        mc_ver="${line%%-*}"
        if [ -z "$mc_ver" ]; then
            continue
        fi
        if [ -z "${seen[$mc_ver]:-}" ]; then
            seen["$mc_ver"]=1
            printf '%s\n' "$mc_ver"
        fi
    done <<< "$raw"
}

# ===========================================================================
# Modrinth: parse de resultados de busca de modpacks.
# Devolve linhas "slug | title | downloads" para o TUI exibir.
# Uso: mc_parse_modrinth_search <json> -> "slug | title | ↓N"
# ===========================================================================
mc_parse_modrinth_search() {
    local json="$1"
    if [ -z "$json" ]; then
        return 0
    fi
    printf '%s' "$json" | jq -r '
        .hits[]
        | "\(.slug) | \(.title) | ↓\(.downloads)"
    ' 2>/dev/null
}

# Extrai apenas o slug de uma linha "slug | title | ↓N" (após seleção no TUI).
# Uso: slug=$(mc_extract_slug "adrenaline | Adrenaline | ↓1234567")
mc_extract_slug() {
    local line="$1"
    # Pega tudo antes do primeiro " | ".
    printf '%s' "${line%% *}" | tr -d '[:space:]'
}

# ===========================================================================
# Modrinth: parse de versões de um projeto (modpack).
# Devolve linhas "<version_number> | <game_versions csv> | type".
# Se json vazio ou erro, devolve vazio.
# Uso: mc_parse_modrinth_project_versions <json>
# ===========================================================================
mc_parse_modrinth_project_versions() {
    local json="$1"
    if [ -z "$json" ]; then
        return 0
    fi
    printf '%s' "$json" | jq -r '
        .[]
        | "\(.version_number) | \((.game_versions | join(","))) | \(.version_type)"
    ' 2>/dev/null
}

# Extrai o version_number (campo antes do primeiro " | ").
mc_extract_version_number() {
    local line="$1"
    printf '%s' "${line%% *}" | tr -d '[:space:]'
}

# ===========================================================================
# Sugestão de versão MC mais próxima.
# Recebe a versão desejada + lista de versões suportadas (uma por linha).
# Heurística (semântica):
#   1. Match exato -> devolve a própria.
#   2. Mesma major.minor (ex.: 1.21.x) -> a mais recente dessa minor.
#   3. Mesma major (ex.: 1.21) -> a mais recente dessa major.
#   4. Mais recente da lista.
# Uso: mc_suggest_closest_version "1.21.4" <supported_list>
# Devolve a versão sugerida no stdout (vazio se lista vazia).
# ===========================================================================
mc_suggest_closest_version() {
    local wanted="$1"
    local supported="$2"

    if [ -z "$supported" ]; then
        return 0
    fi

    # Limpa "(snapshot)" markers para comparação.
    local want_clean="${wanted%% *}"

    # 1. Match exato.
    local exact
    exact=$(printf '%s\n' "$supported" | grep -Fx "$want_clean" | head -1 || true)
    if [ -n "$exact" ]; then
        printf '%s\n' "$exact"
        return 0
    fi

    # Decompõe wanted em major.minor.patch.
    local w_major w_minor w_patch
    IFS=. read -r w_major w_minor w_patch <<<"$want_clean"
    w_patch="${w_patch:-0}"

    # Constrói arrays de versões limpas (sem marker) preservando ordem.
    local -a versions=()
    local v
    while IFS= read -r v; do
        [ -n "$v" ] && versions+=("${v%% *}")
    done <<<"$supported"

    if [ "${#versions[@]}" -eq 0 ]; then
        return 0
    fi

    # 2. Mesma major.minor -> pega a de patch mais alto (assume lista em
    #    ordem desc por data, então a primeira match é a mais recente).
    local match
    match=$(printf '%s\n' "${versions[@]}" | grep -E "^${w_major}\.${w_minor}\." | head -1 || true)
    if [ -n "$match" ]; then
        printf '%s\n' "$match"
        return 0
    fi

    # 3. Mesma major -> primeira ocorrência (mais recente dessa major).
    match=$(printf '%s\n' "${versions[@]}" | grep -E "^${w_major}\." | head -1 || true)
    if [ -n "$match" ]; then
        printf '%s\n' "$match"
        return 0
    fi

    # 4. Fallback: primeira da lista (mais recente).
    printf '%s\n' "${versions[0]}"
}

# ===========================================================================
# Orquestrador: busca versões MC para um loader específico.
# Devolve uma versão por linha no stdout (já com markers de snapshot se
# include_snapshots=1). Retorna 0 em sucesso, 1 se fetch falhou.
# Uso: mc_get_versions_for_loader <loader> <include_snapshots:0|1>
# ===========================================================================
mc_get_versions_for_loader() {
    local loader="$1"
    local include_snapshots="${2:-0}"
    local json

    case "$loader" in
        vanilla)
            json=$(mc_fetch_mojang_versions) || return 1
            mc_parse_mojang_versions "$json" "$include_snapshots"
            ;;
        fabric)
            json=$(mc_fetch_fabric_versions) || return 1
            mc_parse_fabric_versions "$json" "$include_snapshots"
            ;;
        quilt)
            json=$(mc_fetch_quilt_versions) || return 1
            mc_parse_quilt_versions "$json" "$include_snapshots"
            ;;
        neoforge)
            json=$(mc_fetch_neoforge_metadata) || return 1
            mc_parse_neoforge_versions "$json" "$include_snapshots"
            ;;
        forge)
            json=$(mc_fetch_forge_metadata) || return 1
            mc_parse_forge_versions "$json" "$include_snapshots"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# ===========================================================================
# Self-test (executável standalone): valida funções de parse com fixtures
# embutidas, sem rede. Roda: bash shared/lib/mc-manifests.sh selftest
# ===========================================================================
_mc_manifests_selftest() {
    local fails=0
    local out

    # --- Fixture Mojang (releases + 1 snapshot) ---
    local mojang='{"latest":{"release":"1.21.4","snapshot":"1.21.5-snapshot"},"versions":[{"id":"1.21.4","type":"release"},{"id":"1.21.3","type":"release"},{"id":"1.21.5-snapshot","type":"snapshot"},{"id":"a1.0.0","type":"old_alpha"}]}'

    out=$(mc_parse_mojang_versions "$mojang" 0)
    if printf '%s\n' "$out" | grep -qFx "1.21.4" \
        && ! printf '%s\n' "$out" | grep -qF "snapshot"; then
        echo "[mc-manifests] mojang parse (releases only): OK"
    else
        echo "[mc-manifests] mojang parse FAIL: out=[$out]" >&2
        fails=$((fails+1))
    fi

    out=$(mc_parse_mojang_versions "$mojang" 1)
    if printf '%s\n' "$out" | grep -qF "1.21.5-snapshot (snapshot)" \
        && ! printf '%s\n' "$out" | grep -qF "a1.0.0"; then
        echo "[mc-manifests] mojang parse (with snapshots): OK"
    else
        echo "[mc-manifests] mojang parse+snap FAIL: out=[$out]" >&2
        fails=$((fails+1))
    fi

    # --- Fixture Fabric ---
    local fabric='[{"version":"1.21.4","stable":true},{"version":"1.21.3","stable":true},{"version":"22w14a","stable":false}]'
    out=$(mc_parse_fabric_versions "$fabric" 0)
    if printf '%s\n' "$out" | grep -qFx "1.21.4" \
        && ! printf '%s\n' "$out" | grep -qF "22w14a"; then
        echo "[mc-manifests] fabric parse (releases): OK"
    else
        echo "[mc-manifests] fabric parse FAIL: out=[$out]" >&2
        fails=$((fails+1))
    fi

    out=$(mc_parse_fabric_versions "$fabric" 1)
    if printf '%s\n' "$out" | grep -qF "22w14a (snapshot)"; then
        echo "[mc-manifests] fabric parse (with snapshots): OK"
    else
        echo "[mc-manifests] fabric parse+snap FAIL: out=[$out]" >&2
        fails=$((fails+1))
    fi

    # --- Fixture Modrinth search ---
    local search='{"hits":[{"slug":"adrenaline","title":"Adrenaline","downloads":1234567},{"slug":"fabulously-optimized","title":"Fabulously Optimized","downloads":987654}],"offset":0,"limit":10,"total_hits":2}'
    out=$(mc_parse_modrinth_search "$search")
    if printf '%s\n' "$out" | grep -qF "adrenaline | Adrenaline | ↓1234567"; then
        echo "[mc-manifests] modrinth search parse: OK"
    else
        echo "[mc-manifests] modrinth search parse FAIL: out=[$out]" >&2
        fails=$((fails+1))
    fi

    if [ "$(mc_extract_slug 'adrenaline | Adrenaline | ↓1234567')" = "adrenaline" ]; then
        echo "[mc-manifests] extract_slug: OK"
    else
        echo "[mc-manifests] extract_slug FAIL" >&2
        fails=$((fails+1))
    fi

    # --- Fixture Modrinth project versions ---
    local pversions='[{"version_number":"1.0.0","game_versions":["1.21.4","1.21.3"],"version_type":"release","files":[{"url":"https://cdn.modrinth.com/x.mrpack"}]},{"version_number":"0.9.0","game_versions":["1.21.2"],"version_type":"beta"}]'
    out=$(mc_parse_modrinth_project_versions "$pversions")
    if printf '%s\n' "$out" | grep -qF "1.0.0 | 1.21.4,1.21.3 | release"; then
        echo "[mc-manifests] project versions parse: OK"
    else
        echo "[mc-manifests] project versions parse FAIL: out=[$out]" >&2
        fails=$((fails+1))
    fi

    # --- Sugestão de versão próxima ---
    local supported="1.21.4
1.21.3
1.20.6
1.20.1
1.19.4"

    if [ "$(mc_suggest_closest_version "1.21.4" "$supported")" = "1.21.4" ]; then
        echo "[mc-manifests] suggest exact: OK"
    else
        echo "[mc-manifests] suggest exact FAIL" >&2
        fails=$((fails+1))
    fi

    # 1.21.5 não existe -> mesma major.minor 1.21.x -> pega 1.21.4 (mais recente).
    if [ "$(mc_suggest_closest_version "1.21.5" "$supported")" = "1.21.4" ]; then
        echo "[mc-manifests] suggest same-minor: OK"
    else
        echo "[mc-manifests] suggest same-minor FAIL" >&2
        fails=$((fails+1))
    fi

    # 1.20.5 não existe -> mesma minor 1.20.x -> pega 1.20.6 (mais recente).
    if [ "$(mc_suggest_closest_version "1.20.5" "$supported")" = "1.20.6" ]; then
        echo "[mc-manifests] suggest same-minor 1.20: OK"
    else
        echo "[mc-manifests] suggest same-minor 1.20 FAIL" >&2
        fails=$((fails+1))
    fi

    # 1.22 (major futura) -> fallback para mais recente (1.21.4).
    if [ "$(mc_suggest_closest_version "1.22" "$supported")" = "1.21.4" ]; then
        echo "[mc-manifests] suggest fallback-latest: OK"
    else
        echo "[mc-manifests] suggest fallback FAIL" >&2
        fails=$((fails+1))
    fi

    # Lista vazia -> vazio.
    if [ -z "$(mc_suggest_closest_version "1.21.4" "")" ]; then
        echo "[mc-manifests] suggest empty-list: OK"
    else
        echo "[mc-manifests] suggest empty FAIL" >&2
        fails=$((fails+1))
    fi

    if [ "$fails" -gt 0 ]; then
        echo "[mc-manifests] selftest: $fails falha(s)" >&2
        return 1
    fi
    echo "[mc-manifests] selftest: todos passaram"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        selftest) _mc_manifests_selftest ;;
        *)
            echo "Uso: source este arquivo OU rode 'bash $0 selftest'"
            ;;
    esac
fi
