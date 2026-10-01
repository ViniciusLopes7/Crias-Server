#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared/lib/common.sh"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared/lib/config-parser.sh"

# shellcheck source=/dev/null
# Provides download_file() and _curl_with_retry() for this script and stack installers.
source "$SCRIPT_DIR/shared/lib/downloads.sh"

# shellcheck source=/dev/null
# TUI library (gum wrapper with read-based fallback).
source "$SCRIPT_DIR/shared/lib/tui.sh"

# shellcheck source=/dev/null
# Minecraft manifests + Modrinth API helpers (dynamic version/modpack selection).
source "$SCRIPT_DIR/shared/lib/mc-manifests.sh"

# shellcheck source=/dev/null
# tModLoader versions + SteamCMD + mod catalog (Terraria mods).
source "$SCRIPT_DIR/shared/lib/tmodloader.sh"

# Load config once before defaults to avoid capturing false values.
apply_config_with_env_precedence "$CONFIG_FILE"

# Defaults (precedence: defaults < config.env < env vars).
SERVER_TYPE="${SERVER_TYPE:-}"
FORCE_HARDWARE_TIER="${FORCE_HARDWARE_TIER:-}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-true}"
APPLY_SYSTEM_TUNING="${APPLY_SYSTEM_TUNING:-true}"
SYSTEM_TUNING_SCOPE="${SYSTEM_TUNING_SCOPE:-host}"
CLEANUP_OTHER_STACK="${CLEANUP_OTHER_STACK:-true}"
DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# Hardware tier thresholds.
HW_LOW_TIER_MAX_RAM_MB="${HW_LOW_TIER_MAX_RAM_MB:-3072}"
HW_LOW_TIER_MAX_CPU_CORES="${HW_LOW_TIER_MAX_CPU_CORES:-2}"
HW_MID_TIER_MAX_RAM_MB="${HW_MID_TIER_MAX_RAM_MB:-12288}"
HW_MID_TIER_MAX_CPU_CORES="${HW_MID_TIER_MAX_CPU_CORES:-6}"

# Virtualization tuning: auto skips containers/VPS, force always applies.
VIRT_TUNING_BEHAVIOR="${VIRT_TUNING_BEHAVIOR:-auto}"

MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_SERVER_DIR="${MINECRAFT_SERVER_DIR:-/opt/minecraft-server}"
MINECRAFT_PORT="${MINECRAFT_PORT:-25565}"
MINECRAFT_ONLINE_MODE="${MINECRAFT_ONLINE_MODE:-true}"
MINECRAFT_MOTD="${MINECRAFT_MOTD:-§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.11}"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
MINECRAFT_INSTALL_MODPACK="${MINECRAFT_INSTALL_MODPACK:-true}"
MINECRAFT_ADRENALINE_VERSION="${MINECRAFT_ADRENALINE_VERSION:-}"
MINECRAFT_INSTALL_QOL_MODS="${MINECRAFT_INSTALL_QOL_MODS:-true}"
# QoL mods CSV list.
MINECRAFT_QOL_MODS="${MINECRAFT_QOL_MODS:-chunky:chunky,essential-commands:essential-commands,universal-graves:universal-graves,tabtps:tabtps,styled-chat:styled-chat,polymer:polymer,placeholder-api:placeholder-api}"
# Modpack source.
MINECRAFT_MODPACK_SOURCE="${MINECRAFT_MODPACK_SOURCE:-adrenaline}"
MINECRAFT_MODPACK_SLUG="${MINECRAFT_MODPACK_SLUG:-adrenaline}"
MRPACK_INSTALL_VERSION="${MRPACK_INSTALL_VERSION:-v0.21.0-beta}"
ACCEPT_EULA="${ACCEPT_EULA:-false}"

TERRARIA_USER="${TERRARIA_USER:-terraria}"
TERRARIA_SERVER_DIR="${TERRARIA_SERVER_DIR:-/opt/terraria-server}"
TERRARIA_PORT="${TERRARIA_PORT:-7777}"
TERRARIA_WORLD_NAME="${TERRARIA_WORLD_NAME:-world}"
TERRARIA_MOTD="${TERRARIA_MOTD:-Servidor Terraria gerenciado por Crias-Server}"
TERRARIA_DOWNLOAD_URL="${TERRARIA_DOWNLOAD_URL:-https://terraria.org/api/download/pc-dedicated-server/terraria-server-1456.zip}"

# Optional remote control agent install.
INSTALL_AGENT="${INSTALL_AGENT:-}"

# SSH: vazio = pergunta interativamente (default N). true/false = força.
# Se true, instala openssh no host, habilita sshd, cria usuario 'crias' com sudo.
INSTALL_SSH="${INSTALL_SSH:-}"

# tModLoader para Terraria (WIP — v1.2.0). Nao implementado completamente.
# Reservado para futura instalacao de mods no Terraria.
TERRARIA_USE_TMODLOADER="${TERRARIA_USE_TMODLOADER:-false}"
TERRARIA_TMODLOADER_VERSION="${TERRARIA_TMODLOADER_VERSION:-}"
TERRARIA_TMODLOADER_MODS="${TERRARIA_TMODLOADER_MODS:-}"

select_server_type() {
    if [ "$SERVER_TYPE" = "minecraft" ] || [ "$SERVER_TYPE" = "terraria" ]; then
        return 0
    fi

    if is_true "$NON_INTERACTIVE"; then
        print_error "SERVER_TYPE precisa ser definido como minecraft ou terraria quando NON_INTERACTIVE=true."
        exit 1
    fi

    tui_choose SERVER_TYPE "Qual servidor deseja instalar?" "$SERVER_TYPE" "minecraft" "terraria"
}

prompt_global_options() {
    if is_true "$NON_INTERACTIVE"; then
        return 0
    fi

    echo ""
    if tui_confirm "Deseja revisar opcoes globais?" "N"; then
        tui_help "hardware-tier" 2>/dev/null || true
        tui_input FORCE_HARDWARE_TIER "Forcar tier de hardware (LOW/MID/HIGH ou vazio para auto)" "$FORCE_HARDWARE_TIER"

        if tui_confirm "Instalar/configurar Tailscale?" "Y"; then
            INSTALL_TAILSCALE="true"
        else
            INSTALL_TAILSCALE="false"
        fi

        if tui_confirm "Aplicar tuning de sistema (zram/scheduler/cpupower)?" "Y"; then
            APPLY_SYSTEM_TUNING="true"
        else
            APPLY_SYSTEM_TUNING="false"
        fi

        if tui_confirm "Limpar stack nao selecionado apos instalar?" "Y"; then
            CLEANUP_OTHER_STACK="true"
        else
            CLEANUP_OTHER_STACK="false"
        fi

        # Nova opcao desde v1.2.0: habilitar SSH no host instalado.
        if tui_confirm "Habilitar acesso SSH no servidor instalado? (cria usuario 'crias' com sudo)" "N"; then
            INSTALL_SSH="true"
        else
            INSTALL_SSH="false"
        fi
    fi
}

