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
# Snapshot dos artefatos preexistentes (CR-08): captura unit, runtime.env,
# scripts e .shared ANTES de o installer sobrescrever, para que o rollback
# RESTAURE o estado anterior em vez de apagar. So captura diretorio
# preexistente (instalacao nova nao tem o que preservar).
# ---------------------------------------------------------------------------
STACK_SNAPSHOT_DIR=""

snapshot_stack_artifacts() {
    STACK_SNAPSHOT_DIR=""

    if [ "${STACK_SERVER_DIR_PREEXISTED:-false}" != "true" ]; then
        return 0
    fi

    STACK_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crias-stack-snapshot.XXXXXX")" || {
        STACK_SNAPSHOT_DIR=""
        return 0
    }

    if [ -f "/etc/systemd/system/${STACK_NAME}.service" ]; then
        cp -a "/etc/systemd/system/${STACK_NAME}.service" "$STACK_SNAPSHOT_DIR/service.unit" 2>/dev/null || true
    fi

    local artifact
    for artifact in runtime.env hardware-profile.env comandos.sh; do
        if [ -f "$STACK_SERVER_DIR/$artifact" ]; then
            cp -a "$STACK_SERVER_DIR/$artifact" "$STACK_SNAPSHOT_DIR/$artifact" 2>/dev/null || true
        fi
    done

    local script base
    for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
        base="$(basename "$script")"
        if [ -f "$STACK_SERVER_DIR/$base" ]; then
            cp -a "$STACK_SERVER_DIR/$base" "$STACK_SNAPSHOT_DIR/$base" 2>/dev/null || true
        fi
    done

    if [ -d "$STACK_SERVER_DIR/.shared" ]; then
        cp -a "$STACK_SERVER_DIR/.shared" "$STACK_SNAPSHOT_DIR/.shared" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Best-effort rollback. Restaura o snapshot quando disponivel (CR-08);
# NUNCA apaga dados do usuario (mundos, mods/, configs) — so artefatos
# gerados pelo installer.
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
    elif [ -n "${STACK_SNAPSHOT_DIR:-}" ] && [ -d "$STACK_SNAPSHOT_DIR" ]; then
        # Diretorio preexistente COM snapshot: restaura o estado anterior
        # (CR-08 — antes os artefatos eram apagados sem restauracao).
        if [ -f "$STACK_SNAPSHOT_DIR/service.unit" ]; then
            cp -a "$STACK_SNAPSHOT_DIR/service.unit" "$service_unit" 2>/dev/null || true
        else
            rm -f "$service_unit" 2>/dev/null || true
        fi

        local artifact
        for artifact in runtime.env hardware-profile.env comandos.sh; do
            if [ -f "$STACK_SNAPSHOT_DIR/$artifact" ]; then
                cp -a "$STACK_SNAPSHOT_DIR/$artifact" "$STACK_SERVER_DIR/$artifact" 2>/dev/null || true
            else
                rm -f "$STACK_SERVER_DIR/$artifact" 2>/dev/null || true
            fi
        done

        local script base
        for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
            base="$(basename "$script")"
            if [ -f "$STACK_SNAPSHOT_DIR/$base" ]; then
                cp -a "$STACK_SNAPSHOT_DIR/$base" "$STACK_SERVER_DIR/$base" 2>/dev/null || true
            else
                rm -f "$STACK_SERVER_DIR/$base" 2>/dev/null || true
            fi
        done

        if [ -d "$STACK_SNAPSHOT_DIR/.shared" ]; then
            rm -rf "$STACK_SERVER_DIR/.shared" 2>/dev/null || true
            cp -a "$STACK_SNAPSHOT_DIR/.shared" "$STACK_SERVER_DIR/" 2>/dev/null || true
        else
            rm -rf "$STACK_SERVER_DIR/.shared" 2>/dev/null || true
        fi

        rm -rf "$STACK_SNAPSHOT_DIR" 2>/dev/null || true
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

    # Artefatos extras criados APENAS pelo installer (nunca dados do usuario:
    # mundos, mods/ e configs ficam de fora por contrato — ver
    # stack_rollback_extra_files nos stacks).
    local extra_files=()
    if declare -F stack_rollback_extra_files >/dev/null 2>&1; then
        mapfile -t extra_files < <(stack_rollback_extra_files)
    fi
    if [ "${#extra_files[@]}" -gt 0 ]; then
        rm -rf "${extra_files[@]}" 2>/dev/null || true
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
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
    local unit_target="/etc/systemd/system/${STACK_NAME}.service"
    local unit_tmp
    unit_tmp="$(mktemp_crias_file)"

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

    # install does atomic copy (open + rename) with mode 0644.
    install -m 0644 -o root -g root "$unit_tmp" "$unit_target"
    rm -f "$unit_tmp"

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

    # Save prior EXIT trap state and install ours.
    # Only track existence (not content) to avoid eval on captured trap strings.
    local _had_prev_trap_exit=false
    if [ -n "$(trap -p EXIT 2>/dev/null || true)" ]; then
        _had_prev_trap_exit=true
    fi

    trap 'if [ "${STACK_INSTALL_SUCCEEDED:-false}" != "true" ]; then rollback_stack_install; fi' EXIT

    # Snapshot dos artefatos preexistentes (CR-08): captura ANTES de qualquer
    # fase modificar o diretorio/unit, para o rollback poder restaurar.
    if ! dry_run_enabled; then
        snapshot_stack_artifacts
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

    STACK_INSTALL_SUCCEEDED=true
    print_success "${STACK_NAME^^} instalado com sucesso em $STACK_SERVER_DIR"

    # Clear our EXIT trap. Caller must reset prior trap explicitly if needed.
    trap - EXIT
    if [ "$_had_prev_trap_exit" = "true" ]; then
        print_warning "Trap EXIT pré-existente foi removido por run_stack_install; reconfigure explicitamente se necessário."
    fi

    # Sucesso: o snapshot pre-instalacao nao e mais necessario (so o rollback
    # o usava). Limpo DEPOIS de desarmar o trap — se o rm falhar aqui, nao ha
    # mais caminho de rollback para corromper. Sem isto o mktemp -d vaza em
    # /tmp a cada reinstalacao bem-sucedida.
    if [ -n "${STACK_SNAPSHOT_DIR:-}" ] && [ -d "$STACK_SNAPSHOT_DIR" ]; then
        rm -rf "$STACK_SNAPSHOT_DIR" 2>/dev/null || true
    fi
}
