#!/bin/bash
# tests/mc-manifests-test.sh
#
# Testa shared/lib/mc-manifests.sh: parsing de manifests (Mojang, Fabric,
# Modrinth search, Modrinth project versions), extracao de slug/version_number,
# e sugestao de versao MC mais proxima.
#
# Usa fixtures JSON em tests/fixtures/ (sem rede — pure parsing).
# Este teste NAO chama a rede; a funcao de fetch e mockada substituindo o
# conteudo do fixture pela chamada mc_parse_*.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/mc-manifests.sh"

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

echo "[mc-manifests-test] Testando parsing de manifests (sem rede)..."

# --- 1. Mojang parse: releases only ---
echo "- Mojang manifest (releases only):"
json=$(cat "$FIXTURES/mojang-version-manifest.json")
out=$(mc_parse_mojang_versions "$json" 0)
# Esperado: 1.21.4, 1.21.3, 1.21.1, 1.20.6, 1.20.1 (5 releases; sem snapshot, sem alpha)
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 5 ]; then
    pass "5 releases parseadas"
else
    fail "5 releases esperadas" "5" "$count"
fi
if printf '%s\n' "$out" | grep -qFx "1.21.4"; then
    pass "1.21.4 presente"
else
    fail "1.21.4 ausente"
fi
if printf '%s\n' "$out" | grep -qF "25w03a"; then
    fail "snapshot 25w03a nao deveria aparecer (releases only)"
else
    pass "snapshot ausente (releases only)"
fi
if printf '%s\n' "$out" | grep -qF "a1.0.0"; then
    fail "old_alpha a1.0.0 nao deveria aparecer"
else
    pass "old_alpha ausente"
fi

# --- 2. Mojang parse: com snapshots ---
echo "- Mojang manifest (com snapshots):"
out=$(mc_parse_mojang_versions "$json" 1)
if printf '%s\n' "$out" | grep -qF "25w03a (snapshot)"; then
    pass "snapshot marcado visualmente"
else
    fail "snapshot marcado ausente"
fi
if printf '%s\n' "$out" | grep -qF "a1.0.0"; then
    fail "old_alpha nao deveria aparecer mesmo com snapshots"
else
    pass "old_alpha ainda ausente (com snapshots)"
fi

# --- 3. Fabric parse ---
echo "- Fabric manifest:"
json=$(cat "$FIXTURES/fabric-game-versions.json")
out=$(mc_parse_fabric_versions "$json" 0)
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 6 ]; then
    pass "6 releases estaveis fabric"
else
    fail "6 releases estaveis esperadas" "6" "$count"
fi
if printf '%s\n' "$out" | grep -qFx "1.21.4"; then
    pass "1.21.4 fabric presente"
else
    fail "1.21.4 fabric ausente"
fi
if printf '%s\n' "$out" | grep -qF "25w03a"; then
    fail "fabric snapshot 25w03a nao deveria aparecer (releases only)"
else
    pass "fabric snapshot ausente (releases only)"
fi

# --- 4. Fabric parse com snapshots ---
out=$(mc_parse_fabric_versions "$json" 1)
if printf '%s\n' "$out" | grep -qF "25w03a (snapshot)"; then
    pass "fabric snapshot marcado"
else
    fail "fabric snapshot marcado ausente"
fi

# --- 5. Modrinth search parse ---
echo "- Modrinth search (modpacks):"
json=$(cat "$FIXTURES/modrinth-search-modpacks.json")
out=$(mc_parse_modrinth_search "$json")
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 3 ]; then
    pass "3 hits parseados"
else
    fail "3 hits esperados" "3" "$count"
fi
if printf '%s\n' "$out" | grep -qF "adrenaline | Adrenaline | ↓1234567"; then
    pass "linha adrenaline formatada corretamente"
else
    fail "linha adrenaline formatada incorretamente"
fi
if printf '%s\n' "$out" | grep -qF "fabulously-optimized"; then
    pass "fabulously-optimized presente"
else
    fail "fabulously-optimized ausente"
fi
if printf '%s\n' "$out" | grep -qF "simply-optimized | Simply Optimized | ↓500000"; then
    pass "linha simply-optimized formatada corretamente"