prompt_minecraft_options() {
    if is_true "$NON_INTERACTIVE"; then
        return 0
    fi

    echo ""
    if tui_confirm "Deseja revisar configuracoes do Minecraft?" "Y"; then
        tui_input MINECRAFT_USER "Usuario do Minecraft" "$MINECRAFT_USER"
        tui_input MINECRAFT_SERVER_DIR "Diretorio do Minecraft" "$MINECRAFT_SERVER_DIR"
        tui_input MINECRAFT_PORT "Porta do Minecraft" "$MINECRAFT_PORT"
        tui_input MINECRAFT_MOTD "MOTD (Message of the Day)" "$MINECRAFT_MOTD"

        # Loader selection via TUI (paper not supported).
        tui_help "loader" 2>/dev/null || true
        tui_choose MINECRAFT_LOADER "Loader (fabric/quilt/vanilla/forge/neoforge)" "$MINECRAFT_LOADER" \
            "fabric" "quilt" "vanilla" "forge" "neoforge"

        # Dynamic MC version selection via Modrinth/Mojang manifest.
        prompt_minecraft_version_dynamic

        if tui_confirm "Ativar online-mode=true (premium)?" "N"; then
            MINECRAFT_ONLINE_MODE="true"
        else
            MINECRAFT_ONLINE_MODE="false"
        fi

        # Modpack source: dynamic top-10 Modrinth / search / vanilla / manual slug.
        prompt_minecraft_modpack_dynamic

        if tui_confirm "Instalar mods QoL adicionais?" "Y"; then
            MINECRAFT_INSTALL_QOL_MODS="true"
        else
            MINECRAFT_INSTALL_QOL_MODS="false"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Dynamic Minecraft version selection.
# Busca versoes do manifest do loader selecionado e oferece selecao via TUI
# (gum filter). Se sem internet, aborta com mensagem clara (server.jar exige
# download). Mostra snapshots marcados visualmente se usuario optar.
# ---------------------------------------------------------------------------
prompt_minecraft_version_dynamic() {
    print_step "Buscando versoes de Minecraft para loader: $MINECRAFT_LOADER ..."

    if ! mc_has_internet; then
        print_error "Sem conexao com internet. A selecao dinamica de versao e o"
        print_error "download do server.jar exigem internet. Conecte-se e tente novamente."
        if is_true "$NON_INTERACTIVE"; then
            return 0
        fi
        exit 1
    fi

    # Pergunta se quer ver snapshots.
    local include_snapshots=0
    if tui_confirm "Mostrar snapshots/pre-releases na lista de versoes? (marcados visualmente)" "N"; then
        include_snapshots=1
    fi

    local versions
    if ! versions=$(mc_get_versions_for_loader "$MINECRAFT_LOADER" "$include_snapshots") || [ -z "$versions" ]; then
        print_warning "Falha ao buscar versoes dinamicas para loader '$MINECRAFT_LOADER'."
        print_warning "Usando versao default do config.env: $MINECRAFT_VERSION"
        tui_input MINECRAFT_VERSION "Versao do Minecraft (manual)" "$MINECRAFT_VERSION"
        return 0
    fi

    local selected
    if selected=$(printf '%s\n' "$versions" | tui_filter "Selecione a versao do Minecraft (busca fuzzy)") && [ -n "$selected" ]; then
        # Limpa marker "(snapshot)" se presente.
        MINECRAFT_VERSION="${selected%% *}"
        print_success "Versao selecionada: $MINECRAFT_VERSION"
    else
        print_warning "Selecao cancelada; usando default: $MINECRAFT_VERSION"
    fi
}

# ---------------------------------------------------------------------------
# Dynamic modpack selection.
# Fonte: top-10 Modrinth (downloads) / busca por nome / vanilla (so loader) /
# slug Modrinth manual. Busca versoes do modpack compatíveis com o loader+MC
# selecionado (filtro server-side); se nenhuma compativel, sugere MC mais
# proxima.
# ---------------------------------------------------------------------------
prompt_minecraft_modpack_dynamic() {
    local source
    tui_help "modpack" 2>/dev/null || true
    tui_choose source "Fonte do modpack?" "adrenaline" \
        "Top 10 modpacks (Modrinth)" \
        "Buscar modpack por nome" \
        "Vanilla (so loader, sem modpack)" \
        "Slug Modrinth manual"

    case "$source" in
        "Top 10 modpacks (Modrinth)")
            _prompt_modpack_top10 ;;
        "Buscar modpack por nome")
            _prompt_modpack_search ;;
        "Vanilla (so loader, sem modpack)")
            MINECRAFT_MODPACK_SOURCE="vanilla"
            MINECRAFT_INSTALL_MODPACK="false"
            return 0
            ;;
        "Slug Modrinth manual")
            MINECRAFT_MODPACK_SOURCE="modrinth"
            tui_input MINECRAFT_MODPACK_SLUG "Slug do modpack no Modrinth" "${MINECRAFT_MODPACK_SLUG:-adrenaline}"
            _prompt_modpack_select_version "$MINECRAFT_MODPACK_SLUG"
            ;;
        *)
            print_warning "Opcao invalida; mantendo default (adrenaline)."
            MINECRAFT_MODPACK_SOURCE="adrenaline"
            MINECRAFT_MODPACK_SLUG="adrenaline"
            ;;
    esac

    if [ "$MINECRAFT_MODPACK_SOURCE" != "vanilla" ]; then
        MINECRAFT_INSTALL_MODPACK="true"
    fi
}

_prompt_modpack_top10() {
    print_step "Buscando top 10 modpacks no Modrinth (por downloads) ..."
    if ! mc_has_internet; then
        print_error "Sem internet para buscar modpacks. Conecte-se e tente novamente."
        exit 1
    fi
    local json results selected
    json=$(mc_fetch_modrinth_search_modpacks "" 10) || true
    results=$(mc_parse_modrinth_search "$json")
    if [ -z "$results" ]; then
        print_error "Nenhum modpack encontrado na busca do Modrinth."
        return 1
    fi
    if selected=$(printf '%s\n' "$results" | tui_filter "Selecione o modpack (top 10 Modrinth)") && [ -n "$selected" ]; then
        MINECRAFT_MODPACK_SOURCE="modrinth"
        MINECRAFT_MODPACK_SLUG=$(mc_extract_slug "$selected")
        print_success "Modpack: $MINECRAFT_MODPACK_SLUG"
        _prompt_modpack_select_version "$MINECRAFT_MODPACK_SLUG"
    else
        print_warning "Selecao cancelada; usando default adrenaline."
        MINECRAFT_MODPACK_SOURCE="adrenaline"
        MINECRAFT_MODPACK_SLUG="adrenaline"
    fi
}

_prompt_modpack_search() {
    local query
    tui_input query "Buscar modpack por nome (ex.: Fabulously Optimized)" ""
    if [ -z "$query" ]; then
        print_warning "Busca vazia; usando default adrenaline."
        MINECRAFT_MODPACK_SOURCE="adrenaline"
        MINECRAFT_MODPACK_SLUG="adrenaline"
        return 0
    fi
    print_step "Buscando modpacks no Modrinth por: $query ..."
    if ! mc_has_internet; then
        print_error "Sem internet para buscar modpacks."
        exit 1
    fi
    local json results selected
    json=$(mc_fetch_modrinth_search_modpacks "$query" 10) || true
    results=$(mc_parse_modrinth_search "$json")
    if [ -z "$results" ]; then
        print_error "Nenhum modpack encontrado para '$query'."
        return 1
    fi
    if selected=$(printf '%s\n' "$results" | tui_filter "Resultados para '$query'") && [ -n "$selected" ]; then
        MINECRAFT_MODPACK_SOURCE="modrinth"
        MINECRAFT_MODPACK_SLUG=$(mc_extract_slug "$selected")
        print_success "Modpack: $MINECRAFT_MODPACK_SLUG"
        _prompt_modpack_select_version "$MINECRAFT_MODPACK_SLUG"
    else
        print_warning "Selecao cancelada; usando default adrenaline."
        MINECRAFT_MODPACK_SOURCE="adrenaline"
        MINECRAFT_MODPACK_SLUG="adrenaline"
    fi
}

