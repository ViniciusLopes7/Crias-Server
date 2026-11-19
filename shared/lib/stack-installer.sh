#!/bin/bash
# shared/lib/stack-installer.sh
#
# Unified install framework for Minecraft and Terraria stacks.
#
# Usage:
#
#   source "$ROOT_DIR/shared/lib/stack-installer.sh"
#
#   # Stack-specific hooks:
#   stack_download_and_install() { ... }   # required
#   stack_configure_runtime()    { ... }   # required
#   stack_install_extra_deps()   { ... }   # optional
#   stack_install_logrotate()    { ... }   # optional
#   stack_install_qol_mods()     { ... }   # optional (Minecraft only)
#   stack_install_extra_mods()  { ... }   # optional (Minecraft only)
#
#   # Variables the caller MUST define before calling:
#   STACK_NAME              # "minecraft" | "terraria"
#   STACK_USER              # systemd user
#   STACK_SERVER_DIR        # /opt/<stack>-server
#   STACK_SERVICE_TEMPLATE  # path to .service template
#   STACK_RUNTIME_SCRIPTS   # array of runtime scripts to copy
#   STACK_SHARED_LIBS       # array of shared libs to copy
#
#   run_stack_install
#
# Framework handles: rollback via EXIT trap, user/dir creation, script and
# lib copying, systemd unit install via envsubst, and host tuning (skipped
# in VPS/container).

# NOTE: do not use `set -u` in sourced libs; caller decides error policy.

# ---------------------------------------------------------------------------
# Create stack user and base directories.
# ---------------------------------------------------------------------------
create_stack_user_and_dirs() {
    print_step "Garantindo usuario e diretorio do ${STACK_NAME^^}..."

    # Validate STACK_SERVER_DIR before destructive operations.
    if ! validate_server_dir "$STACK_SERVER_DIR"; then
        print_error "STACK_SERVER_DIR rejeitado pela validação de segurança."
        return 1
    fi

    if dry_run_enabled; then
        print_step "[DRY_RUN] Pulando criacao do usuario e diretorio do ${STACK_NAME^^}."
        return 0
    fi

    if [ -d "$STACK_SERVER_DIR" ]; then
        STACK_SERVER_DIR_PREEXISTED=true
    else
        STACK_SERVER_DIR_PREEXISTED=false
    fi

    if ! id "$STACK_USER" >/dev/null 2>&1; then
        useradd -r -M -s /usr/bin/nologin -d "$STACK_SERVER_DIR" "$STACK_USER"
    fi

    # Allow stack to create specific subdirs (worlds/, config/, mods/).
    mkdir -p "$STACK_SERVER_DIR"
    if declare -F stack_create_extra_dirs >/dev/null 2>&1; then
        stack_create_extra_dirs
    fi

    chown -R "${STACK_USER}:${STACK_USER}" "$STACK_SERVER_DIR"
}

# ---------------------------------------------------------------------------
# Snapshot dos artefatos preexistentes (CR-04): captura TUDO que o installer
# pode sobrescrever — unit, runtime.env, hardware-profile.env, comandos.sh,
# scripts de runtime, .shared/ E os extras declarados pelo stack
# (server.properties, serverconfig.txt, server.jar, server/, steamapps/...) —
# ANTES de qualquer fase modificar o diretorio. O rollback usa o MANIFESTO
# (arquivo de decisoes) para saber, por artefato: restaurar do snapshot,
# remover (nao existia antes) ou preservar o atual (snapshot pulado por
# tamanho). Snapshot de artefato existente que FALHA aborta a instalacao
# (fail-closed) — antes `cp -a ... || true` deixava o rollback sem estado
# para restaurar.
# ---------------------------------------------------------------------------
STACK_SNAPSHOT_DIR=""
STACK_SNAPSHOT_MANIFEST=""
# (AUDIT-A P2-3) So e true quando o snapshot foi 100% concluido. Se a
# preparacao do snapshot falhar (mktemp/disco), o rollback NAO pode rodar a
# limpeza legacy (apagaria artefatos preexistentes que esta execucao nunca
# tocou — contradizendo o contrato do CR-04).
STACK_SNAPSHOT_COMPLETE=false

