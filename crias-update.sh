#!/usr/bin/env bash
# Atualizador de ferramentas Crias-Server SEM reinstalar Minecraft/Terraria.
# Fonte da release: GitHub oficial + SHA256, reaproveitando o bootstrap.
set -euo pipefail

UPDATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# O comando de producao fica em /usr/local/bin, mas as bibliotecas e o
# bootstrap permanecem em /opt/crias-server (link versionado). No repo local,
# sourcear o caminho ao lado permite os testes sem rede.
if [ ! -f "$UPDATE_SCRIPT_DIR/crias-bootstrap.sh" ]; then
    UPDATE_SCRIPT_DIR="${CRIAS_UPDATE_INSTALL_DIR:-/opt/crias-server}"
fi
if [ ! -f "$UPDATE_SCRIPT_DIR/crias-bootstrap.sh" ]; then
    echo "[ERRO] Bootstrap nao encontrado; verifique /opt/crias-server." >&2
    exit 1
fi
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
    if ! [[ "${CRIAS_RELEASE_TAG_NAME:-}" =~ ^v[0-9A-Za-z._-]+$ ]]; then
        update_fail "Tag de release inesperada; abortando."
        return 1
    fi
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
    local listing="$stage/zip-entries.txt" metadata="$stage/zip-metadata.txt"
    # Validate listing commands themselves (process-substitution masked errors).
    if ! unzip -Z -1 "$archive" > "$listing" || ! unzip -Z -l "$archive" > "$metadata"; then
        update_fail "ZIP invalido ou nao pode ser listado; abortando"
        return 1
    fi
    # Check UNIX symlink metadata BEFORE extraction (a malicious archive could
    # otherwise write through symlinks while being expanded as root).
    if grep -qE '^l[-rwxstST]{9}[[:space:]]' "$metadata"; then
        update_fail "ZIP contem symlinks; abortando antes de extrair"
        return 1
    fi
    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in
            ""|/*|../*|*/../*|*/..|..|*\\*)
                update_fail "Caminho perigoso no ZIP: $entry"; return 1 ;;
        esac
    done < "$listing"
    # Validated paths + metadata before unpacking as root.
    if ! unzip -q "$archive" -d "$stage"; then
        update_fail "Falha ao extrair arquivo de release"
        return 1
    fi
    dir="$stage"
    if [ ! -f "$dir/install.sh" ]; then
        dir="$(find "$stage" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/install.sh' \; -print -quit)"
    fi
    [ -n "$dir" ] && [ -f "$dir/install.sh" ] || { update_fail "Release sem install.sh"; return 1; }
    if [ -n "$(find "$dir" -type l -print -quit)" ]; then
        update_fail "Release contem symlinks; abortando"
        return 1
    fi
    UPDATE_SOURCE_DIR="$dir"
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

# Journal persistente para recuperar o Hub mesmo apos SIGKILL/reboot.
UPDATE_TEMP=""
UPDATE_SOURCE_DIR=""
UPDATE_NEW_REF=""
UPDATE_PREVIOUS_REF=""
UPDATE_TXN=""
UPDATE_COMMITTED=0

update_admin_targets() {
    local ref="$1" src
    printf '%s\t%s\t%s\n' "$ref/crias-tui.sh" "$CRIAS_UPDATE_BIN_DIR/crias-tui" 0755
    printf '%s\t%s\t%s\n' "$ref/crias-update.sh" "$CRIAS_UPDATE_BIN_DIR/crias-update" 0755
    for src in "$ref/shared/lib/"*.sh; do
        [ -f "$src" ] || continue
        printf '%s\t%s\t%s\n' "$src" "$CRIAS_UPDATE_LIBEXEC_DIR/lib/$(basename "$src")" 0644
    done
    for src in minecraft/mc-manager.sh minecraft/install-mcrcon.sh minecraft/voicechat-tools.sh terraria/tt-manager.sh; do
        printf '%s\t%s\t%s\n' "$ref/$src" "$CRIAS_UPDATE_LIBEXEC_DIR/$(basename "$src")" 0755
    done
    local cron=minecraft/setup-cron.sh
    if [ -e /etc/systemd/system/terraria.service ] && [ ! -e /etc/systemd/system/minecraft.service ]; then
        cron=terraria/setup-cron.sh
    fi
    printf '%s\t%s\t%s\n' "$ref/$cron" "$CRIAS_UPDATE_LIBEXEC_DIR/setup-cron.sh" 0755
}

