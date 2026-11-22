#!/usr/bin/env bash
# Atualizador de ferramentas Crias-Server SEM reinstalar Minecraft/Terraria.
# Fonte da release: GitHub oficial + SHA256, reaproveitando o bootstrap.
set -euo pipefail

UPDATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$UPDATE_SCRIPT_DIR/crias-bootstrap.sh"

# Nao permitir que variaveis de shell redirecionem o updater para outro repo.
CRIAS_REPO="ViniciusLopes7/Crias-Server"
CRIAS_ASSET_ZIP="crias-server-slim.zip"
CRIAS_ASSET_SHA="sha256sums.txt"

CRIAS_UPDATE_INSTALL_DIR="${CRIAS_UPDATE_INSTALL_DIR:-/opt/crias-server}"
CRIAS_UPDATE_LIBEXEC_DIR="${CRIAS_UPDATE_LIBEXEC_DIR:-/usr/local/libexec/crias}"
CRIAS_UPDATE_BIN_DIR="${CRIAS_UPDATE_BIN_DIR:-/usr/local/bin}"
CRIAS_UPDATE_LOCK="${CRIAS_UPDATE_LOCK:-/run/lock/crias-update.lock}"

update_fail() { err "$*"; return 1; }

update_root_required() {
    if [ "$(id -u)" -ne 0 ]; then
        update_fail "Atualizacao requer root: sudo crias-update apply"
        return 1
    fi
}

update_fetch_release() {
    command -v curl >/dev/null 2>&1 || { update_fail "curl indisponivel"; return 1; }
    command -v jq >/dev/null 2>&1 || { update_fail "jq indisponivel"; return 1; }
    if ! crias_fetch_release_urls; then return 1; fi
    case "${CRIAS_RELEASE_TAG_NAME:-}" in
        v[0-9A-Za-z._-]*) ;;
        *) update_fail "Tag de release inesperada; abortando."; return 1 ;;
    esac
    # Nao aceitar assets arbitrarios, mesmo que um JSON inesperado seja lido.
    case "$CRIAS_ZIP_URL" in
        "https://github.com/$CRIAS_REPO/releases/download/$CRIAS_RELEASE_TAG_NAME/$CRIAS_ASSET_ZIP") ;;
        *) update_fail "URL do pacote nao pertence a release oficial."; return 1 ;;
    esac
    case "$CRIAS_SHA_URL" in
        "https://github.com/$CRIAS_REPO/releases/download/$CRIAS_RELEASE_TAG_NAME/$CRIAS_ASSET_SHA") ;;
        *) update_fail "URL de checksums nao pertence a release oficial."; return 1 ;;
    esac
}

update_local_tag() {
    local file="$CRIAS_UPDATE_INSTALL_DIR/.crias-release-tag"
    if [ -r "$file" ] && [ ! -L "$file" ]; then
        head -n1 "$file" | tr -cd 'a-zA-Z0-9._-'
    else
        printf 'nao-identificada'
    fi
}

update_check() {
    update_fetch_release || return 1
    local installed
    installed="$(update_local_tag)"
    printf '\nCrias-Server: versao local %s\n' "$installed"
    printf 'Release oficial mais recente: %s\n' "$CRIAS_RELEASE_TAG_NAME"
    printf 'Pagina: https://github.com/%s/releases/tag/%s\n' "$CRIAS_REPO" "$CRIAS_RELEASE_TAG_NAME"
    if [ "$installed" = "$CRIAS_RELEASE_TAG_NAME" ]; then
        ok "Ferramentas Crias-Server ja estao nesta release."
    else
        warn "Para aplicar SOMENTE Hub e scripts administrativos: sudo crias-update apply"
    fi
    echo "Minecraft, Terraria, mundo, modpack, systemd e RAM nao sao alterados."
}

# Overridable only when sourced by tests; production calls HTTPS strict.
update_download() {
    local url="$1" output="$2"
    curl --fail --show-error --silent --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 2 \
        --output "$output" "$url"
}