# Seleciona versao do modpack compativel com o loader+MC selecionados.
# Se nenhuma versao compativel, sugere MC mais proxima e pergunta se troca.
_prompt_modpack_select_version() {
    local slug="$1"
    print_step "Buscando versoes de '$slug' compativeis com $MINECRAFT_LOADER + MC $MINECRAFT_VERSION ..."
    local json versions selected
    json=$(mc_fetch_modrinth_project_versions "$slug" "$MINECRAFT_LOADER" "$MINECRAFT_VERSION") || true
    versions=$(mc_parse_modrinth_project_versions "$json")

    if [ -n "$versions" ]; then
        if selected=$(printf '%s\n' "$versions" | tui_filter "Versoes compativeis (selecione)") && [ -n "$selected" ]; then
            MINECRAFT_ADRENALINE_VERSION=$(mc_extract_version_number "$selected")
            print_success "Versao do modpack: $MINECRAFT_ADRENALINE_VERSION"
        else
            print_warning "Sem selecao; mrpack-install usara a mais recente."
            MINECRAFT_ADRENALINE_VERSION=""
        fi
        return 0
    fi

    # Nenhuma versao compativel. Sugerir MC mais proxima.
    print_warning "Nenhuma versao de '$slug' compativel com MC $MINECRAFT_VERSION + $MINECRAFT_LOADER."
    print_step "Buscando versoes do modpack para o loader $MINECRAFT_LOADER (para sugerir MC mais proxima)..."
    # Filtra por loader (sem MC especifica) para respeitar a escolha do usuario
    # e evitar sugerir MC de versao que so existe para outro loader.
    local all_json all_versions
    all_json=$(mc_fetch_modrinth_project_versions "$slug" "$MINECRAFT_LOADER" "") || true
    # Extrai game_versions suportadas (unica, ordenadas pela posicao = mais recente primeiro).
    all_versions=$(printf '%s' "$all_json" | jq -r '
        .[]?.game_versions[]?
    ' 2>/dev/null | awk '!seen[$0]++' || true)

    if [ -z "$all_versions" ]; then
        print_error "Nao foi possivel obter versoes suportadas por '$slug'."
        print_warning "Continuando com MC $MINECRAFT_VERSION; o modpack pode falhar ao instalar."
        MINECRAFT_ADRENALINE_VERSION=""
        return 0
    fi

    local suggested
    suggested=$(mc_suggest_closest_version "$MINECRAFT_VERSION" "$all_versions")
    if [ -n "$suggested" ] && [ "$suggested" != "$MINECRAFT_VERSION" ]; then
        print_step "Versao de Minecraft mais proxima suportada por '$slug': $suggested"
        if tui_confirm "Trocar a versao do MC de $MINECRAFT_VERSION para $suggested?" "Y"; then
            MINECRAFT_VERSION="$suggested"
            print_success "Versao do MC ajustada para: $MINECRAFT_VERSION"
            # Re-busca versoes do modpack com a nova MC.
            json=$(mc_fetch_modrinth_project_versions "$slug" "$MINECRAFT_LOADER" "$MINECRAFT_VERSION") || true
            versions=$(mc_parse_modrinth_project_versions "$json")
            if [ -n "$versions" ] && selected=$(printf '%s\n' "$versions" | tui_filter "Versoes compativeis (MC $MINECRAFT_VERSION)") && [ -n "$selected" ]; then
                MINECRAFT_ADRENALINE_VERSION=$(mc_extract_version_number "$selected")
                print_success "Versao do modpack: $MINECRAFT_ADRENALINE_VERSION"
            else
                MINECRAFT_ADRENALINE_VERSION=""
            fi
        else
            print_warning "Mantendo MC $MINECRAFT_VERSION; o modpack pode falhar."
            MINECRAFT_ADRENALINE_VERSION=""
        fi
    else
        print_warning "Nao foi possivel sugerir versao proxima; continuando."
        MINECRAFT_ADRENALINE_VERSION=""
    fi
}

prompt_terraria_options() {
    if is_true "$NON_INTERACTIVE"; then
        return 0
    fi

    echo ""
    if tui_confirm "Deseja revisar configuracoes do Terraria?" "Y"; then
        tui_input TERRARIA_USER "Usuario do Terraria" "$TERRARIA_USER"
        tui_input TERRARIA_SERVER_DIR "Diretorio do Terraria" "$TERRARIA_SERVER_DIR"
        tui_input TERRARIA_PORT "Porta do Terraria" "$TERRARIA_PORT"
        tui_input TERRARIA_WORLD_NAME "Nome do mundo" "$TERRARIA_WORLD_NAME"
        tui_input TERRARIA_MOTD "MOTD" "$TERRARIA_MOTD"
        tui_input TERRARIA_DOWNLOAD_URL "URL de download do pacote Terraria" "$TERRARIA_DOWNLOAD_URL"

        # tModLoader: pergunta se quer usar (substitui vanilla).
        if tui_confirm "Usar tModLoader (Terraria com mods)? Substitui o servidor vanilla." "N"; then
            TERRARIA_USE_TMODLOADER="true"
            prompt_tmodloader_options
        else
            TERRARIA_USE_TMODLOADER="false"
        fi
    fi
}

# ---------------------------------------------------------------------------
# tModLoader: seleção de versão (GitHub Releases) + mods (catálogo curado).
# ---------------------------------------------------------------------------
prompt_tmodloader_options() {
    print_step "Buscando versões do tModLoader (GitHub Releases)..."

    if ! mc_has_internet; then
        print_error "Sem internet para buscar versões do tModLoader."
        print_error "Defina TERRARIA_TMODLOADER_VERSION em config.env ou conecte-se."
        if is_true "$NON_INTERACTIVE"; then
            return 0
        fi
        exit 1
    fi

    # Pergunta se quer ver pre-releases.
    local include_pre=0
    if tui_confirm "Mostrar pre-releases do tModLoader na lista?" "N"; then
        include_pre=1
    fi

    local versions
    if ! versions=$(tml_get_versions "$include_pre") || [ -z "$versions" ]; then
        print_warning "Falha ao buscar versões dinâmicas do tModLoader."
        print_warning "Usando versão default: ${TERRARIA_TMODLOADER_VERSION:-latest}"
        if [ -z "$TERRARIA_TMODLOADER_VERSION" ]; then
            tui_input TERRARIA_TMODLOADER_VERSION "Versão do tModLoader (tag, ex.: v2026.06.3.6)" "latest"
        fi
    else
        local selected
        if selected=$(printf '%s\n' "$versions" | tui_filter "Selecione a versão do tModLoader (busca fuzzy)") && [ -n "$selected" ]; then
            TERRARIA_TMODLOADER_VERSION="${selected%% *}"
            print_success "Versão tModLoader: $TERRARIA_TMODLOADER_VERSION"
        else
            print_warning "Seleção cancelada; usando latest."
            TERRARIA_TMODLOADER_VERSION=""
        fi
    fi

    # Seletor de mods: catálogo curado + busca manual + nenhum.
    prompt_tmodloader_mods
}

prompt_tmodloader_mods() {
    local source
    tui_choose source "Como instalar mods do tModLoader?" "catalog" \
        "Catálogo curado (Calamity, Thorium, etc.)" \
        "Sem mods (instalar tModLoader vazio)" \
        "Workshop IDs manuais (CSV)"

    case "$source" in
        "Catálogo curado (Calamity, Thorium, etc.)")
            _prompt_tml_catalog_mods
            ;;
        "Sem mods (instalar tModLoader vazio)")
            TERRARIA_TMODLOADER_MODS=""
            print_step "tModLoader será instalado sem mods. Você pode adicioná-los depois em Mods/"
            ;;
        "Workshop IDs manuais (CSV)")
            local manual_ids
            tui_input manual_ids "Workshop IDs (CSV, ex.: 2824688072,2909886416)" "${TERRARIA_TMODLOADER_MODS:-}"
            TERRARIA_TMODLOADER_MODS="$manual_ids"
            ;;
        *)
            print_warning "Opção inválida; sem mods."
            TERRARIA_TMODLOADER_MODS=""
            ;;
    esac
}