# Registra uma decisao no manifesto: "restore|remove|leave <rel>".
_snapshot_record() {
    printf '%s %s\n' "$1" "$2" >> "$STACK_SNAPSHOT_MANIFEST"
}

# Snapshot de um artefato (arquivo ou diretorio) com verificacao.
# $1 = caminho absoluto do artefato; $2 = nome relativo no snapshot.
_snapshot_capture() {
    local path="$1" rel="$2"

    if [ ! -e "$path" ]; then
        # Nao existia antes desta execucao: o rollback pode remover.
        _snapshot_record "remove" "$rel"
        return 0
    fi

    # Diretorios enormes (tML ~centenas de MB) podem nao caber no TMPDIR;
    # acima do teto o snapshot e PULADO e o rollback PRESERVA o atual
    # (nunca apaga o que nao pode restaurar). Aviso claro, decisao "leave".
    local size_bytes=0
    if [ -d "$path" ]; then
        size_bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
        if ! [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
            size_bytes=0
        fi
        local max_bytes="${CRIAS_SNAPSHOT_MAX_BYTES:-2147483648}"
        if [ "$size_bytes" -gt "$max_bytes" ]; then
            print_warning "Snapshot de $rel pulado (${size_bytes} bytes > teto ${max_bytes}); rollback preservara o conteudo atual."
            _snapshot_record "leave" "$rel"
            return 0
        fi
    fi

    # (AUDIT-A P1-2) Rels aninhados (ex.: config/serverconfig.txt) precisam
    # do diretorio-pai criado no snapshot — sem isto o cp falhava e o modo
    # fail-closed abortava TODA reinstalacao do Terraria.
    local snap_target="$STACK_SNAPSHOT_DIR/$rel"
    mkdir -p "$(dirname "$snap_target")"

    if ! cp -a "$path" "$snap_target" 2>/dev/null || [ ! -e "$snap_target" ]; then
        print_error "Falha ao fotografar artefato preexistente: $path"
        print_error "Sem snapshot integro o rollback nao pode restaurar; abortando ANTES de modificar o sistema."
        return 1
    fi
    _snapshot_record "restore" "$rel"
}

snapshot_stack_artifacts() {
    STACK_SNAPSHOT_DIR=""
    STACK_SNAPSHOT_MANIFEST=""
    STACK_SNAPSHOT_COMPLETE=false

    if [ "${STACK_SERVER_DIR_PREEXISTED:-false}" != "true" ]; then
        return 0
    fi

    STACK_SNAPSHOT_MANIFEST="$(mktemp_crias_file)" || return 1
    STACK_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crias-stack-snapshot.XXXXXX")" || {
        STACK_SNAPSHOT_DIR=""
        print_error "Falha ao criar diretorio de snapshot (mktemp)."
        return 1
    }

    # Unit systemd (fora do diretorio do jogo — nome fixo no snapshot).
    # NOTA: cada captura propaga falha explicitamente (`|| return 1`) — o
    # caller invoca esta funcao em contexto condicional (`if ! ...`), o que
    # desativa o errexit interno; sem o return explicito a falha do primeiro
    # artefato nao abortaria os demais.
    local service_unit="/etc/systemd/system/${STACK_NAME}.service"
    _snapshot_capture "$service_unit" "service.unit" || return 1

    local artifact
    for artifact in runtime.env hardware-profile.env comandos.sh; do
        _snapshot_capture "$STACK_SERVER_DIR/$artifact" "$artifact" || return 1
    done

    local script base
    for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
        base="$(basename "$script")"
        _snapshot_capture "$STACK_SERVER_DIR/$base" "$base" || return 1
    done

    _snapshot_capture "$STACK_SERVER_DIR/.shared" ".shared" || return 1

    # (CR-04) Extras declarados pelo stack: configs, jar do servidor,
    # server/ do tModLoader, steamapps/... Tudo que o installer sobrescreve.
    if declare -F stack_snapshot_extra_paths >/dev/null 2>&1; then
        local extra extra_rel
        while IFS= read -r extra; do
            [ -z "$extra" ] && continue
            # (AUDIT-A P3-11) Extras do stack vivem sob o prefixo extra/ no
            # snapshot: nunca colidem com nomes reservados do manifesto
            # (service.unit, runtime.env, ...). Caminho completo sob o server
            # dir preservado; caminho externo vira nome plano.
            extra_rel="${extra#"$STACK_SERVER_DIR"/}"
            case "$extra_rel" in
                "$extra")
                    extra_rel="$(basename "$extra")"
                    ;;
            esac
            _snapshot_capture "$extra" "extra/$extra_rel" || return 1
        done < <(stack_snapshot_extra_paths)
    fi

    # (AUDIT-A P2-3) Snapshot 100% concluido: todas as capturas OK. Se
    # qualquer captura falhar, o return 1 acima deixa a flag false e o
    # rollback vira NO-OP (esta execucao abortou antes de modificar algo).
    STACK_SNAPSHOT_COMPLETE=true
    return 0
}