update_preflight() {
    local archive="$1" stage="$2"
    local entry dir file
    # Reject absolute paths and traversal BEFORE extraction as root.
    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in
            /*|../*|*/../*|*/..|..|*\\*) update_fail "Caminho perigoso no ZIP"; return 1 ;;
        esac
    done < <(unzip -Z -1 "$archive")
    if ! unzip -q "$archive" -d "$stage"; then
        update_fail "Falha ao extrair arquivo de release"
        return 1
    fi
    dir="$stage"
    if [ ! -f "$dir/install.sh" ]; then
        dir="$(find "$stage" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/install.sh' \; -print -quit)"
    fi
    [ -n "$dir" ] && [ -f "$dir/install.sh" ] || { update_fail "Release sem install.sh"; return 1; }
    # Disallow symlinks in distributed scripts and nested files.
    if [ -n "$(find "$dir" -type l -print -quit)" ]; then
        update_fail "Release contem symlinks; abortando atualizacao de root"
        return 1
    fi
    for file in \
        install.sh crias-bootstrap.sh crias-tui.sh crias-update.sh \
        minecraft/mc-manager.sh minecraft/setup-cron.sh \
        minecraft/install-mcrcon.sh minecraft/voicechat-tools.sh \
        terraria/tt-manager.sh terraria/setup-cron.sh \
        shared/lib/common.sh shared/lib/manager-common.sh \
        shared/lib/setup-cron.sh; do
        if [ ! -s "$dir/$file" ]; then
            update_fail "Release sem arquivo obrigatorio: $file"
            return 1
        fi
        if ! bash -n "$dir/$file"; then
            update_fail "Shell invalido: $file"
            return 1
        fi
    done
    while IFS= read -r -d '' file; do
        if ! bash -n "$file"; then
            update_fail "Biblioteca shell invalida no release: $file"
            return 1
        fi
    done < <(find "$dir/shared/lib" -maxdepth 1 -type f -name '*.sh' -print0)
}

# Rollback de cada arquivo administrativo, inclusive os que nao existiam.
UPDATE_DESTS=()
UPDATE_SNAPSHOTS=()
UPDATE_OLD_REF=""
UPDATE_PUBLISHED=0
UPDATE_COMMITTED=0
UPDATE_TEMP=""

update_track_install() {
    local src="$1" dest="$2" mode="$3"
    local n="${#UPDATE_DESTS[@]}" backup="$UPDATE_TEMP/backup-$n"
    mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        cp -a -- "$dest" "$backup"
        UPDATE_SNAPSHOTS+=("$backup")
    else
        UPDATE_SNAPSHOTS+=("")
    fi
    UPDATE_DESTS+=("$dest")
    # Same-directory staging + atomic rename. A failed copy leaves old intact.
    local stage_dest="$dest.crias-update.$$"
    rm -f -- "$stage_dest"
    if ! install -o root -g root -m "$mode" -- "$src" "$stage_dest"; then
        rm -f -- "$stage_dest"
        return 1
    fi
    if ! mv -f -T -- "$stage_dest" "$dest"; then
        rm -f -- "$stage_dest"
        return 1
    fi
}