# Todos os snapshots sao persistidos ANTES da primeira alteracao. Journal
# incompleto (sem prepared) significa que nenhuma ferramenta foi trocada.
update_prepare_journal() {
    local previous="$1" next="$2" src dest mode exists i=0
    UPDATE_TXN="${CRIAS_UPDATE_INSTALL_DIR}.releases/.update-transaction"
    if [ -e "$UPDATE_TXN" ] || [ -L "$UPDATE_TXN" ]; then
        update_fail "Transacao anterior nao recuperada: $UPDATE_TXN"; return 1
    fi
    mkdir -m 0700 -- "$UPDATE_TXN" || return 1
    printf '%s\n' "$previous" > "$UPDATE_TXN/previous" || return 1
    printf '%s\n' "$next" > "$UPDATE_TXN/next" || return 1
    update_admin_targets "$next" > "$UPDATE_TXN/targets" || return 1
    : > "$UPDATE_TXN/manifest" || return 1
    while IFS=$'\t' read -r src dest mode; do
        [ -s "$src" ] || { update_fail "Ferramenta ausente: $src"; return 1; }
        if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
            update_fail "Destino administrativo inesperado: $dest"; return 1
        fi
        exists=0
        if [ -f "$dest" ]; then
            cp -a -- "$dest" "$UPDATE_TXN/backup.$i" || return 1
            exists=1
        fi
        printf '%s\t%s\t%s\n' "$i" "$exists" "$dest" >> "$UPDATE_TXN/manifest" || return 1
        i=$((i+1))
    done < "$UPDATE_TXN/targets"
    printf 'ready\n' > "$UPDATE_TXN/.prepared.tmp" || return 1
    mv -f -T "$UPDATE_TXN/.prepared.tmp" "$UPDATE_TXN/prepared" || return 1
}