# ---------------------------------------------------------------------------
# Best-effort rollback orientado a manifesto (CR-04). Por artefato:
#   restore -> devolve o estado pre-instalacao fotografado;
#   remove  -> apaga (o artefato nao existia antes desta execucao);
#   leave   -> preserva o atual (snapshot pulado; nunca apagar sem restauro).
# ---------------------------------------------------------------------------
rollback_stack_install() {
    local service_unit="/etc/systemd/system/${STACK_NAME}.service"

    if dry_run_enabled; then
        return 0
    fi

    print_warning "Instalacao do ${STACK_NAME^^} falhou; executando rollback best-effort."

    if [ "${STACK_SERVER_DIR_PREEXISTED:-false}" = "false" ]; then
        # Instalacao nova: o diretorio inteiro foi criado por esta execucao.
        rm -f "$service_unit" 2>/dev/null || true
        safe_remove_dir "$STACK_SERVER_DIR" || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 0
    fi

    if [ -n "${STACK_SNAPSHOT_MANIFEST:-}" ] && [ -f "$STACK_SNAPSHOT_MANIFEST" ] \
        && [ -n "${STACK_SNAPSHOT_DIR:-}" ] && [ -d "$STACK_SNAPSHOT_DIR" ]; then
        local action rel target
        while read -r action rel; do
            [ -z "${action:-}" ] || [ -z "${rel:-}" ] && continue
            case "$rel" in
                service.unit) target="$service_unit" ;;
                # (AUDIT-A P3-11) Extras do stack: o prefixo extra/ e interno
                # do snapshot — o alvo real e o caminho sem o prefixo.
                extra/*) target="$STACK_SERVER_DIR/${rel#extra/}" ;;
                *) target="$STACK_SERVER_DIR/$rel" ;;
            esac
            case "$action" in
                restore)
                    if [ -e "$STACK_SNAPSHOT_DIR/$rel" ]; then
                        rm -rf -- "$target" 2>/dev/null || true
                        cp -a "$STACK_SNAPSHOT_DIR/$rel" "$target" 2>/dev/null || true
                    else
                        rm -f -- "$target" 2>/dev/null || true
                    fi
                    ;;
                remove)
                    rm -rf -- "$target" 2>/dev/null || true
                    ;;
                leave)
                    print_warning "Rollback preservou '$rel' (sem snapshot; conteudo atual mantido)."
                    ;;
            esac
        done < "$STACK_SNAPSHOT_MANIFEST"

        rm -rf "$STACK_SNAPSHOT_DIR" 2>/dev/null || true
    elif [ "${STACK_SNAPSHOT_COMPLETE:-false}" != "true" ]; then
        # (AUDIT-A P2-3) Preexistente com snapshot INCOMPLETO: esta execucao
        # abortou ANTES de modificar qualquer coisa (o snapshot roda primeiro)
        # — o rollback e NO-OP. A limpeza legacy apagaria artefatos que nem
        # chegaram a ser tocados.
        print_warning "Snapshot pre-instalacao incompleto; rollback SEM acao (nada foi modificado por esta execucao)."
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 0
    else
        # Preexistente SEM snapshot (execucao legacy): remove so artefatos do
        # installer, preservando dados do usuario.
        rm -f "$service_unit" 2>/dev/null || true
        local scripts_to_clean=()
        # ${arr[@]+"${arr[@]}"} expands to nothing when array is empty (set -u safe).
        for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
            scripts_to_clean+=("$STACK_SERVER_DIR/$(basename "$script")")
        done
        scripts_to_clean+=(
            "$STACK_SERVER_DIR/comandos.sh"
            "$STACK_SERVER_DIR/runtime.env"
            "$STACK_SERVER_DIR/hardware-profile.env"
        )
        rm -f "${scripts_to_clean[@]}" 2>/dev/null || true
        rm -rf "$STACK_SERVER_DIR/.shared" 2>/dev/null || true
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# (EXP-34) Ferramentas administrativas (managers + libs usadas por root)
# vivem FORA do diretorio do jogo, em /usr/local/libexec/crias, root:root.
# Dentro de STACK_SERVER_DIR elas eram gravaveis pelo usuario do jogo
# (chown -R): um processo de jogo comprometido podia reescrever o manager
# e o `. .shared/*.sh` — o proximo `sudo <manager>` executaria codigo
# arbitrario como root. O diretorio do jogo guarda apenas o que o processo
# do jogo precisa executar (start-server.sh, backup-cron.sh e o .shared de
# runtime, rodando com o privilegio do propio jogo).
# ---------------------------------------------------------------------------
CRIS_LIBEXEC_DIR="/usr/local/libexec/crias"
CRIS_LIBEXEC_LIB_DIR="$CRIS_LIBEXEC_DIR/lib"

deploy_stack_admin_tools() {
    print_step "Instalando ferramentas administrativas em $CRIS_LIBEXEC_DIR (root:root)..."

    if dry_run_enabled; then
        print_step "[DRY_RUN] Pulando deploy de ferramentas administrativas."
        return 0
    fi

    mkdir -p "$CRIS_LIBEXEC_DIR" "$CRIS_LIBEXEC_LIB_DIR"

    # Managers/scripts administrativos declarados pelo stack.
    local admin_script base
    for admin_script in ${STACK_ADMIN_SCRIPTS[@]+"${STACK_ADMIN_SCRIPTS[@]}"}; do
        base="$(basename "$admin_script")"
        if [ -f "$admin_script" ]; then
            install -m 0755 -o root -g root "$admin_script" "$CRIS_LIBEXEC_DIR/$base"
        else
            print_error "Script administrativo nao encontrado: $admin_script"
            return 1
        fi
    done

    # Libs compartilhadas (sourced por managers executados como root).
    local lib
    for lib in ${STACK_SHARED_LIBS[@]+"${STACK_SHARED_LIBS[@]}"}; do
        base="$(basename "$lib")"
        install -m 0644 -o root -g root "$lib" "$CRIS_LIBEXEC_LIB_DIR/$base"
    done

    # Migracao de instalacoes legadas: remove as copias gravaveis pelo jogo.
    # Managers e a lib manager-common.sh nao podem mais viver no diretorio
    # do jogo (superficie de escalada root). setup-cron.sh tambem e
    # administrativo (roda como root via manager) e muda de lugar junto.
    rm -f "$STACK_SERVER_DIR/mc-manager.sh" \
          "$STACK_SERVER_DIR/tt-manager.sh" \
          "$STACK_SERVER_DIR/setup-cron.sh" \
          "$STACK_SERVER_DIR/.shared/manager-common.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Deploy runtime scripts + shared libs + comandos.sh.
# ---------------------------------------------------------------------------
deploy_stack_scripts() {
    print_step "Copiando scripts do modulo ${STACK_NAME^^}..."

    # ${arr[@]+"${arr[@]}"} expands to nothing when array is empty (set -u safe).
    local script
    for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
        local base
        base="$(basename "$script")"
        run_or_dry_run "Copiando $base do ${STACK_NAME^^}" cp "$script" "$STACK_SERVER_DIR/$base"
    done

    run_or_dry_run "Criando diretorio compartilhado do ${STACK_NAME^^}" mkdir -p "$STACK_SERVER_DIR/.shared"

    local lib
    for lib in ${STACK_SHARED_LIBS[@]+"${STACK_SHARED_LIBS[@]}"}; do
        local base
        base="$(basename "$lib")"
        run_or_dry_run "Copiando $base compartilhado do ${STACK_NAME^^}" cp "$lib" "$STACK_SERVER_DIR/.shared/$base"
    done

    # Mark runtime scripts as executable.
    local chmod_targets=()
    for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
        chmod_targets+=("$STACK_SERVER_DIR/$(basename "$script")")
    done
    if [ "${#chmod_targets[@]}" -gt 0 ]; then
        run_or_dry_run "Marcando scripts do ${STACK_NAME^^} como executaveis" chmod +x "${chmod_targets[@]}"
    fi

    # Allow stack to copy extra assets (server-icon.png, etc.).
    if declare -F stack_deploy_extra_assets >/dev/null 2>&1; then
        stack_deploy_extra_assets
    fi

    # Generate comandos.sh with aliases via stack callback.
    if declare -F stack_generate_aliases >/dev/null 2>&1; then
        local aliases_content
        aliases_content="$(stack_generate_aliases)"
        printf '%s\n' "$aliases_content" | write_file_or_dry_run "Gerando comandos do ${STACK_NAME^^} em $STACK_SERVER_DIR/comandos.sh" "$STACK_SERVER_DIR/comandos.sh"
        run_or_dry_run "Marcando comandos do ${STACK_NAME^^} como executavel" chmod +x "$STACK_SERVER_DIR/comandos.sh"
    fi

    if ! dry_run_enabled; then
        # Revalidate before chown -R (path may have changed).
        if validate_server_dir "$STACK_SERVER_DIR"; then
            chown -R "${STACK_USER}:${STACK_USER}" "$STACK_SERVER_DIR"
        else
            print_error "Recusa de chown -R em STACK_SERVER_DIR inválido: '$STACK_SERVER_DIR'"
            return 1
        fi
    fi

    # (EXP-34) Ferramentas administrativas fora da arvore do jogo, DEPOIS do
    # chown -R (garante root:root mesmo que um arquivo legado seja migrado).
    deploy_stack_admin_tools
}

# ---------------------------------------------------------------------------
# Install systemd unit via envsubst (avoids injection in MOTD and
# special characters).
# ---------------------------------------------------------------------------
install_stack_service() {
    print_step "Instalando servico systemd do ${STACK_NAME^^}..."

    if ! command_exists envsubst; then
        print_error "envsubst nao encontrado. Instale gettext (pacman -S gettext)."
        return 1
    fi

    # Variables the template can use via ${VAR}.
    # Valida ANTES de gerar a unit: campo vazio aqui vira User= / MemoryMax=M
    # no arquivo final (modo de falha do CR-03).
    if [ -z "$STACK_USER" ] || [ -z "$STACK_SERVER_DIR" ] || [ -z "${STACK_SERVICE_MEMORY_MAX_MB:-}" ]; then
        print_error "install_stack_service: STACK_USER/STACK_SERVER_DIR/STACK_SERVICE_MEMORY_MAX_MB nao podem ser vazios."
        return 1
    fi

    # Allow stack to provide extra variables.
    if declare -F stack_service_extra_env >/dev/null 2>&1; then
        # Callback may export additional variables.
        stack_service_extra_env
    fi

    # envsubst reads stdin, substitutes ${VAR}, writes stdout.
    # Use explicit var list to avoid substituting embedded ${1} etc.
    # Valores passados via env do COMANDO (CR-03): `local` nao exporta, e o
    # envsubst (binario externo) lia ambiente sem as variaveis — gerando
    # User=, ExecStart=/start-server.sh e MemoryMax=M. O prefixo `env` so
    # exporta para o envsubst, sem vazar globais no installer.
    local _envsubst_vars='${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}'
    if dry_run_enabled; then
        print_step "[DRY_RUN] Gerando unidade systemd do ${STACK_NAME^^} em /etc/systemd/system/${STACK_NAME}.service (nao sera escrita)"
        env SERVER_USER="$STACK_USER" SERVER_DIR="$STACK_SERVER_DIR" \
            MEMORY_MAX_MB="${STACK_SERVICE_MEMORY_MAX_MB:-2048}" SERVICE_NAME="$STACK_NAME" \
            envsubst "$_envsubst_vars" \
            < "$STACK_SERVICE_TEMPLATE" > /dev/null
        return 0
    fi

    # Write to tmpfile and move atomically. Validate with systemd-analyze
    # verify before rename to avoid loading a partial unit.
    # (CR-01) O temporario precisa terminar em .service: o systemd-analyze
    # verify rejeita arquivos sem extensao de unidade valida ("Failed to
    # prepare filename ...: Invalid argument" no systemd 257) — o nome
    # antigo (/tmp/crias.XXXXXX) fazia a validacao bloqueante falhar SEMPRE,
    # derrubando toda instalacao nao-DRY_RUN.
    # (EXP-59) O temporario vive no MESMO diretorio do destino para o rename
    # ser atomico (rename(2) via mv -T): `install` copia por cima do destino
    # — um corte no meio deixava a unit anterior truncada.
    local unit_target="/etc/systemd/system/${STACK_NAME}.service"
    local unit_tmp
    unit_tmp="$(mktemp --tmpdir=/etc/systemd/system --suffix=.service crias-unit.XXXXXX)" || {
        print_error "Falha ao criar temporario da unit em /etc/systemd/system."
        return 1
    }
    # Registrar no limpador de temporarios do common.sh (cobre caminhos de
    # erro antecipados antes do rm -f explicito abaixo).
    printf '%s\n' "$unit_tmp" >> "$CRIAS_TEMPS_FILE" 2>/dev/null || true

    if ! env SERVER_USER="$STACK_USER" SERVER_DIR="$STACK_SERVER_DIR" \
            MEMORY_MAX_MB="${STACK_SERVICE_MEMORY_MAX_MB:-2048}" SERVICE_NAME="$STACK_NAME" \
            envsubst "$_envsubst_vars" \
            < "$STACK_SERVICE_TEMPLATE" > "$unit_tmp"; then
        print_error "envsubst falhou ao gerar unit file para ${STACK_NAME}."
        rm -f "$unit_tmp"
        return 1
    fi

    # Defesa em profundidade (CR-03): recusa campos criticos vazios mesmo com
    # a validacao de entrada acima.
    if grep -qE '^(User|Group|WorkingDirectory|ExecStart)=$' "$unit_tmp" \
        || grep -q '^MemoryMax=M$' "$unit_tmp"; then
        print_error "Unit do ${STACK_NAME} gerada com campos criticos vazios; abortando."
        rm -f "$unit_tmp"
        return 1
    fi

    # Validacao bloqueante (CR-25): unit rejeitada pelo systemd-analyze nao
    # pode ser instalada. A saida e impressa para diagnostico.
    if command -v systemd-analyze >/dev/null 2>&1; then
        local verify_out
        if ! verify_out="$(systemd-analyze verify "$unit_tmp" 2>&1)"; then
            print_error "systemd-analyze verify rejeitou a unit do ${STACK_NAME}:"
            printf '%s\n' "$verify_out" >&2
            rm -f "$unit_tmp"
            return 1
        fi
    fi

    # (EXP-59) Publicacao atomica: perms/owner no temporario + rename. A unit
    # anterior so e substituida quando o novo conteudo ja foi validado.
    chown root:root "$unit_tmp"
    chmod 0644 "$unit_tmp"
    if ! mv -T -- "$unit_tmp" "$unit_target"; then
        print_error "Falha ao publicar a unit do ${STACK_NAME} (mv -T)."
        rm -f "$unit_tmp"
        return 1
    fi

    systemctl daemon-reload
    # Habilitacao bloqueante (CR-25): falha aqui e falha da instalacao (o
    # rollback do EXIT trap remove a unit). Antes: `|| true` mascarava.
    if ! systemctl enable "$STACK_NAME" >/dev/null 2>&1; then
        print_error "Falha ao habilitar o servico ${STACK_NAME} (systemctl enable)."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Apply shared host tuning (skipped in virtualized environments).
# ---------------------------------------------------------------------------
apply_stack_system_tuning() {
    if dry_run_enabled; then
        print_step "[DRY_RUN] Pulando tuning de sistema compartilhado."
        return 0
    fi

    if ! is_true "${APPLY_SYSTEM_TUNING:-true}"; then
        return 0
    fi

    # Auto-skip em container/VPS — exceto com override explicito (CR-24):
    # VIRT_TUNING_BEHAVIOR=force e o contrato documentado em
    # docs/hardware-tuning.md (antes: variavel lida em lugar nenhum e a
    # mensagem sugeria SYSTEM_TUNING_SCOPE, que tambem nao e consultada
    # neste branch).
    if is_virtualized && [ "${VIRT_TUNING_BEHAVIOR:-auto}" != "force" ]; then
        local virt_type=""
        if command_exists systemd-detect-virt; then
            virt_type="$(systemd-detect-virt 2>/dev/null || echo unknown)"
        else
            virt_type="container"
        fi
        print_warning "Virtualizacao detectada ($virt_type); skip de tuning de host (sysctl/zram/scheduler/cpupower)."
        print_warning "Defina VIRT_TUNING_BEHAVIOR=force (veja docs/hardware-tuning.md) se quiser forcar tuning mesmo em container."
        return 0
    fi

    print_step "Aplicando tuning de sistema compartilhado..."
    apply_common_system_tuning "$STACK_USER" "${HW_TIER:-MID}" "${HW_TOTAL_RAM_MB:-4096}"
}

# ---------------------------------------------------------------------------
# Orchestrate the full stack install.
# ---------------------------------------------------------------------------
run_stack_install() {
    print_step "Iniciando instalacao do stack ${STACK_NAME^^}..."

    # Fail-fast if STACK_SERVER_DIR is unsafe (before installing rollback trap).
    if ! validate_server_dir "$STACK_SERVER_DIR"; then
        print_error "STACK_SERVER_DIR rejeitado pela validação de segurança: '$STACK_SERVER_DIR'"
        return 1
    fi

    if [ -d "$STACK_SERVER_DIR" ]; then
        STACK_SERVER_DIR_PREEXISTED=true
    else
        STACK_SERVER_DIR_PREEXISTED=false
    fi

    # (CR-21) O trap do common.sh (_crias_cleanup_temps) NAO pode ser
    # descartado: esta funcao o substitui pelo rollback e, no sucesso,
    # removia tudo com `trap - EXIT` — temporarios registrados vazavam em
    # /tmp. Composicao: rollback (se falha) + limpeza de temporarios SEMPRE.
    trap 'if [ "${STACK_INSTALL_SUCCEEDED:-false}" != "true" ]; then rollback_stack_install; fi; if declare -F _crias_cleanup_temps >/dev/null 2>&1; then _crias_cleanup_temps; fi' EXIT

    # Snapshot dos artefatos preexistentes (CR-04): captura ANTES de qualquer
    # fase modificar o diretorio/unit. Falha no snapshot de artefato
    # preexistente ABORTA a instalacao (fail-closed) — sem foto integra nao
    # existe rollback confiavel.
    if ! dry_run_enabled; then
        if ! snapshot_stack_artifacts; then
            print_error "Snapshot pre-instalacao falhou; abortando sem modificar o sistema."
            return 1
        fi
    fi

    # Stack-specific validation hook (inputs, EULA, etc.).
    if declare -F stack_validate_inputs >/dev/null 2>&1; then
        stack_validate_inputs
    fi

    if dry_run_enabled; then
        STACK_INSTALL_SUCCEEDED=true
        print_step "[DRY_RUN] Instalacao do ${STACK_NAME^^} encerrada sem aplicar alteracoes."
        return 0
    fi

    # 1. Dependências
    if declare -F stack_install_dependencies >/dev/null 2>&1; then
        stack_install_dependencies
    fi

    # 2. Usuário e diretórios
    create_stack_user_and_dirs

    # 3. Download + extração + EULA (específico do stack)
    if declare -F stack_download_and_install >/dev/null 2>&1; then
        stack_download_and_install
    else
        print_error "stack_download_and_install() nao definido pelo caller."
        return 1
    fi

    # 3b. Mods opcionais (tModLoader: SteamCMD; Minecraft: QoL mods).
    # Hook separado de stack_install_qol_mods para não conflitar.
    if declare -F stack_install_mods >/dev/null 2>&1; then
        stack_install_mods
    fi

    # 4. Mods QoL opcionais (apenas Minecraft define)
    if declare -F stack_install_qol_mods >/dev/null 2>&1; then
        stack_install_qol_mods
    fi

    # 4b. Mods individuais do usuário por cima do modpack/QoL (Minecraft).
    # Hook separado do QoL: extras não pulam quando mods/ já tem arquivos.
    if declare -F stack_install_extra_mods >/dev/null 2>&1; then
        stack_install_extra_mods
    fi

    # 5. Tuning de runtime (específico do stack)
    if declare -F stack_configure_runtime >/dev/null 2>&1; then
        stack_configure_runtime
    fi

    # 6. Deploy de scripts
    deploy_stack_scripts

    # 7. Unit systemd
    install_stack_service

    # 8. Logrotate (opcional — só Minecraft define)
    if declare -F stack_install_logrotate >/dev/null 2>&1; then
        stack_install_logrotate
    fi

    # 9. Tuning de host (com skip em VPS/container)
    apply_stack_system_tuning

    # 10. Finalizacao do stack (CR-17): modo strict pode transformar
    # pendencias (mods que falharam) em falha da instalacao — ANTES de
    # marcar sucesso, para o EXIT trap rodar o rollback.
    if declare -F stack_install_finalize >/dev/null 2>&1; then
        if ! stack_install_finalize; then
            print_error "Finalizacao do stack ${STACK_NAME} falhou; acionando rollback."
            return 1
        fi
    fi

    STACK_INSTALL_SUCCEEDED=true
    print_success "${STACK_NAME^^} instalado com sucesso em $STACK_SERVER_DIR"

    # (CR-21) Reinstala o trap de limpeza de temporarios do common.sh em vez
    # de remover todo o tratamento EXIT.
    if declare -F _crias_cleanup_temps >/dev/null 2>&1; then
        trap _crias_cleanup_temps EXIT
    else
        trap - EXIT
    fi

    # Sucesso: o snapshot pre-instalacao nao e mais necessario (so o rollback
    # o usava). Limpo DEPOIS de desarmar o trap — se o rm falhar aqui, nao ha
    # mais caminho de rollback para corromper. Sem isto o mktemp -d vaza em
    # /tmp a cada reinstalacao bem-sucedida.
    if [ -n "${STACK_SNAPSHOT_DIR:-}" ] && [ -d "$STACK_SNAPSHOT_DIR" ]; then
        rm -rf "$STACK_SNAPSHOT_DIR" 2>/dev/null || true
    fi
}
