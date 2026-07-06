#!/bin/bash
# shared/lib/stack-installer.sh
#
# Framework de instalação unificado para stacks Minecraft e Terraria.
# Reduz ~40% da duplicação entre minecraft/install.sh e terraria/install.sh
# (item A1 do plano).
#
# Como usar:
#
#   source "$ROOT_DIR/shared/lib/stack-installer.sh"
#
#   # Stack define hooks específicos:
#   stack_download_and_install() { ... }   # obrigatório
#   stack_configure_runtime()    { ... }   # obrigatório
#   stack_install_extra_deps()   { ... }   # opcional
#   stack_install_logrotate()    { ... }   # opcional
#   stack_install_qol_mods()     { ... }   # opcional (só Minecraft)
#
#   # Variáveis que o caller DEVE definir antes de chamar:
#   STACK_NAME              # "minecraft" | "terraria"
#   STACK_USER              # usuário do systemd
#   STACK_SERVER_DIR        # /opt/<stack>-server
#   STACK_SERVICE_TEMPLATE  # caminho para o .service template
#   STACK_RUNTIME_SCRIPTS   # array de scripts runtime a copiar
#   STACK_SHARED_LIBS       # array de libs compartilhadas a copiar
#
#   run_stack_install
#
# O framework trata:
#   - rollback automático via trap EXIT
#   - criação de usuário e diretórios
#   - cópia de scripts e libs compartilhadas
#   - instalação de unit systemd via envsubst
#   - aplicação de tuning de sistema (com skip em VPS/container)

# NOTA: não usar `set -u` em libs sourced — caller decide política de erro.

# ---------------------------------------------------------------------------
# Cria usuário do stack e diretórios base.
# ---------------------------------------------------------------------------
create_stack_user_and_dirs() {
    print_step "Garantindo usuario e diretorio do ${STACK_NAME^^}..."

    # SH-004: validar STACK_SERVER_DIR antes de qualquer operação destrutiva
    # (chown -R, mkdir, rm -rf) para evitar comprometer áreas do sistema.
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

    # Permite que o stack crie subdirs específicos (worlds/, config/, mods/).
    mkdir -p "$STACK_SERVER_DIR"
    if declare -F stack_create_extra_dirs >/dev/null 2>&1; then
        stack_create_extra_dirs
    fi

    chown -R "${STACK_USER}:${STACK_USER}" "$STACK_SERVER_DIR"
}