else
    fail "linha simply-optimized formatada incorretamente"
fi

# --- 6. Extract slug ---
echo "- Extracao de slug:"
slug=$(mc_extract_slug "adrenaline | Adrenaline | ↓1234567")
if [ "$slug" = "adrenaline" ]; then
    pass "extract_slug = adrenaline"
else
    fail "extract_slug" "adrenaline" "$slug"
fi
slug=$(mc_extract_slug "fabulously-optimized | Fabulously Optimized | ↓987654")
if [ "$slug" = "fabulously-optimized" ]; then
    pass "extract_slug com hyphen = fabulously-optimized"
else
    fail "extract_slug com hyphen" "fabulously-optimized" "$slug"
fi

# --- 7. Modrinth project versions parse ---
echo "- Modrinth project versions:"
json=$(cat "$FIXTURES/modrinth-project-versions.json")
out=$(mc_parse_modrinth_project_versions "$json")
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 2 ]; then
    pass "2 versoes parseadas"
else
    fail "2 versoes esperadas" "2" "$count"
fi
if printf '%s\n' "$out" | grep -qF "1.0.0 | 1.21.4,1.21.3 | release"; then
    pass "linha v1.0.0 formatada corretamente"
else
    fail "linha v1.0.0 formatada incorretamente"
fi
if printf '%s\n' "$out" | grep -qF "0.9.0 | 1.21.1 | beta"; then
    pass "linha v0.9.0 (beta) formatada"
else
    fail "linha v0.9.0 ausente"
fi

# --- 8. Extract version_number ---
vn=$(mc_extract_version_number "1.0.0 | 1.21.4,1.21.3 | release")
if [ "$vn" = "1.0.0" ]; then
    pass "extract_version_number = 1.0.0"
else
    fail "extract_version_number" "1.0.0" "$vn"
fi

# --- 9. Sugestao de versao proxima ---
echo "- Sugestao de versao proxima:"
supported="1.21.4
1.21.3
1.21.1
1.20.6
1.20.1
1.19.4"

# Match exato.
r=$(mc_suggest_closest_version "1.21.4" "$supported")
if [ "$r" = "1.21.4" ]; then
    pass "suggest exact 1.21.4"
else
    fail "suggest exact" "1.21.4" "$r"
fi

# Mesma minor 1.21.x -> pega 1.21.4 (mais recente).
r=$(mc_suggest_closest_version "1.21.5" "$supported")
if [ "$r" = "1.21.4" ]; then
    pass "suggest same-minor 1.21.5 -> 1.21.4"
else
    fail "suggest same-minor" "1.21.4" "$r"
fi

# 1.20.5 nao existe -> mesma minor 1.20.x -> 1.20.6.
r=$(mc_suggest_closest_version "1.20.5" "$supported")
if [ "$r" = "1.20.6" ]; then
    pass "suggest same-minor 1.20.5 -> 1.20.6"
else
    fail "suggest same-minor 1.20" "1.20.6" "$r"
fi

# 1.18 (major ausente) -> fallback para mais recente 1.21.4.
r=$(mc_suggest_closest_version "1.18.2" "$supported")
if [ "$r" = "1.21.4" ]; then
    pass "suggest fallback-latest 1.18.2 -> 1.21.4"
else
    fail "suggest fallback" "1.21.4" "$r"
fi

# Lista vazia -> vazio.
r=$(mc_suggest_closest_version "1.21.4" "")
if [ -z "$r" ]; then
    pass "suggest empty-list -> vazio"
else
    fail "suggest empty" "" "$r"
fi

# Input não-numérico (snapshot "25w03a") -> fallback latest.
r=$(mc_suggest_closest_version "25w03a" "$supported")
if [ "$r" = "1.21.4" ]; then
    pass "suggest snapshot input (25w03a) -> fallback latest"
else
    fail "suggest snapshot input" "1.21.4" "$r"
fi

