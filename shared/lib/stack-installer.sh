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
# Best-effort rollback. Does not abort on individual failures.
# ---------------------------------------------------------------------------
rollback_stack_install() {
    local service_unit="/etc/systemd/system/${STACK_NAME}.service"

    if dry_run_enabled; then
        return 0
    fi

    print_warning "Instalacao do ${STACK_NAME^^} falhou; executando rollback best-effort."
    rm -f "$service_unit" 2>/dev/null || true

    # Allow stack to provide a list of extra files to clean.
    local extra_files=()
    if declare -F stack_rollback_extra_files >/dev/null 2>&1; then
        mapfile -t extra_files < <(stack_rollback_extra_files)
    fi

    if [ "${STACK_SERVER_DIR_PREEXISTED:-false}" = "false" ]; then
        safe_remove_dir "$STACK_SERVER_DIR" || true
    else
        # Server preexisted: clean only installer artifacts.
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
        scripts_to_clean+=("${extra_files[@]}")
        rm -f "${scripts_to_clean[@]}" 2>/dev/null || true
        rm -rf "$STACK_SERVER_DIR/.shared" 2>/dev/null || true
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
    # Empty defaults so envsubst does not fail with -u.
    local SERVER_USER="$STACK_USER"
    local SERVER_DIR="$STACK_SERVER_DIR"
    local MEMORY_MAX_MB="${STACK_SERVICE_MEMORY_MAX_MB:-2048}"
    local SERVICE_NAME="$STACK_NAME"

    # Allow stack to provide extra variables.
    if declare -F stack_service_extra_env >/dev/null 2>&1; then
        # Callback may export additional variables.
        stack_service_extra_env
    fi

    # envsubst reads stdin, substitutes ${VAR}, writes stdout.
    # Use explicit var list to avoid substituting embedded ${1} etc.
    if dry_run_enabled; then
        print_step "[DRY_RUN] Gerando unidade systemd do ${STACK_NAME^^} em /etc/systemd/system/${STACK_NAME}.service (nao sera escrita)"
        envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
            < "$STACK_SERVICE_TEMPLATE" > /dev/null
        return 0
    fi

    # Write to tmpfile and move atomically. Validate with systemd-analyze
    # verify before rename to avoid loading a partial unit.
    local unit_target="/etc/systemd/system/${STACK_NAME}.service"
    local unit_tmp
    unit_tmp="$(mktemp "${TMPDIR:-/tmp}/crias_unit_${STACK_NAME}.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -f -- "$unit_tmp"' RETURN

    if ! envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
            < "$STACK_SERVICE_TEMPLATE" > "$unit_tmp"; then
        print_error "envsubst falhou ao gerar unit file para ${STACK_NAME}."
        rm -f "$unit_tmp"
        return 1
    fi

    # Optionally validate with systemd-analyze before moving.
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze verify "$unit_tmp" >/dev/null 2>&1; then
            print_warning "systemd-analyze verify reportou problemas em $unit_tmp; verifique antes de prosseguir."
            # Don't abort — some warnings are benign.
        fi
    fi

    # install does atomic copy (open + rename) with mode 0644.
    install -m 0644 -o root -g root "$unit_tmp" "$unit_target"
    rm -f "$unit_tmp"

    systemctl daemon-reload
    systemctl enable "$STACK_NAME" >/dev/null 2>&1 || true
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

    # Auto-skip in container/VPS.
    if is_virtualized; then
        local virt_type=""
        if command_exists systemd-detect-virt; then
            virt_type="$(systemd-detect-virt 2>/dev/null || echo unknown)"
        else
            virt_type="container"
        fi
        print_warning "Virtualizacao detectada ($virt_type); skip de tuning de host (sysctl/zram/scheduler/cpupower)."
        print_warning "Defina SYSTEM_TUNING_SCOPE=host explicitamente se quiser forcar tuning mesmo em container."
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
}