_prompt_tml_catalog_mods() {
    print_step "Carregando catálogo de mods do tModLoader..."
    local catalog
    catalog=$(tml_mod_catalog_formatted)
    if [ -z "$catalog" ]; then
        print_error "Catálogo de mods vazio."
        return 1
    fi

    # Multi-seleção do catálogo (checklist TUI).
    local selected_csv
    tui_checklist selected_csv "Selecione os mods (espaço para toggle, Enter para confirmar)" "" \
        "Calamity Mod" \
        "Calamity Mod Music" \
        "Thorium Mod" \
        "Magic Storage" \
        "Recipe Browser"

    if [ -z "$selected_csv" ]; then
        print_step "Nenhum mod selecionado no catálogo."
        TERRARIA_TMODLOADER_MODS=""
        return 0
    fi

    # Mapeia display_name -> workshop_id.
    local workshop_ids=""
    local first=1
    local IFS=','
    local dname
    for dname in $selected_csv; do
        [ -z "$dname" ] && continue
        local wid
        wid=$(tml_extract_workshop_id_by_displayname "$dname")
        if [ -n "$wid" ]; then
            if [ "$first" -eq 1 ]; then
                workshop_ids="$wid"
                first=0
            else
                workshop_ids="$workshop_ids,$wid"
            fi
        fi
    done
    unset IFS

    TERRARIA_TMODLOADER_MODS="$workshop_ids"
    print_success "Mods selecionados: $TERRARIA_TMODLOADER_MODS"
}

install_tailscale_if_enabled() {
    local outdated_packages

    if ! is_true "$INSTALL_TAILSCALE"; then
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do Tailscale."
        return 0
    fi

    print_step "Instalando Tailscale..."

    # Skip download if already installed (e.g., from Crias ISO).
    if command_exists tailscale; then
        print_step "Tailscale já está instalado — pulando download."
    else
        # Install via pacman on bare Arch.
        outdated_packages="$(pacman -Qu 2>/dev/null || true)"
        if [ -n "$outdated_packages" ]; then
            print_warning "Foram detectados pacotes desatualizados no sistema."
            print_warning "Recomendado executar 'pacman -Syu' antes para evitar partial-upgrade."
            if ! is_true "$NON_INTERACTIVE"; then
                if ! tui_confirm "Continuar mesmo assim?" "N"; then
                    print_error "Instalacao do Tailscale cancelada pelo usuario."
                    return 1
                fi
            fi
        fi

        # Try pacman first.
        if ! pacman -S --needed --noconfirm tailscale; then
            print_warning "pacman -S tailscale falhou. Tentando via repo oficial Tailscale..."
            # Fallback: add Tailscale repo to pacman.conf.
            local tmpdir
            tmpdir="$(mktemp_crias_dir)"
            if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 \
                    -o "$tmpdir/tailscale.repo" \
                    https://pkgs.tailscale.com/stable/arch/tailscale.repo 2>/dev/null; then
                # Add [tailscale] repo to pacman.conf.
                if ! grep -q '^\[tailscale\]' /etc/pacman.conf 2>/dev/null; then
                    cat >> /etc/pacman.conf <<'EOF'

[tailscale]
Server = https://pkgs.tailscale.com/stable/arch/$arch
EOF
                fi
                # Import and sign Tailscale repo key.
                if ! pacman-key --recv-key 999EAC3D9BD5B7F7 2>&1 | sed 's/^/[pacman-key] /'; then
                    print_error "pacman-key --recv-key falhou para 999EAC3D9BD5B7F7 (chave Tailscale)."
                    print_error "Verifique conectividade com o keyserver e tente novamente."
                    rm -rf "$tmpdir"
                    return 1
                fi
                if ! pacman-key --lsign-key 999EAC3D9BD5B7F7 2>&1 | sed 's/^/[pacman-key] /'; then
                    print_error "pacman-key --lsign-key falhou para 999EAC3D9BD5B7F7 (chave Tailscale)."
                    rm -rf "$tmpdir"
                    return 1
                fi
                if ! pacman -Syy --noconfirm tailscale; then
                    print_error "Falha ao instalar Tailscale via repo oficial."
                    print_error "Instale manualmente depois: sudo pacman -S tailscale"
                    rm -rf "$tmpdir"
                    return 1
                fi
            else
                print_error "Não foi possível baixar repo Tailscale (sem internet?)."
                print_error "Instale manualmente depois: sudo pacman -S tailscale"
                rm -rf "$tmpdir"
                return 1
            fi
            rm -rf "$tmpdir"
        fi
    fi

    # Only report success if tailscaled is actually active.
    local tailscale_activated=false
    if command_exists systemctl; then
        if systemctl enable tailscaled >/dev/null 2>&1 && \
           systemctl start tailscaled >/dev/null 2>&1 && \
           systemctl is-active --quiet tailscaled; then
            tailscale_activated=true
        fi
    fi

    if [ "$tailscale_activated" = "true" ]; then
        print_success "Tailscale pronto. Execute 'sudo tailscale up' para autenticar."
    else
        print_warning "Tailscale foi instalado mas o serviço tailscaled não está ativo."
        print_warning "Verifique manualmente: sudo systemctl status tailscaled"
    fi
}

stack_alias_script() {
    local stack_type="$1"

    if [ "$stack_type" = "minecraft" ]; then
        echo "$MINECRAFT_SERVER_DIR/comandos.sh"
    else
        echo "$TERRARIA_SERVER_DIR/comandos.sh"
    fi
}

ensure_alias_autoload_entry() {
    local alias_script="$1"
    local profiled_path
    local source_line

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao automatica de aliases globais."
        return 0
    fi

    profiled_path="/etc/profile.d/crias-server.sh"
    source_line="[ -f \"$alias_script\" ] && . \"$alias_script\""

    if [ -f "$profiled_path" ]; then
        cleanup_stale_alias_autoload_entries "$profiled_path"

        if grep -Fqx "$source_line" "$profiled_path"; then
            print_step "Aliases globais ja configurados em $profiled_path"
            return 0
        fi

        # Append an idempotent source_line while preserving operator customizations.
        printf '# Generated by Crias-Server installer - do not edit manually\n' >> "$profiled_path"
        printf '%s\n' "$source_line" >> "$profiled_path"
    else
        # Create new file with header and source_line
        cat > "$profiled_path" << EOF
# Generated by Crias-Server installer - do not edit manually
$source_line
EOF
        chmod 0644 "$profiled_path"
    fi

    print_success "Aliases configurados automaticamente em $profiled_path"
    print_step "Abra um novo shell de login ou faca logout/login para carregar os atalhos."
    print_step "Opcional: carregue agora com: source $profiled_path"
}