# --- 9b. NeoForge XML parse ---
echo "- NeoForge maven-metadata.xml:"
json=$(cat "$FIXTURES/neoforge-maven-metadata.xml")
out=$(mc_parse_neoforge_versions "$json" 0)
# Esperado (releases only, sem -beta): 1.21.0, 1.20.6, 1.20.4
# (21.0.143 -> 1.21.0; 21.0.140 -> 1.21.0 dedup; 20.6.121 -> 1.20.6;
#  20.6.100-beta pulado; 20.4.237 -> 1.20.4; 20.2.46-beta pulado)
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 3 ]; then
    pass "neoforge releases: 3 versoes MC unicas (21.0 + 20.6 + 20.4)"
else
    fail "neoforge releases count" "3" "$count"
fi
if printf '%s\n' "$out" | grep -qFx "1.21.0"; then
    pass "neoforge 21.0.143 -> 1.21.0"
else
    fail "neoforge 21.0 mapeamento" "1.21.0" "$(printf '%s' "$out" | head -1)"
fi
if printf '%s\n' "$out" | grep -qFx "1.20.6"; then
    pass "neoforge 20.6.121 -> 1.20.6"
else
    fail "neoforge 20.6 mapeamento"
fi
if printf '%s\n' "$out" | grep -qFx "1.20.4"; then
    pass "neoforge 20.4.237 -> 1.20.4"
else
    fail "neoforge 20.4 mapeamento"
fi
if ! printf '%s\n' "$out" | grep -qF "1.20.2"; then
    pass "neoforge 20.2.46-beta excluido (releases only)"
else
    fail "neoforge beta nao deveria aparecer em releases only"
fi

# NeoForge com snapshots: inclui 1.20.2 (do 20.2.46-beta).
out=$(mc_parse_neoforge_versions "$json" 1)
if printf '%s\n' "$out" | grep -qFx "1.20.2"; then
    pass "neoforge com snapshots inclui 1.20.2 (do -beta)"
else
    fail "neoforge snapshots deveria incluir 1.20.2"
fi

# --- 9c. Forge XML parse ---
echo "- Forge maven-metadata.xml:"
json=$(cat "$FIXTURES/forge-maven-metadata.xml")
out=$(mc_parse_forge_versions "$json" 0)
# Esperado: 1.21.8, 1.21.4, 1.21.1, 1.20.6, 1.20.1, 1.19.4 (6 versoes MC)
count=$(printf '%s\n' "$out" | grep -c . || true)
if [ "$count" -eq 6 ]; then
    pass "forge releases: 6 versoes MC"
else
    fail "forge releases count" "6" "$count"
fi
if printf '%s\n' "$out" | grep -qFx "1.21.8"; then
    pass "forge 1.21.8-58.0.3 -> 1.21.8"
else
    fail "forge 1.21.8 mapeamento"
fi
if printf '%s\n' "$out" | grep -qFx "1.20.1"; then
    pass "forge 1.20.1-47.3.12 -> 1.20.1"
else
    fail "forge 1.20.1 mapeamento"
fi
if printf '%s\n' "$out" | grep -qFx "1.19.4"; then
    pass "forge 1.19.4-44.1.0 -> 1.19.4"
else
    fail "forge 1.19.4 mapeamento"
fi
# Verifica que o forgever (depois do -) nao aparece na saida.
if printf '%s\n' "$out" | grep -qF "58.0.3"; then
    fail "forge: forgever nao deveria aparecer (soh MC version)"
else
    pass "forge: forgever excluido da saida"
fi

# --- 10. Loaders suportados (sem paper) ---
echo "- Loader validation (paper removido):"
# mc_get_versions_for_loader paper deve falhar (return 1) sem chamar rede.
if mc_get_versions_for_loader paper 0 >/dev/null 2>&1; then
    fail "loader paper deveria ser rejeitado por mc_get_versions_for_loader"
else
    pass "loader paper rejeitado"
fi

# --- 11. Empty input ---
echo "- Inputs vazios:"
out=$(mc_parse_mojang_versions "" 0)
if [ -z "$out" ]; then
    pass "mojang empty input -> vazio"
else
    fail "mojang empty"
fi
out=$(mc_parse_modrinth_search "")
if [ -z "$out" ]; then
    pass "modrinth search empty -> vazio"
else
    fail "modrinth empty"
fi
out=$(mc_parse_modrinth_project_versions "")
if [ -z "$out" ]; then
    pass "project versions empty -> vazio"
else
    fail "project empty"
fi

echo ""
echo "[mc-manifests-test] PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