# ---------------------------------------------------------------------------
# Rollback best-effort. Não aborta em falhas individuais.
# ---------------------------------------------------------------------------
rollback_stack_install() {
    local service_unit="/etc/systemd/system/${STACK_NAME}.service"

    if dry_run_enabled; then
        return 0
    fi

    print_warning "Instalacao do ${STACK_NAME^^} falhou; executando rollback best-effort."
    rm -f "$service_unit" 2>/dev/null || true

    # Permite que o stack forneça lista de arquivos extras para limpar.
    local extra_files=()
    if declare -F stack_rollback_extra_files >/dev/null 2>&1; then
        mapfile -t extra_files < <(stack_rollback_extra_files)
    fi

    if [ "${STACK_SERVER_DIR_PREEXISTED:-false}" = "false" ]; then
        safe_remove_dir "$STACK_SERVER_DIR" || true
    else
        # Servidor preexistia: limpa apenas artefatos do installer.
        local scripts_to_clean=()
        # 2D-012: usar ${arr[@]+"${arr[@]}"} (idioma compat com set -u) em vez
        # de "${arr[@]:-}" que itera uma string vazia quando o array está vazio
        # (levando a basename "" e adicionar "$STACK_SERVER_DIR/" ao array,
        # que poderia apagar o diretório inteiro em rm -f).
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
# Deploy de scripts runtime + libs compartilhadas + comandos.sh.
# ---------------------------------------------------------------------------
deploy_stack_scripts() {
    print_step "Copiando scripts do modulo ${STACK_NAME^^}..."

    # Item: ${arr[@]:-} itera com string vazia se array está vazio.
    # Usamos ${arr[@]+"${arr[@]}"} para expandir para nada quando vazio (compat com set -u).
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

    # Marca runtime scripts como executáveis
    local chmod_targets=()
    for script in ${STACK_RUNTIME_SCRIPTS[@]+"${STACK_RUNTIME_SCRIPTS[@]}"}; do
        chmod_targets+=("$STACK_SERVER_DIR/$(basename "$script")")
    done
    if [ "${#chmod_targets[@]}" -gt 0 ]; then
        run_or_dry_run "Marcando scripts do ${STACK_NAME^^} como executaveis" chmod +x "${chmod_targets[@]}"
    fi

    # Permite que o stack copie assets extras (server-icon.png, etc.)
    if declare -F stack_deploy_extra_assets >/dev/null 2>&1; then
        stack_deploy_extra_assets
    fi

    # Gera comandos.sh com aliases. Stack fornece o conteúdo via callback.
    if declare -F stack_generate_aliases >/dev/null 2>&1; then
        local aliases_content
        aliases_content="$(stack_generate_aliases)"
        printf '%s\n' "$aliases_content" | write_file_or_dry_run "Gerando comandos do ${STACK_NAME^^} em $STACK_SERVER_DIR/comandos.sh" "$STACK_SERVER_DIR/comandos.sh"
        run_or_dry_run "Marcando comandos do ${STACK_NAME^^} como executavel" chmod +x "$STACK_SERVER_DIR/comandos.sh"
    fi

    if ! dry_run_enabled; then
        # SH-004: revalidar antes do chown -R (defesa em profundidade — o
        # path pode ter mudado entre create_stack_user_and_dirs e aqui).
        if validate_server_dir "$STACK_SERVER_DIR"; then
            chown -R "${STACK_USER}:${STACK_USER}" "$STACK_SERVER_DIR"
        else
            print_error "Recusa de chown -R em STACK_SERVER_DIR inválido: '$STACK_SERVER_DIR'"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Instala unit systemd usando envsubst (item S5 do plano).
#
# Substitui o sed por envsubst para eliminar risco de injection em MOTD
# e valores com caracteres especiais.
# ---------------------------------------------------------------------------
install_stack_service() {
    print_step "Instalando servico systemd do ${STACK_NAME^^}..."

    if ! command_exists envsubst; then
        print_error "envsubst nao encontrado. Instale gettext (pacman -S gettext)."
        return 1
    fi

    # Variáveis que o template pode usar via ${VAR}.
    # Garantimos defaults vazios para envsubst não falhar com -u.
    local SERVER_USER="$STACK_USER"
    local SERVER_DIR="$STACK_SERVER_DIR"
    local MEMORY_MAX_MB="${STACK_SERVICE_MEMORY_MAX_MB:-2048}"
    local SERVICE_NAME="$STACK_NAME"

    # Permite que o stack forneça variáveis extras.
    if declare -F stack_service_extra_env >/dev/null 2>&1; then
        # Callback pode export variáveis adicionais.
        stack_service_extra_env
    fi

    # envsubst lê stdin, substitui ${VAR} e escreve em stdout.
    # Usamos shell builtin readarray + envsubst com lista explícita de variáveis
    # para evitar substituir coisas demais (ex.: ${1} em scripts embutidos).
    if dry_run_enabled; then
        print_step "[DRY_RUN] Gerando unidade systemd do ${STACK_NAME^^} em /etc/systemd/system/${STACK_NAME}.service (nao sera escrita)"
        envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
            < "$STACK_SERVICE_TEMPLATE" > /dev/null
        return 0
    fi

    # 2D-026: escrever em tmpfile e mover atomicamente. Antes, envsubst
    # escrevia diretamente em /etc/systemd/system/${STACK_NAME}.service;
    # se envsubst fosse interrompido (signal) ou falhasse mid-write, o unit
    # file parcial seria carregado pelo próximo daemon-reload. Agora
    # validamos com systemd-analyze verify antes do rename.
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

    # 2D-026: opcionalmente valida com systemd-analyze verify antes de mover.
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze verify "$unit_tmp" >/dev/null 2>&1; then
            print_warning "systemd-analyze verify reportou problemas em $unit_tmp; verifique antes de prosseguir."
            # Não aborta — alguns avisos são benignos (ex.: dependências não carregadas).
        fi
    fi

    # install faz cópia atômica (open + rename) com modo 0644.
    install -m 0644 -o root -g root "$unit_tmp" "$unit_target"
    rm -f "$unit_tmp"

    systemctl daemon-reload
    systemctl enable "$STACK_NAME" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Aplica tuning de sistema compartilhado (com skip de virtualização).
# ---------------------------------------------------------------------------
apply_stack_system_tuning() {
    if dry_run_enabled; then
        print_step "[DRY_RUN] Pulando tuning de sistema compartilhado."
        return 0
    fi

    if ! is_true "${APPLY_SYSTEM_TUNING:-true}"; then
        return 0
    fi

    # Skip automático em container/VPS (item S8 do plano).
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
# Orquestra a instalação completa do stack.
# ---------------------------------------------------------------------------
run_stack_install() {
    print_step "Iniciando instalacao do stack ${STACK_NAME^^}..."

    # SH-004: fail-fast se STACK_SERVER_DIR for perigoso. Fazemos a validação
    # ANTES de instalar qualquer trap para que um path inválido não dispare
    # rollback (que faria rm -rf em path do sistema). O rollback também
    # valida via safe_remove_dir, mas falhar cedo evita confusão no log.
    if ! validate_server_dir "$STACK_SERVER_DIR"; then
        print_error "STACK_SERVER_DIR rejeitado pela validação de segurança: '$STACK_SERVER_DIR'"
        return 1
    fi

    if [ -d "$STACK_SERVER_DIR" ]; then
        STACK_SERVER_DIR_PREEXISTED=true
    else
        STACK_SERVER_DIR_PREEXISTED=false
    fi

    # Salva trap EXIT anterior (se houver) e instala o nosso.
    # No fim de run_stack_install, restauramos o trap anterior.
    # SH-009: capturamos apenas a flag booleana de existência (não o conteúdo
    # do trap) para evitar `eval` em strings capturadas de `trap -p`, que é
    # frágil com aspas aninhadas e re-avalia variáveis no momento do eval
    # (não no momento da captura). Aqui apenas registramos se havia um trap
    # anterior; o caller é responsável por re-setar explicitamente o próprio
    # trap caso precise. Referência: ShellCheck SC2294, CWE-95.
    local _had_prev_trap_exit=false
    if [ -n "$(trap -p EXIT 2>/dev/null || true)" ]; then
        _had_prev_trap_exit=true
    fi

    trap 'if [ "${STACK_INSTALL_SUCCEEDED:-false}" != "true" ]; then rollback_stack_install; fi' EXIT

    # Hook de validação específico do stack (inputs, EULA, etc.)
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

    # SH-009: limpa nosso trap EXIT explicitamente (sem eval). Se havia um
    # trap EXIT anterior, o caller deve re-setá-lo explicitamente após
    # run_stack_install retornar — não tentamos restaurar via eval de string
    # capturada (padrão frágil segundo CWE-95 e ShellCheck SC2294).
    trap - EXIT
    if [ "$_had_prev_trap_exit" = "true" ]; then
        print_warning "Trap EXIT pré-existente foi removido por run_stack_install; reconfigure explicitamente se necessário."
    fi
}