cleanup_stale_alias_autoload_entries() {
    local profiled_path="$1"
    local tmp_file
    local line
    local alias_path

    if [ ! -f "$profiled_path" ]; then
        return 0
    fi

    tmp_file="$(mktemp_crias_file)"

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^\[\ -f\ \"([^\"]+)\"\ \]\ \&\&\ \.\ \"([^\"]+)\"$ ]]; then
            alias_path="${BASH_REMATCH[1]}"
            if [ ! -f "$alias_path" ]; then
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp_file"
    done < "$profiled_path"

    # Atomic mv.
    mv -f "$tmp_file" "$profiled_path"
    chmod 0644 "$profiled_path"
}

remove_alias_autoload_entry() {
    local alias_script="$1"
    local profiled_path
    local tmp_file

    if is_true "$DRY_RUN"; then
        return 0
    fi

    profiled_path="/etc/profile.d/crias-server.sh"

    if [ ! -f "$profiled_path" ]; then
        return 0
    fi

    tmp_file="$(mktemp_crias_file)"

    # Remove lines that exactly match the generated source line or the generated header comment.
    local source_line
    source_line="[ -f \"$alias_script\" ] && . \"$alias_script\""

    grep -Fv "$source_line" "$profiled_path" | grep -Fv '# Generated by Crias-Server installer - do not edit manually' > "$tmp_file" || true

    # Atomic mv.
    mv -f "$tmp_file" "$profiled_path"
    chmod 0644 "$profiled_path"
}

write_stack_env_file() {
    local env_file

    env_file="$(mktemp "${TMPDIR:-/tmp}/crias_stack_env.XXXXXX")"
    chmod 600 "$env_file"
    # Caller cleans up; validate write before returning path.
    if ! {
        printf 'FORCE_HARDWARE_TIER=%q\n' "$FORCE_HARDWARE_TIER"
        printf 'APPLY_SYSTEM_TUNING=%q\n' "$APPLY_SYSTEM_TUNING"
        printf 'SYSTEM_TUNING_SCOPE=%q\n' "$SYSTEM_TUNING_SCOPE"
        printf 'DRY_RUN=%q\n' "$DRY_RUN"
        printf 'NON_INTERACTIVE=%q\n' "$NON_INTERACTIVE"
        # Hardware tier thresholds.
        printf 'HW_LOW_TIER_MAX_RAM_MB=%q\n' "${HW_LOW_TIER_MAX_RAM_MB:-3072}"
        printf 'HW_LOW_TIER_MAX_CPU_CORES=%q\n' "${HW_LOW_TIER_MAX_CPU_CORES:-2}"
        printf 'HW_MID_TIER_MAX_RAM_MB=%q\n' "${HW_MID_TIER_MAX_RAM_MB:-12288}"
        printf 'HW_MID_TIER_MAX_CPU_CORES=%q\n' "${HW_MID_TIER_MAX_CPU_CORES:-6}"

        if [ "$SERVER_TYPE" = "minecraft" ]; then
            printf 'MINECRAFT_USER=%q\n' "$MINECRAFT_USER"
            printf 'MINECRAFT_SERVER_DIR=%q\n' "$MINECRAFT_SERVER_DIR"
            printf 'MINECRAFT_PORT=%q\n' "$MINECRAFT_PORT"
            printf 'MINECRAFT_ONLINE_MODE=%q\n' "$MINECRAFT_ONLINE_MODE"
            printf 'MINECRAFT_MOTD=%q\n' "$MINECRAFT_MOTD"
            printf 'MINECRAFT_VERSION=%q\n' "$MINECRAFT_VERSION"
            printf 'MINECRAFT_LOADER=%q\n' "$MINECRAFT_LOADER"
            printf 'MINECRAFT_INSTALL_MODPACK=%q\n' "$MINECRAFT_INSTALL_MODPACK"
            printf 'MINECRAFT_ADRENALINE_VERSION=%q\n' "$MINECRAFT_ADRENALINE_VERSION"
            printf 'MINECRAFT_INSTALL_QOL_MODS=%q\n' "$MINECRAFT_INSTALL_QOL_MODS"
            printf 'ACCEPT_EULA=%q\n' "${ACCEPT_EULA:-false}"
            printf 'MINECRAFT_QOL_MODS=%q\n' "${MINECRAFT_QOL_MODS:-}"
            printf 'MINECRAFT_MODPACK_SOURCE=%q\n' "${MINECRAFT_MODPACK_SOURCE:-adrenaline}"
            printf 'MINECRAFT_MODPACK_SLUG=%q\n' "${MINECRAFT_MODPACK_SLUG:-adrenaline}"
            printf 'MRPACK_INSTALL_VERSION=%q\n' "${MRPACK_INSTALL_VERSION:-v0.21.0-beta}"
        else
            printf 'TERRARIA_USER=%q\n' "$TERRARIA_USER"
            printf 'TERRARIA_SERVER_DIR=%q\n' "$TERRARIA_SERVER_DIR"
            printf 'TERRARIA_PORT=%q\n' "$TERRARIA_PORT"
            printf 'TERRARIA_WORLD_NAME=%q\n' "$TERRARIA_WORLD_NAME"
            printf 'TERRARIA_MOTD=%q\n' "$TERRARIA_MOTD"
            printf 'TERRARIA_DOWNLOAD_URL=%q\n' "$TERRARIA_DOWNLOAD_URL"
            printf 'TERRARIA_USE_TMODLOADER=%q\n' "$TERRARIA_USE_TMODLOADER"
            printf 'TERRARIA_TMODLOADER_VERSION=%q\n' "$TERRARIA_TMODLOADER_VERSION"
            printf 'TERRARIA_TMODLOADER_MODS=%q\n' "$TERRARIA_TMODLOADER_MODS"
        fi
    } > "$env_file"; then
        rm -f "$env_file"
        print_error "Falha ao escrever stack env file."
        return 1
    fi

    printf '%s\n' "$env_file"
}

configure_alias_autoload_for_selected_stack() {
    local alias_script

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao automatica de aliases globais."
        return 0
    fi

    alias_script="$(stack_alias_script "$SERVER_TYPE")"
    if [ ! -f "$alias_script" ]; then
        print_warning "Arquivo de aliases nao encontrado para autoload: $alias_script"
        return 0
    fi

    ensure_alias_autoload_entry "$alias_script"
}

run_selected_stack_installer() {
    local env_file
    local target_script
    local entry_function
    local exit_code

    env_file="$(write_stack_env_file)"

    if [ "$SERVER_TYPE" = "minecraft" ]; then
        target_script="$SCRIPT_DIR/minecraft/install.sh"
        entry_function="run_minecraft_install"
    else
        target_script="$SCRIPT_DIR/terraria/install.sh"
        entry_function="run_terraria_install"
    fi

    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$env_file"
        rm -f "$env_file"
        # shellcheck disable=SC1090
        source "$target_script"
        "$entry_function"
    )

    exit_code=$?
    rm -f "$env_file"
    return "$exit_code"
}

cleanup_stack_by_type() {
    local stack_type="$1"
    local service_name
    local stack_dir

    if [ "$stack_type" = "minecraft" ]; then
        service_name="minecraft"
        stack_dir="$MINECRAFT_SERVER_DIR"
    else
        service_name="terraria"
        stack_dir="$TERRARIA_SERVER_DIR"
    fi

    print_step "Desativando stack $stack_type..."

    if is_true "$DRY_RUN"; then
        print_warning "[DRY_RUN] Desativacao real pulada para stack $stack_type."
        return 0
    fi

    # Use grep -F (literal) to avoid regex injection.
    if systemctl list-unit-files | grep -Fq "${service_name}.service"; then
        systemctl stop "$service_name" >/dev/null 2>&1 || true
        systemctl disable "$service_name" >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    # Remove backup-cron entries from the service user crontab (if present)
    local server_user_var
    if [ "$stack_type" = "minecraft" ]; then
        server_user_var="$MINECRAFT_USER"
    else
        server_user_var="$TERRARIA_USER"
    fi

    # If user-specific crontab exists and contains the backup script, remove it.
    if command -v crontab >/dev/null 2>&1; then
        if crontab -u "$server_user_var" -l 2>/dev/null | grep -Fq "$stack_dir/backup-cron.sh"; then
            local tmp_cron_file
            tmp_cron_file="$(mktemp_crias_file)"
            local original_count
            original_count=$(crontab -u "$server_user_var" -l 2>/dev/null | wc -l)
            crontab -u "$server_user_var" -l 2>/dev/null | grep -Fv "$stack_dir/backup-cron.sh" > "$tmp_cron_file" || true
            if [ -s "$tmp_cron_file" ]; then
                crontab -u "$server_user_var" "$tmp_cron_file" >/dev/null 2>&1 || true
            elif [ "$original_count" -le 1 ]; then
                crontab -u "$server_user_var" -r >/dev/null 2>&1 || true
            else
                crontab -u "$server_user_var" "$tmp_cron_file" >/dev/null 2>&1 || true
            fi
            rm -f "$tmp_cron_file"
        fi

        # Also attempt to remove from root crontab if present
        if crontab -l 2>/dev/null | grep -Fq "$stack_dir/backup-cron.sh"; then
            local tmp_cron_root_file
            tmp_cron_root_file="$(mktemp_crias_file)"
            local original_count_root
            original_count_root=$(crontab -l 2>/dev/null | wc -l)
            crontab -l 2>/dev/null | grep -Fv "$stack_dir/backup-cron.sh" > "$tmp_cron_root_file" || true
            if [ -s "$tmp_cron_root_file" ]; then
                crontab "$tmp_cron_root_file" >/dev/null 2>&1 || true
            elif [ "$original_count_root" -le 1 ]; then
                crontab -r >/dev/null 2>&1 || true
            else
                crontab "$tmp_cron_root_file" >/dev/null 2>&1 || true
            fi
            rm -f "$tmp_cron_root_file"
        fi
    fi

    remove_alias_autoload_entry "$stack_dir/comandos.sh"

    print_success "Stack $stack_type desativado sem remover dados."
}