# Idempotente; dispara antes de consultar rede em cada apply/recover.
update_recover_pending() {
    local txn="${CRIAS_UPDATE_INSTALL_DIR}.releases/.update-transaction"
    local previous next index exists dest stage path
    if [ ! -e "$txn" ] && [ ! -L "$txn" ]; then return 0; fi
    if [ -L "$txn" ] || [ ! -d "$txn" ]; then
        update_fail "Journal invalido (symlink ou nao-diretorio)"; return 1
    fi
    if [ -f "$txn/committed" ] || [ ! -f "$txn/prepared" ]; then
        rm -rf -- "$txn" || return 1
        return 0
    fi
    previous="$(cat "$txn/previous" 2>/dev/null)" || return 1
    next="$(cat "$txn/next" 2>/dev/null)" || return 1
    case "$previous" in
        "${CRIAS_UPDATE_INSTALL_DIR}.releases"/release.*|"${CRIAS_UPDATE_INSTALL_DIR}.releases"/legacy.*) ;;
        *) update_fail "Referencia de rollback fora de releases: $previous"; return 1 ;;
    esac
    case "$next" in
        "${CRIAS_UPDATE_INSTALL_DIR}.releases"/release.*) ;;
        *) update_fail "Proxima release fora do diretorio gerenciado"; return 1 ;;
    esac
    [ -d "$previous" ] || { update_fail "Release anterior ausente; recuperacao manual necessaria"; return 1; }
    [ -f "$txn/manifest" ] || { update_fail "Manifesto de recuperacao ausente"; return 1; }
    warn "Atualizacao incompleta detectada; restaurando Hub e link anterior."
    while IFS=$'\t' read -r index exists dest; do
        [ -n "$index" ] || continue
        case "$dest" in
            "$CRIAS_UPDATE_LIBEXEC_DIR"/*|"$CRIAS_UPDATE_BIN_DIR"/crias-tui|"$CRIAS_UPDATE_BIN_DIR"/crias-update) ;;
            *) update_fail "Destino inesperado no manifesto"; return 1 ;;
        esac
        if [ "$exists" = 1 ]; then
            [ -f "$txn/backup.$index" ] || { update_fail "Snapshot ausente: $index"; return 1; }
            stage="$dest.crias-restore.$$"
            cp -a -- "$txn/backup.$index" "$stage" || return 1
            mv -f -T -- "$stage" "$dest" || return 1
        elif [ "$exists" = 0 ]; then
            rm -f -- "$dest" || return 1
        else
            update_fail "Snapshot desconhecido: $exists"; return 1
        fi
    done < "$txn/manifest"
    path="${CRIAS_UPDATE_INSTALL_DIR}.releases/.crias-restore.$$"
    ln -s -- "$previous" "$path" || return 1
    mv -f -T -- "$path" "$CRIAS_UPDATE_INSTALL_DIR" || return 1
    rm -rf -- "$txn" || return 1
    ok "Ferramentas e versao anterior recuperadas; dados do jogo intactos."
}

update_track_install() {
    local src="$1" dest="$2" mode="$3"
    local tmp="$dest.crias-update.$$"
    mkdir -p "$(dirname "$dest")" || return 1
    rm -f -- "$tmp" || return 1
    if ! install -o root -g root -m "$mode" -- "$src" "$tmp"; then
        rm -f -- "$tmp"; return 1
    fi
    if ! mv -f -T -- "$tmp" "$dest"; then
        rm -f -- "$tmp"; return 1
    fi
}

update_deploy_admin() {
    local src dest mode
    while IFS=$'\t' read -r src dest mode; do
        update_track_install "$src" "$dest" "$mode" || return 1
    done < "$UPDATE_TXN/targets"
}

update_prepare_release() {
    local root="$1" src="$UPDATE_SOURCE_DIR" newref
    newref="$(mktemp -d "$root/release.XXXXXXXX")" || return 1
    UPDATE_NEW_REF="$newref"
    cp -a -- "$src/." "$newref/" || return 1
    if [ -L "$UPDATE_PREVIOUS_REF/config.env" ]; then
        update_fail "config.env e symlink; alteracao manual obrigatoria"; return 1
    fi
    if [ -f "$UPDATE_PREVIOUS_REF/config.env" ]; then
        install -o root -g root -m 0600 "$UPDATE_PREVIOUS_REF/config.env" "$newref/config.env" || return 1
    fi
    printf '%s\n' "$CRIAS_RELEASE_TAG_NAME" > "$newref/.crias-release-tag" || return 1
    chmod 0644 "$newref/.crias-release-tag" || return 1
    chmod 0755 "$newref/install.sh" || return 1
    find "$newref" -type f -name '*.sh' -exec chmod 0755 {} + || return 1
}

update_publish_release() {
    local link="${CRIAS_UPDATE_INSTALL_DIR}.releases/.crias-publish.$$"
    ln -s -- "$UPDATE_NEW_REF" "$link" || return 1
    if ! mv -f -T -- "$link" "$CRIAS_UPDATE_INSTALL_DIR"; then
        rm -f -- "$link"; return 1
    fi
}

# Cleanup only AFTER all tools have been committed. Always preserve both
# the currently installed version and its prior rollback target.
update_prune_releases() {
    local root="${CRIAS_UPDATE_INSTALL_DIR}.releases" old keep=0
    while IFS= read -r old; do
        [ -d "$old" ] || continue
        if [ "$old" = "$UPDATE_NEW_REF" ] || [ "$old" = "$UPDATE_PREVIOUS_REF" ]; then continue; fi
        keep=$((keep+1))
        if [ "$keep" -gt 1 ]; then
            rm -rf -- "$old" || warn "Nao foi possivel limpar versao historica: $old"
        fi
    done < <(ls -1dt "$root"/release.* "$root"/legacy.* 2>/dev/null || true)
}

update_abort() {
    if ! update_recover_pending; then
        err "Recuperacao incompleta. Execute: sudo crias-update recover"
    fi
    if [ -n "$UPDATE_TEMP" ] && [ -d "$UPDATE_TEMP" ]; then rm -rf -- "$UPDATE_TEMP" || true; fi
    trap - EXIT INT TERM
    return 1
}

update_exit_cleanup() {
    local rc=$?
    # SIGKILL/power loss leave a journal for next apply or recover call.
    if [ "$UPDATE_COMMITTED" -eq 0 ]; then update_recover_pending || true; fi
    if [ -n "$UPDATE_TEMP" ] && [ -d "$UPDATE_TEMP" ]; then rm -rf -- "$UPDATE_TEMP" || true; fi
    return "$rc"
}

update_lock() {
    command -v flock >/dev/null 2>&1 || { update_fail "flock indisponivel"; return 1; }
    mkdir -p "$(dirname "$CRIAS_UPDATE_LOCK")" || return 1
    exec 9>"$CRIAS_UPDATE_LOCK"
    flock -n 9 || { update_fail "Outra atualizacao esta em andamento"; return 1; }
}

update_validate_install() {
    local root="${CRIAS_UPDATE_INSTALL_DIR}.releases"
    [ -L "$CRIAS_UPDATE_INSTALL_DIR" ] || {
        update_fail "Atualizacao segura exige link versionado em $CRIAS_UPDATE_INSTALL_DIR"; return 1
    }
    UPDATE_PREVIOUS_REF="$(readlink -f "$CRIAS_UPDATE_INSTALL_DIR")" || return 1
    case "$UPDATE_PREVIOUS_REF" in
        "$root"/release.*|"$root"/legacy.*) ;;
        *) update_fail "Instalacao nao gerenciada em $root"; return 1 ;;
    esac
    [ -f "$UPDATE_PREVIOUS_REF/install.sh" ] || { update_fail "Release atual invalida"; return 1; }
}

update_apply_steps() {
    local root="${CRIAS_UPDATE_INSTALL_DIR}.releases"
    log "Baixando a release $CRIAS_RELEASE_TAG_NAME, sem tocar no jogo..."
    update_download "$CRIAS_ZIP_URL" "$UPDATE_TEMP/release.zip" || return 1
    update_download "$CRIAS_SHA_URL" "$UPDATE_TEMP/sha256sums.txt" || return 1
    crias_verify_sha256 "$UPDATE_TEMP/release.zip" "$UPDATE_TEMP/sha256sums.txt" "$CRIAS_ASSET_ZIP" || return 1
    mkdir -p "$UPDATE_TEMP/check" || return 1
    update_preflight "$UPDATE_TEMP/release.zip" "$UPDATE_TEMP/check" || return 1
    # Crucial: do NOT invoke crias_extract_to from the previously installed
    # bootstrap. It may prune the previous active rollback version.
    update_prepare_release "$root" || return 1
    update_prepare_journal "$UPDATE_PREVIOUS_REF" "$UPDATE_NEW_REF" || return 1
    update_publish_release || return 1
    update_deploy_admin || return 1
    printf 'committed\n' > "$UPDATE_TXN/.commit.tmp" || return 1
    mv -f -T "$UPDATE_TXN/.commit.tmp" "$UPDATE_TXN/committed" || return 1
    UPDATE_COMMITTED=1
    rm -rf -- "$UPDATE_TXN" || warn "Transacao concluida; limpeza pendente"
    update_prune_releases
}

update_apply() {
    update_root_required || return 1
    update_lock || return 1
    update_recover_pending || return 1
    update_validate_install || return 1
    update_fetch_release || return 1
    if [ "$(update_local_tag)" = "$CRIAS_RELEASE_TAG_NAME" ]; then
        ok "Versao $CRIAS_RELEASE_TAG_NAME ja instalada. Sem alteracoes."
        return 0
    fi
    UPDATE_COMMITTED=0
    UPDATE_NEW_REF=""
    UPDATE_TXN=""
    UPDATE_TEMP="$(mktemp -d /tmp/crias-update.XXXXXXXX)" || return 1
    chmod 0700 "$UPDATE_TEMP" || return 1
    trap update_exit_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! update_apply_steps; then
        update_abort
        return 1
    fi
    rm -rf -- "$UPDATE_TEMP" || true
    UPDATE_TEMP=""
    trap - EXIT INT TERM
    ok "Crias-Server atualizado para $CRIAS_RELEASE_TAG_NAME."
    echo "Mundos, modpacks e servicos de jogo nao foram modificados nem reiniciados."
    echo "Reabra o Hub para carregar o menu atualizado."
}

update_recover() {
    update_root_required || return 1
    update_lock || return 1
    update_recover_pending
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
    echo "Leia avisos de manutencao antes da atualizacao: https://archlinux.org/news/"
    echo "O pacman mostrara as alteracoes e pedira confirmacao; revise a lista."
    printf "Digite ATUALIZAR ARCH para autorizar pacman -Syu: "
    local answer
    IFS= read -r answer || return 1
    if [ "$answer" != "ATUALIZAR ARCH" ]; then
        warn "Cancelado; pacman nao foi executado."
        return 1
    fi
    pacman -Syu
    ok "Pacotes atualizados. Reboot fica a cargo do administrador."
}

update_main() {
    case "${1:-}" in
        check) [ "$#" -eq 1 ] || return 2; update_check ;;
        apply) [ "$#" -eq 1 ] || return 2; update_apply ;;
        recover) [ "$#" -eq 1 ] || return 2; update_recover ;;
        arch-check) [ "$#" -eq 1 ] || return 2; update_arch_check ;;
        arch-apply) [ "$#" -eq 1 ] || return 2; update_arch_apply ;;
        *)
            echo "Uso: crias-update {check|apply|recover|arch-check|arch-apply}" >&2
            return 2 ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    update_main "$@"
fi