update_recover() {
    local i dest backup link
    if [ "$UPDATE_COMMITTED" -eq 0 ] && [ "${#UPDATE_DESTS[@]}" -gt 0 ]; then
        for ((i=${#UPDATE_DESTS[@]}-1; i>=0; i--)); do
            dest="${UPDATE_DESTS[$i]}"
            backup="${UPDATE_SNAPSHOTS[$i]}"
            if [ -n "$backup" ] && [ -e "$backup" ]; then
                cp -a -- "$backup" "$dest" || true
            else
                rm -f -- "$dest" || true
            fi
        done
    fi
    if [ "$UPDATE_COMMITTED" -eq 0 ] && [ "$UPDATE_PUBLISHED" -eq 1 ] && [ -n "$UPDATE_OLD_REF" ]; then
        link="$CRIAS_UPDATE_INSTALL_DIR.releases/.crias-restore.$$"
        if ln -s -- "$UPDATE_OLD_REF" "$link"; then
            mv -f -T -- "$link" "$CRIAS_UPDATE_INSTALL_DIR" || true
        fi
    fi
    if [ -n "$UPDATE_TEMP" ] && [ -d "$UPDATE_TEMP" ]; then
        rm -rf -- "$UPDATE_TEMP"
    fi
}

update_deploy_admin() {
    local dest file src cron
    update_track_install "$CRIAS_UPDATE_INSTALL_DIR/crias-tui.sh" "$CRIAS_UPDATE_BIN_DIR/crias-tui" 0755
    update_track_install "$CRIAS_UPDATE_INSTALL_DIR/crias-update.sh" "$CRIAS_UPDATE_BIN_DIR/crias-update" 0755
    for src in "$CRIAS_UPDATE_INSTALL_DIR/shared/lib/"*.sh; do
        [ -f "$src" ] || continue
        update_track_install "$src" "$CRIAS_UPDATE_LIBEXEC_DIR/lib/$(basename "$src")" 0644
    done
    # Both managers are harmless when not installed; only the selected
    # stack's setup-cron wrapper must share the common name.
    for file in minecraft/mc-manager.sh minecraft/install-mcrcon.sh minecraft/voicechat-tools.sh terraria/tt-manager.sh; do
        update_track_install "$CRIAS_UPDATE_INSTALL_DIR/$file" "$CRIAS_UPDATE_LIBEXEC_DIR/$(basename "$file")" 0755
    done
    cron="minecraft/setup-cron.sh"
    if [ -e /etc/systemd/system/terraria.service ] && [ ! -e /etc/systemd/system/minecraft.service ]; then
        cron="terraria/setup-cron.sh"
    fi
    update_track_install "$CRIAS_UPDATE_INSTALL_DIR/$cron" "$CRIAS_UPDATE_LIBEXEC_DIR/setup-cron.sh" 0755
}

update_apply() {
    update_root_required || return 1
    [ -L "$CRIAS_UPDATE_INSTALL_DIR" ] || {
        update_fail "Atualizacao segura requer /opt/crias-server como link versionado do bootstrap. Nenhum arquivo foi alterado."
        return 1
    }
    local releases_root="$CRIAS_UPDATE_INSTALL_DIR.releases"
    local current
    current="$(readlink -f "$CRIAS_UPDATE_INSTALL_DIR")" || return 1
    case "$current" in
        "$releases_root"/release.*|"$releases_root"/legacy.*) ;;
        *) update_fail "Instalacao nao gerenciada em $releases_root; abortando."; return 1 ;;
    esac
    if [ ! -f "$current/install.sh" ]; then
        update_fail "Instalacao atual invalida"
        return 1
    fi
    if [ ! -d "$releases_root" ]; then update_fail "Repositorio de releases ausente"; return 1; fi
    if ! command -v flock >/dev/null 2>&1; then update_fail "flock indisponivel"; return 1; fi
    mkdir -p "$(dirname "$CRIAS_UPDATE_LOCK")"
    exec 9>"$CRIAS_UPDATE_LOCK"
    if ! flock -n 9; then update_fail "Outra atualizacao esta em andamento"; return 1; fi

    update_fetch_release || return 1
    if [ "$(update_local_tag)" = "$CRIAS_RELEASE_TAG_NAME" ]; then
        ok "Versao $CRIAS_RELEASE_TAG_NAME ja instalada. Sem alteracoes."
        return 0
    fi

    UPDATE_TEMP="$(mktemp -d /tmp/crias-update.XXXXXXXX)" || return 1
    chmod 0700 "$UPDATE_TEMP"
    UPDATE_OLD_REF="$current"
    trap update_recover EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    log "Baixando a release $CRIAS_RELEASE_TAG_NAME, sem tocar no jogo..."
    update_download "$CRIAS_ZIP_URL" "$UPDATE_TEMP/release.zip"
    update_download "$CRIAS_SHA_URL" "$UPDATE_TEMP/sha256sums.txt"
    crias_verify_sha256 "$UPDATE_TEMP/release.zip" "$UPDATE_TEMP/sha256sums.txt" "$CRIAS_ASSET_ZIP"
    mkdir -p "$UPDATE_TEMP/check"
    update_preflight "$UPDATE_TEMP/release.zip" "$UPDATE_TEMP/check" || return 1

    # Preserve user-specific installer defaults, never execute/shell-source it.
    if [ -L "$current/config.env" ]; then
        update_fail "config.env e symlink; alteracao manual obrigatoria"
        return 1
    fi
    if [ -f "$current/config.env" ]; then
        cp -- "$current/config.env" "$UPDATE_TEMP/old-config.env"
        chmod 0600 "$UPDATE_TEMP/old-config.env"
    fi

    # Existing bootstrap provides transactional version directories. The
    # game dir (/opt/minecraft-server) is never passed to this function.
    crias_extract_to "$UPDATE_TEMP/release.zip" "$CRIAS_UPDATE_INSTALL_DIR"
    UPDATE_PUBLISHED=1
    local newref
    newref="$(readlink -f "$CRIAS_UPDATE_INSTALL_DIR")"
    case "$newref" in
        "$releases_root"/release.*) ;;
        *) update_fail "Novo destino de release invalido"; return 1 ;;
    esac
    if [ -f "$UPDATE_TEMP/old-config.env" ]; then
        install -o root -g root -m 0600 "$UPDATE_TEMP/old-config.env" "$newref/config.env"
    fi
    printf '%s\n' "$CRIAS_RELEASE_TAG_NAME" > "$newref/.crias-release-tag"
    chmod 0644 "$newref/.crias-release-tag"

    # Admin scripts are root-owned, outside game dirs. Any failure restores
    # old binaries/libs and the old release symlink; no game service restart.
    update_deploy_admin
    UPDATE_COMMITTED=1
    ok "Crias-Server atualizado para $CRIAS_RELEASE_TAG_NAME."
    echo "O servidor Minecraft/Terraria e seus mundos, mods, units e JVM permanecem intactos."
    echo "Nao houve reinicio do jogo. Feche/reabra o Hub para carregar o menu atualizado."
}