cleanup_other_stack_if_needed() {
    local other_stack
    local other_dir
    local has_existing_data=false

    if ! is_true "$CLEANUP_OTHER_STACK"; then
        print_warning "Cleanup do stack oposto desativado."
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_warning "[DRY_RUN] Cleanup do stack oposto pulado."
        return 0
    fi

    if [ "$SERVER_TYPE" = "minecraft" ]; then
        other_stack="terraria"
        other_dir="$TERRARIA_SERVER_DIR"
    else
        other_stack="minecraft"
        other_dir="$MINECRAFT_SERVER_DIR"
    fi

    if [ -d "$other_dir" ]; then
        has_existing_data=true
    fi

    # Use grep -F (literal).
    if systemctl list-unit-files | grep -Fq "${other_stack}.service"; then
        has_existing_data=true
    fi

    if [ "$has_existing_data" = true ]; then
        print_warning "Foi detectado stack existente de $other_stack no host."
        print_warning "Essa limpeza preserva dados e apenas desativa o servico do stack oposto: $other_dir"

        if ! tui_confirm "CONFIRMAR DESATIVACAO DO STACK $other_stack?" "N"; then
            print_warning "Desativacao do stack oposto foi cancelada pelo usuario."
            return 0
        fi

        cleanup_stack_by_type "$other_stack"
    fi
}

# ---------------------------------------------------------------------------
# SSH setup (v1.2.0). Pergunta interativamente se INSTALL_SSH estiver vazio.
# Se sim: instala openssh no host, habilita sshd, cria usuario 'crias' com
# sudo (senha pedida), configura PermitRootLogin no. No live ISO o sshd NAO
# sobe sozinho — este passo configura apenas o host instalado.
# ---------------------------------------------------------------------------
install_ssh_if_enabled() {
    local ssh_user="crias"

    # Resolve config interativa se INSTALL_SSH estiver vazio.
    if [ -z "$INSTALL_SSH" ]; then
        if is_true "$NON_INTERACTIVE"; then
            INSTALL_SSH="false"
        else
            if tui_confirm "Habilitar acesso SSH no servidor instalado? (cria usuario 'crias' com sudo)" "N"; then
                INSTALL_SSH="true"
            else
                INSTALL_SSH="false"
            fi
        fi
    fi

    if ! is_true "$INSTALL_SSH"; then
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando configuracao de SSH."
        return 0
    fi

    print_step "Configurando acesso SSH..."

    # 1. Instala openssh (se nao presente).
    if ! command -v sshd >/dev/null 2>&1; then
        print_step "Instalando openssh via pacman..."
        if ! pacman -S --needed --noconfirm openssh >/dev/null 2>&1; then
            print_error "Falha ao instalar openssh via pacman."
            print_error "Configure SSH manualmente apos a instalacao."
            return 1
        fi
    else
        print_step "openssh ja instalado."
    fi

    # 2. Cria usuario 'crias' com sudo (se nao existir).
    if ! id "$ssh_user" >/dev/null 2>&1; then
        print_step "Criando usuario '$ssh_user' com sudo..."

        # Pede a senha de forma interativa (nao-echo). Em NON_INTERACTIVE
        # isso nao roda (INSTALL_SSH ja foi forçado false acima), mas defendemos.
        if ! is_true "$NON_INTERACTIVE"; then
            local ssh_pass ssh_pass_confirm
            while true; do
                # Le senha sem echo. read -s nao imprime caracteres.
                print_prompt "Defina a senha do usuario '$ssh_user' (para SSH + sudo)"
                read -r -s -p "$(printf '%b' "${CYAN}  ➜ senha: ${NC}")" ssh_pass
                echo ""
                read -r -s -p "$(printf '%b' "${CYAN}  ➜ confirme a senha: ${NC}")" ssh_pass_confirm
                echo ""
                if [ -z "$ssh_pass" ]; then
                    print_error "Senha nao pode ser vazia."
                    continue
                fi
                if [ "$ssh_pass" != "$ssh_pass_confirm" ]; then
                    print_error "As senhas nao coincidem. Tente novamente."
                    continue
                fi
                break
            done

            # Cria o usuario com home e shell bash.
            useradd -m -s /bin/bash "$ssh_user"

            # Define a senha.
            if ! printf '%s:%s\n' "$ssh_user" "$ssh_pass" | chpasswd 2>/dev/null; then
                print_error "Falha ao definir senha do usuario '$ssh_user'."
                return 1
            fi
            # Limpa a senha da memoria.
            ssh_pass=""
            ssh_pass_confirm=""
        else
            # Fallback defensivo: cria usuario com senha bloqueada (login por chave apenas).
            useradd -m -s /bin/bash "$ssh_user"
            passwd -l "$ssh_user" >/dev/null 2>&1 || true
            print_warning "Usuario '$ssh_user' criado com senha bloqueada (NON_INTERACTIVE)."
            print_warning "Configure uma chave publica em /home/$ssh_user/.ssh/authorized_keys."
        fi

        # Adiciona ao grupo wheel (sudo no Arch).
        usermod -aG wheel "$ssh_user" 2>/dev/null || true
    else
        print_step "Usuario '$ssh_user' ja existe."
    fi

    # 3. Garante que sudoers permite wheel (sem senha NAO — exige senha).
    local sudoers_file="/etc/sudoers.d/crias-wheel"
    if [ ! -f "$sudoers_file" ]; then
        printf '%%wheel ALL=(ALL) ALL\n' > "$sudoers_file"
        chmod 0440 "$sudoers_file"
        if command -v visudo >/dev/null 2>&1; then
            if ! visudo -cf "$sudoers_file" >/dev/null 2>&1; then
                print_warning "sudoers invalido; removendo $sudoers_file"
                rm -f "$sudoers_file"
            else
                print_step "sudoers para grupo wheel criado em $sudoers_file"
            fi
        fi
    fi

    # 4. Configura sshd: drop-in para PermitRootLogin no + PasswordAuthentication yes.
    local sshd_dropin_dir="/etc/ssh/sshd_config.d"
    local sshd_dropin="$sshd_dropin_dir/10-crias.conf"
    mkdir -p "$sshd_dropin_dir"
    cat > "$sshd_dropin" << 'EOF'
# /etc/ssh/sshd_config.d/10-crias.conf
# Generated by Crias-Server installer - do not edit manually
# Hardening: root login proibido; apenas autenticacao por senha (usuario crias).
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
    chmod 0644 "$sshd_dropin"
    print_step "Drop-in sshd_config criado em $sshd_dropin (PermitRootLogin no)"

    # 5. Habilita e (re)inicia sshd.
    if ! systemctl enable sshd >/dev/null 2>&1; then
        print_error "Falha ao habilitar sshd.service."
        return 1
    fi
    if ! systemctl restart sshd >/dev/null 2>&1; then
        print_error "Falha ao (re)iniciar sshd.service."
        print_error "Verifique: journalctl -u sshd"
        return 1
    fi

    print_success "SSH habilitado: usuario '$ssh_user' (grupo wheel), PermitRootLogin no."
    print_step "Conecte via: ssh $ssh_user@<ip-do-servidor>"
    if [ -f /etc/hostname ]; then
        local host
        host=$(cat /etc/hostname 2>/dev/null || echo "servidor")
        print_step "Hostname: $host"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Monitoring tools install. Pergunta se instala btop + ncdu no
# host instalado. Pré-instalados na ISO (para uso no live), mas o host
# instalado (pós-archinstall) não os tem — esta função as instala para que
# o subcomando `monitor` dos managers funcione pós-reboot.
# ---------------------------------------------------------------------------
install_monitor_tools_if_enabled() {
    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalação de ferramentas de monitoramento."
        return 0
    fi

    if ! is_true "${INSTALL_MONITOR_TOOLS:-}"; then
        if is_true "$NON_INTERACTIVE"; then
            return 0
        fi
        if ! tui_confirm "Instalar ferramentas de monitoramento (btop, ncdu) no host?" "N"; then
            print_step "Ferramentas de monitoramento não instaladas (use 'pacman -S btop ncdu' depois se precisar)."
            return 0
        fi
    fi

    print_step "Instalando btop + ncdu..."
    if ! pacman -S --needed --noconfirm btop ncdu >/dev/null 2>&1; then
        print_warning "Falha ao instalar btop/ncdu via pacman."
        print_warning "Instale manualmente: sudo pacman -S btop ncdu"
        return 1
    fi
    print_success "Ferramentas de monitoramento instaladas: btop, ncdu"
    local manager_name="mc-manager.sh"
    local stack_prefix="minecraft"
    if [ "$SERVER_TYPE" = "terraria" ]; then
        manager_name="tt-manager.sh"
        stack_prefix="terraria"
    fi
    print_step "Subcomando disponível: sudo /opt/${stack_prefix}-server/${manager_name} monitor [cpu|disk|net]"
    return 0
}

# ---------------------------------------------------------------------------
# Optional remote control agent install. Runs after stack install to read
# RCON config from server.properties / serverconfig.txt.
# ---------------------------------------------------------------------------
install_crias_agent_if_enabled() {
    local stack_dir
    local stack_user
    local service_name
    local stack_type_for_agent

    # Resolve config interativa se INSTALL_AGENT estiver vazio.
    if [ -z "$INSTALL_AGENT" ]; then
        if is_true "$NON_INTERACTIVE"; then
            INSTALL_AGENT="false"
        else
            if tui_confirm "Instalar agente de controle remoto (crias-agent)?" "N"; then
                INSTALL_AGENT="true"
            else
                INSTALL_AGENT="false"
            fi
        fi
    fi

    if ! is_true "$INSTALL_AGENT"; then
        return 0
    fi

    if is_true "$DRY_RUN"; then
        print_step "[DRY_RUN] Pulando instalacao do crias-agent."
        return 0
    fi

    print_step "Instalando agente de controle remoto (crias-agent)..."

    # Determina stack alvo.
    local stack_dir
    local stack_user
    local service_name
    local stack_type_for_agent
    local stack_port
    local manager_script_name
    if [ "$SERVER_TYPE" = "minecraft" ]; then
        stack_dir="$MINECRAFT_SERVER_DIR"
        stack_user="$MINECRAFT_USER"
        service_name="minecraft"
        stack_type_for_agent="minecraft"
        stack_port="$MINECRAFT_PORT"
        manager_script_name="mc-manager.sh"
    else
        stack_dir="$TERRARIA_SERVER_DIR"
        stack_user="$TERRARIA_USER"
        service_name="terraria"
        stack_type_for_agent="terraria"
        stack_port="$TERRARIA_PORT"
        manager_script_name="tt-manager.sh"
    fi

    # Effective hardware tier for agent.yaml.
    local agent_hardware_tier="${FORCE_HARDWARE_TIER:-}"
    if [ -z "$agent_hardware_tier" ] && [ -f "$stack_dir/.hardware-tier" ]; then
        agent_hardware_tier="$(cat "$stack_dir/.hardware-tier" 2>/dev/null || true)"
    fi
    if [ -z "$agent_hardware_tier" ]; then
        agent_hardware_tier="unknown"
    fi

    # 1. Cria usuário crias-agent.
    if ! id "crias-agent" >/dev/null 2>&1; then
        useradd -r -M -s /usr/bin/nologin -d /opt/crias-agent "crias-agent"
    fi

    # 2. Cria diretório de instalação.
    mkdir -p /opt/crias-agent /etc/crias /var/log/crias-agent
    chown -R crias-agent:crias-agent /opt/crias-agent /var/log/crias-agent

    # Validate inputs before generating config/sudoers.
    if ! [[ "$stack_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "stack_user inválido para sudoers: $stack_user (use apenas [a-z0-9_-])"
        return 1
    fi
    if ! [[ "$service_name" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_error "service_name inválido para sudoers: $service_name"
        return 1
    fi
    if ! [[ "$stack_dir" =~ ^/[a-zA-Z0-9/_.-]+$ ]]; then
        print_error "stack_dir inválido para sudoers (caracteres não permitidos): $stack_dir"
        return 1
    fi

    # 3. Find latest release asset via GitHub API.
    local agent_url
    local api_url="https://api.github.com/repos/ViniciusLopes7/Crias-Server/releases?per_page=10"
    local curl_auth_headers=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_auth_headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    local api_response
    api_response=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 60 \
        "${curl_auth_headers[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url" 2>/dev/null || true)

    agent_url=$(printf '%s' "$api_response" \
        | jq -r '[.[] | .assets[] | select(.name=="crias-agent-linux-amd64") | .browser_download_url] | .[0] // empty' 2>/dev/null || true)

    if [ -z "$agent_url" ]; then
        print_error "Não foi possível encontrar o asset crias-agent-linux-amd64 em nenhuma release do GitHub."
        print_error "URL da API consultada: $api_url"
        print_error "Verifique se há releases publicadas em:"
        print_error "  https://github.com/ViniciusLopes7/Crias-Server/releases"
        print_warning "Voce pode instalar manualmente depois: ver discord-agent/README.md"
        return 1
    fi

    print_step "URL do agente: $agent_url"

    local agent_tmp_dir
    agent_tmp_dir="$(mktemp_crias_dir)"
    local agent_local="${agent_tmp_dir}/crias-agent"

    if ! _curl_with_retry "$agent_url" "$agent_local"; then
        print_error "Falha ao baixar crias-agent de $agent_url"
        print_warning "Voce pode instalar manualmente depois: ver discord-agent/README.md"
        return 1
    fi

    install -m 755 -o root -g root "$agent_local" /opt/crias-agent/crias-agent

    # 4. Gera token aleatório (32 bytes hex = 64 chars).
    local agent_token
    agent_token="$(generate_token 32)"
    if [ -z "$agent_token" ] || [ "${#agent_token}" -ne 64 ]; then
        print_error "Falha ao gerar token aleatorio para o agente."
        return 1
    fi

    # 5. Lê RCON config (apenas Minecraft tem server.properties).
    local rcon_enabled="false"
    local rcon_host="127.0.0.1"
    local rcon_port="25575"
    local rcon_password=""

    if [ "$stack_type_for_agent" = "minecraft" ]; then
        local props_file="$stack_dir/server.properties"
        if [ -f "$props_file" ]; then
            local rcon_enabled_raw
            rcon_enabled_raw="$(config_read_value "$props_file" "enable-rcon")"
            if [ "$rcon_enabled_raw" = "true" ]; then
                rcon_enabled="true"
            fi
            rcon_port="$(config_read_value "$props_file" "rcon.port")"
            rcon_port="${rcon_port:-25575}"
            rcon_password="$(config_read_value "$props_file" "rcon.password")"
        fi
    fi

    # Validate rcon_password for YAML safety (no newlines/quotes/backslash).
    if [ -n "$rcon_password" ]; then
        if [[ "$rcon_password" == *$'\n'* ]] || [[ "$rcon_password" == *'"'* ]] || \
           [[ "$rcon_password" == *"'"* ]] || [[ "$rcon_password" == *'\'* ]]; then
            print_error "rcon.password em server.properties contém caracteres invalidos para YAML (newline, aspas ou backslash)."
            print_error "Altere a senha do RCON no servidor antes de instalar o agente."
            return 1
        fi
    fi

    # Validate port range before emitting YAML.
    if ! [[ "$stack_port" =~ ^[0-9]+$ ]] || [ "$stack_port" -lt 1 ] || [ "$stack_port" -gt 65535 ]; then
        print_error "stack_port inválido para YAML: $stack_port (deve ser 1-65535)"
        return 1
    fi
    if ! [[ "$rcon_port" =~ ^[0-9]+$ ]] || [ "$rcon_port" -lt 1 ] || [ "$rcon_port" -gt 65535 ]; then
        print_error "rcon_port inválido para YAML: $rcon_port (deve ser 1-65535)"
        return 1
    fi

    # Validate hardware tier against whitelist.
    case "$agent_hardware_tier" in
        LOW|MID|HIGH|unknown)
            ;;
        *)
            print_error "agent_hardware_tier inválido para YAML: $agent_hardware_tier (esperado LOW/MID/HIGH/unknown)"
            return 1
            ;;
    esac

    # 6. Write agent.yaml atomically.
    local agent_yaml_tmp
    agent_yaml_tmp="$(mktemp_crias_file)"

    cat > "$agent_yaml_tmp" << EOF
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "$agent_token"

server:
  stack: "$stack_type_for_agent"
  service_name: "$service_name"
  manager_script: "$stack_dir/$manager_script_name"
  server_dir: "$stack_dir"
  server_port: "$stack_port"
  hardware_tier: "$agent_hardware_tier"
  rcon:
    enabled: $rcon_enabled
    host: "$rcon_host"
    port: "$rcon_port"
    password: "$rcon_password"

features:
  auto_shutdown:
    enabled: false
    empty_minutes: 30
  health_check:
    interval_seconds: 300
    passive: true
EOF
    # Atomic install with mode 0640.
    install -m 0640 -o root -g crias-agent "$agent_yaml_tmp" /etc/crias/agent.yaml
    rm -f "$agent_yaml_tmp"

    # 7. Write sudoers with explicit subcommands (least privilege).
    # Validate with visudo -cf before installing.
    local sudoers_tmp
    sudoers_tmp="$(mktemp_crias_file)"

    cat > "$sudoers_tmp" << EOF
# /etc/sudoers.d/crias-agent
# Generated by Crias-Server installer - do not edit manually
crias-agent ALL=(root) NOPASSWD: /usr/bin/systemctl start $service_name, /usr/bin/systemctl stop $service_name, /usr/bin/systemctl restart $service_name, /usr/bin/systemctl status $service_name, /usr/bin/systemctl is-active $service_name
crias-agent ALL=($stack_user) NOPASSWD: $stack_dir/backup-cron.sh, $stack_dir/$manager_script_name start, $stack_dir/$manager_script_name stop, $stack_dir/$manager_script_name restart, $stack_dir/$manager_script_name status, $stack_dir/$manager_script_name backup, $stack_dir/$manager_script_name health, $stack_dir/$manager_script_name hardware-report
EOF

    # Validate sudoers before install.
    if command -v visudo >/dev/null 2>&1; then
        if ! visudo -cf "$sudoers_tmp" >/dev/null 2>&1; then
            print_error "Sintaxe sudoers inválida; arquivo NÃO foi instalado em /etc/sudoers.d/."
            rm -f "$sudoers_tmp"
            return 1
        fi
    else
        print_warning "visudo não disponível; sudoers não validado. Verifique manualmente após install: cat /etc/sudoers.d/crias-agent"
    fi
    install -m 0440 -o root -g root "$sudoers_tmp" /etc/sudoers.d/crias-agent
    rm -f "$sudoers_tmp"

    # 8. Write and verify systemd unit atomically.
    local unit_tmp
    unit_tmp="$(mktemp_crias_file)"

    cat > "$unit_tmp" << 'EOF'
[Unit]
Description=Crias Agent - Remote control bridge
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
User=crias-agent
Group=crias-agent
WorkingDirectory=/opt/crias-agent
ExecStart=/opt/crias-agent/crias-agent
Restart=on-failure
RestartSec=5

MemoryMax=128M
CPUQuota=10%
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/crias-agent /var/log/crias-agent
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
RemoveIPC=yes
LockPersonality=yes
# Go binary is AOT-compiled: MemoryDenyWriteExecute is safe.
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallArchitectures=native
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
    # Optionally validate with systemd-analyze.
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze verify "$unit_tmp" >/dev/null 2>&1; then
            print_warning "systemd-analyze verify reportou problemas no unit file; verifique $unit_tmp"
            # Don't abort on benign warnings.
        fi
    fi
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/crias-agent.service
    rm -f "$unit_tmp"

    systemctl daemon-reload
    systemctl enable crias-agent >/dev/null 2>&1 || true
    systemctl restart crias-agent >/dev/null 2>&1 || print_warning "crias-agent nao iniciou imediatamente; verifique /var/log/crias-agent/"

    # 9. Final instructions (token not printed).
    print_success "crias-agent instalado em /opt/crias-agent/crias-agent"
    print_success "Token de autenticacao gerado em /etc/crias/agent.yaml (chmod 0640)"
    print_step "Para visualizar o token (protected file):"
    print_step "  sudo grep auth_token /etc/crias/agent.yaml"
    print_step "Configure no Railway (bot Discord):"
    print_step "  CRIAS_AGENT_HOST=https://<seu-tailnet>.ts.net"
    print_step "  CRIAS_AGENT_TOKEN=<copie do agent.yaml>"
    print_step "Ative o Tailscale Funnel apos 'sudo tailscale up':"
    print_step "  sudo tailscale funnel 8473"
    print_warning "NAO commitar /etc/crias/agent.yaml nem exportar o token em logs de CI."
}

main() {
    print_header
    # Config already loaded at top-level.

    # ERR trap for diagnostics in both modes.
    trap 'echo "[install.sh] erro (exit=$?) em DRY_RUN=${DRY_RUN:-false}" >&2; echo "Funcao: ${FUNCNAME[1]:-unknown}, Linha: ${BASH_LINENO[0]}" >&2; echo "Arquivo: ${BASH_SOURCE[1]:-unknown}" >&2' ERR

    if is_true "$DRY_RUN"; then
        print_warning "Modo DRY_RUN ativo: nenhuma alteracao destrutiva no host sera aplicada."
        # Keep fail-fast enabled even in DRY_RUN to catch logic errors without exposing secrets.
    else
        check_root
        check_arch
    fi

    select_server_type

    print_step "Stack selecionado: $SERVER_TYPE"

    prompt_global_options

    if [ "$SERVER_TYPE" = "minecraft" ]; then
        prompt_minecraft_options
    else
        prompt_terraria_options
    fi

    install_tailscale_if_enabled
    # Policy gate: ensure EULA acceptance for non-interactive Minecraft installs
    if [ "$SERVER_TYPE" = "minecraft" ] && is_true "${NON_INTERACTIVE:-false}"; then
        if ! is_true "${ACCEPT_EULA:-false}"; then
            print_error "ACCEPT_EULA must be set to true in non-interactive mode to accept Mojang EULA. Aborting."
            exit 1
        fi
    fi

    if ! run_selected_stack_installer; then
        exit 1
    fi
    configure_alias_autoload_for_selected_stack
    cleanup_other_stack_if_needed

    # v1.2.0: configura SSH no host instalado (pergunta interativamente).
    install_ssh_if_enabled

    # Fase 1+: instala agente de controle remoto (opcional, pergunta interativo).
    install_crias_agent_if_enabled

    # Install monitoring tools (btop, ncdu) on the host.
    install_monitor_tools_if_enabled

    print_success "Instalacao concluida para stack: $SERVER_TYPE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