update_arch_check() {
    echo "=== Pacotes Arch (consulta sem alterar o host) ==="
    if command -v checkupdates >/dev/null 2>&1; then
        checkupdates || [ "$?" -eq 2 ]
    elif command -v pacman >/dev/null 2>&1; then
        echo "[AVISO] 'checkupdates' nao instalado (pacman-contrib)."
        echo "Listando apenas atualizacoes ja presentes no banco local (pode estar desatualizado):"
        pacman -Qu || true
    else
        update_fail "pacman indisponivel"; return 1
    fi
}

update_arch_apply() {
    update_root_required || return 1
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        update_fail "Atualizacao Arch exige confirmacao em terminal TTY"
        return 1
    fi
    if systemctl is-active --quiet minecraft.service || systemctl is-active --quiet terraria.service; then
        update_fail "Pare o jogo em horario de manutencao antes de atualizar o Arch. Nenhum servico foi parado."
        return 1
    fi
    echo "Atualizar pacotes do Arch pode exigir reboot. Nao altera mods/mundos."
    printf "Digite ATUALIZAR ARCH para autorizar pacman -Syu: "
    local answer
    IFS= read -r answer || return 1
    if [ "$answer" != "ATUALIZAR ARCH" ]; then
        warn "Cancelado; pacman nao foi executado."
        return 1
    fi
    pacman -Syu --noconfirm
    ok "Pacotes atualizados. Reboot fica a cargo do administrador."
}

update_main() {
    case "${1:-}" in
        check) [ "$#" -eq 1 ] || return 2; update_check ;;
        apply) [ "$#" -eq 1 ] || return 2; update_apply ;;
        arch-check) [ "$#" -eq 1 ] || return 2; update_arch_check ;;
        arch-apply) [ "$#" -eq 1 ] || return 2; update_arch_apply ;;
        *)
            echo "Uso: crias-update {check|apply|arch-check|arch-apply}" >&2
            return 2 ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    update_main "$@"
fi
