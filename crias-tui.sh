#!/bin/bash
# crias-tui.sh
#
# Hub central TUI para o Crias-Server. Detecta qual stack está instalado e
# apresenta um menu interativo (gum) com as ações principais, sem precisar
# lembrar comandos do manager.
#
# Disponivel em /usr/local/bin/crias-tui desde o inicio do instalador.
# --doctor funciona mesmo com instalacao parcial ou sem gum.
#
# Uso: crias-tui  (abre o menu principal)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cores
if [ -t 1 ]; then
    CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    CYAN=''; GREEN=''; YELLOW=''; NC=''
fi

# gum ja deve vir do bootstrap/install.sh. Se removido depois, o Hub
# tenta reparar o pacote em sessao interativa, sem reinstalar o jogo.
# --doctor/--help e usos sem TTY nunca fazem alteracoes no host.
hub_ensure_gum() {
    [ -t 0 ] && [ -t 1 ] || return 0
    if command -v gum >/dev/null 2>&1 && gum --version >/dev/null 2>&1; then
        return 0
    fi
    printf '%s\n' "[Hub] gum ausente ou danificado; tentando reparar o menu interativo..."
    if ! command -v pacman >/dev/null 2>&1; then
        printf '%s\n' "[AVISO] pacman indisponivel. Menu numerado continua disponivel." >&2
        return 1
    fi
    if [ "$(id -u)" -eq 0 ]; then
        if ! pacman -S --noconfirm gum; then
            printf '%s\n' "[AVISO] Falha ao instalar gum. Menu numerado continua disponivel." >&2
            return 1
        fi
    else
        if ! command -v sudo >/dev/null 2>&1; then
            printf '%s\n' "[AVISO] Sem sudo para instalar gum. Use: sudo pacman -S gum" >&2
            return 1
        fi
        if ! sudo pacman -S --noconfirm gum; then
            printf '%s\n' "[AVISO] Falha ao instalar gum. Menu numerado continua disponivel." >&2
            return 1
        fi
    fi
    if ! command -v gum >/dev/null 2>&1 || ! gum --version >/dev/null 2>&1; then
        printf '%s\n' "[AVISO] gum ainda nao responde. Verifique o pacote no Arch." >&2
        return 1
    fi
    printf '%s\n' "[Hub] gum pronto. Use setas e Enter para navegar."
}

# Os chamadores usam choice=$(hub_choose ...). Em uma substituicao de comando,
# stdout vira PIPE, portanto [ -t 1 ] sempre falha AQUI, mesmo via SSH/TTY.
# Gum desenha o menu em stderr (terminal) e escreve a escolha em stdout.
# Testamos stdin+stderr como TTY para manter as setas funcionais.
hub_gum_interactive() {
    [ -t 0 ] && [ -t 2 ] && [ "${TERM:-}" != "dumb" ] &&
        command -v gum >/dev/null 2>&1 && gum --version >/dev/null 2>&1
}

hub_choose() {
    local header="$1" picked opt i=1
    shift
    if hub_gum_interactive; then
        gum choose --header="$header  ·  ↑/↓ mover  Enter selecionar  Esc voltar" \
            --cursor="❯ " --height="$#" "$@"
        return $?
    fi
    # Apenas ambientes realmente sem terminal interativo/gum usam numeros.
    # Nunca prometer setas enquanto o fallback estiver ativo.
    printf "%s (modo numerado)\n" "$header" >&2
    for opt in "$@"; do printf "  %s) %s\n" "$i" "$opt" >&2; i=$((i + 1)); done
    printf "Escolha (numero ou nome, Enter para voltar): " >&2
    IFS= read -r picked || return 1
    [ -n "$picked" ] || return 1
    if [[ "$picked" =~ ^[0-9]+$ ]] && [ "$picked" -ge 1 ] && [ "$picked" -le "$#" ]; then
        i=1
        for opt in "$@"; do
            if [ "$i" -eq "$picked" ]; then printf "%s\n" "$opt"; return 0; fi
            i=$((i + 1))
        done
    fi
    for opt in "$@"; do
        if [ "$opt" = "$picked" ]; then printf "%s\n" "$opt"; return 0; fi
    done
    return 1
}

# Diagnostico somente leitura para reparo e memoria.
show_diagnostics() {
    local service
    echo "=== Diagnostico do Crias-Server (somente leitura) ==="
    if [ -f /opt/crias-server/install.sh ]; then
        printf "Instalador: %s\n" "$(readlink -f /opt/crias-server)"
    else
        echo "Instalador ausente em /opt/crias-server"
    fi
    if [ -x /usr/local/bin/crias-tui ]; then
        echo "Hub: /usr/local/bin/crias-tui"
    else
        echo "Hub: ainda nao instalado"
    fi
    if command -v free >/dev/null 2>&1; then echo "--- RAM/swap ---"; free -h || true; fi
    if command -v systemctl >/dev/null 2>&1; then
        for service in minecraft terraria; do
            if systemctl list-unit-files "$service.service" --no-legend 2>/dev/null | grep -Fq "$service.service"; then
                echo "--- $service: status e limites ---"
                systemctl show "$service.service" --no-pager -p ActiveState -p SubState -p Result -p NRestarts -p Restart -p OOMPolicy -p StartLimitBurst -p StartLimitIntervalUSec -p MemoryMax -p EffectiveMemoryMax -p MemoryHigh -p MemoryCurrent -p MemoryPeak -p MemorySwapMax 2>/dev/null || true
                if [ "$service" = minecraft ]; then
                    local cg_unit
                    cg_unit="$(systemctl show -p ControlGroup --value minecraft.service 2>/dev/null || true)"
                    if [[ "$cg_unit" == /* && "$cg_unit" != *".."* && -r "/sys/fs/cgroup${cg_unit}/memory.events" ]]; then
                        echo "--- minecraft: contadores cgroup OOM ---"
                        grep -E "^(high|max|oom|oom_kill|oom_group_kill) " "/sys/fs/cgroup${cg_unit}/memory.events" || true
                    fi
                    # Nunca use source do runtime.env: o servidor pode editar
                    # esse arquivo, e o doctor pode ser executado como root.
                    if [ -r /opt/minecraft-server/runtime.env ]; then
                        local runtime_xmx
                        runtime_xmx="$(sed -n 's/^MAX_RAM="\([0-9][0-9]*\)M"$/\1/p' /opt/minecraft-server/runtime.env | head -n 1)"
                        if [[ "$runtime_xmx" =~ ^[0-9]+$ ]]; then
                            echo "Heap Java configurado (-Xmx): ${runtime_xmx} MB"
                        fi
                    fi
                fi
            fi
        done
    fi
    if command -v journalctl >/dev/null 2>&1; then
        echo "--- Eventos OOM historicos deste boot (nao necessariamente atuais) ---"
        journalctl -k -b -o short-iso --no-pager 2>/dev/null | grep -Ei "memory cgroup out of memory|out of memory: killed process|oom-kill" | tail -n 8 || true
        echo "--- Resultado e eventos recentes do servico Minecraft ---"
        journalctl -u minecraft.service -b -n 30 -o short-iso --no-pager 2>/dev/null | grep -Ei "oom|killed|memory|Main process exited|Failed with result" | tail -n 12 || true
    fi
    echo "--- Acesso remoto ---"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active sshd.service 2>/dev/null || true
        systemctl is-active tailscaled.service 2>/dev/null || true
    fi
    if command -v tailscale >/dev/null 2>&1; then
        tailscale ip -4 2>/dev/null || true
    fi
    echo "Logs: sudo journalctl -u minecraft -n 80 --no-pager"
    echo "Instalador: sudo /opt/crias-server/install.sh"
}

# (AUDIT-A P2-4) Deteccao via systemd units + manager no libexec: as copias
# em /opt/<stack>-server/ foram REMOVIDAS pela migracao EXP-34 (eram
# gravaveis pelo usuario do jogo) — o TUI nao detectava mais nenhum stack.
detect_stack() {
    local manager_dir="/usr/local/libexec/crias"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files 2>/dev/null | grep -Fq "minecraft.service"; then
            echo "minecraft"
            return 0
        fi
        if systemctl list-unit-files 2>/dev/null | grep -Fq "terraria.service"; then
            echo "terraria"
            return 0
        fi
    fi
    # Fallback sem systemd: manager presente no libexec.
    if [ -x "$manager_dir/mc-manager.sh" ]; then
        echo "minecraft"
    elif [ -x "$manager_dir/tt-manager.sh" ]; then
        echo "terraria"
    else
        echo ""
    fi
}

get_manager_script() {
    local stack="$1"
    if [ "$stack" = "minecraft" ]; then
        echo "/usr/local/libexec/crias/mc-manager.sh"
    elif [ "$stack" = "terraria" ]; then
        echo "/usr/local/libexec/crias/tt-manager.sh"
    else
        echo ""
    fi
}

get_service_name() {
    local stack="$1"
    if [ "$stack" = "minecraft" ]; then
        echo "minecraft"
    else
        echo "terraria"
    fi
}

show_header() {
    local stack="$1" service="$2" status="parado"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        status="rodando"
    fi
    local title="Crias-Server  |  Painel de controle"
    local detail="Jogo: $stack    Estado: $status"
    echo ""
    # Borda completa, largura fixa e sem truncamentos por sequencias ANSI.
    printf '%b\n' "${GREEN}╭────────────────────────────────────────────╮${NC}"
    printf '%b│%b %-42s %b│%b\n' "$GREEN" "$NC" "$title" "$GREEN" "$NC"
    printf '%b\n' "${GREEN}├────────────────────────────────────────────┤${NC}"
    printf '%b│%b %-42s %b│%b\n' "$GREEN" "$NC" "$detail" "$GREEN" "$NC"
    printf '%b\n' "${GREEN}╰────────────────────────────────────────────╯${NC}"
    echo ""
}

# UI controller only: the manager owns memory validation, persistence and systemd.
# Return to the main menu on cancel/error; do not restart the game implicitly.
hub_minecraft_memory_menu() {
    local manager_script="$1"
    local ram_choice ram_amount ram_growth ram_mode
    ram_choice=$(hub_choose "Heap Java (Minecraft deve estar parado para alterar):" \
        "Ver configuracao atual" \
        "Xms igual a Xmx (limite seguro automatico)" \
        "Definir Xmx manualmente" \
        "Voltar para tuning automatico" \
        "← Voltar") || return 0
    case "$ram_choice" in
        "Ver configuracao atual")
            sudo "$manager_script" memory status || true
            read -r -p "Enter para voltar..." _ || true
            ;;
        "Xms igual a Xmx"*)
            echo "Requer Minecraft parado. Xms sera igual ao Xmx seguro calculado pelo host."
            ram_mode=$(hub_choose "Confirmar heap fixo? Sem reiniciar o servidor." \
                "Confirmar heap fixo" "Cancelar") || return 0
            if [ "$ram_mode" = "Confirmar heap fixo" ]; then
                sudo "$manager_script" memory fixed || true
                read -r -p "Enter para voltar..." _ || true
            fi
            ;;
        "Definir Xmx manualmente")
            echo "Valor em MiB; teto calculado pelo hardware. Minecraft deve estar parado."
            if hub_gum_interactive; then
                ram_amount=$(gum input --header="Heap maximo em MiB (ex.: 4096):" --placeholder="4096") || return 0
            else
                read -r -p "Heap maximo (MiB): " ram_amount || return 0
            fi
            [[ "$ram_amount" =~ ^[1-9][0-9]{2,5}$ ]] || { echo "[ERRO] Informe um inteiro em MiB."; read -r -p "Enter..." _ || true; return 0; }
            ram_growth=$(hub_choose "Modo do heap:" \
                "Fixo: Xms = Xmx (consome mais RAM)" \
                "Adaptativo: Xms menor que Xmx" "← Voltar") || return 0
            case "$ram_growth" in
                "Fixo:"*) ram_mode=fixed ;;
                "Adaptativo:"*) ram_mode=dynamic ;;
                *) return 0 ;;
            esac
            sudo "$manager_script" memory set "$ram_amount" "$ram_mode" || true
            read -r -p "Enter para voltar..." _ || true
            ;;
        "Voltar para tuning automatico")
            ram_mode=$(hub_choose "Restaurar a politica automatica Xms/Xmx?" \
                "Restaurar automatico" "Cancelar") || return 0
            if [ "$ram_mode" = "Restaurar automatico" ]; then
                sudo "$manager_script" memory auto || true
                read -r -p "Enter para voltar..." _ || true
            fi
            ;;
    esac
    return 0
}

# UI-only: manager scripts enforce directory boundaries and game-user access.
# Cancellations return to the main menu without changing files or services.
hub_files_menu() {
    local stack="$1" manager_script="$2"
    local files_choice files_area
    files_choice=$(hub_choose "Arquivos do servidor ($stack):" \
        "Pasta principal do servidor" \
        "Mundo atual" \
        "Mods do servidor" \
        "Configuracoes (config)" \
        "Backups locais" \
        "Logs locais" \
        "Instalar gerenciador de arquivos" \
        "← Voltar") || return 0
    files_area=""
    case "$files_choice" in
        "Pasta principal"*) files_area="root" ;;
        "Mods do servidor") files_area="mods" ;;
        "Configuracoes"*) files_area="config" ;;
        "Mundo atual") files_area="world" ;;
        "Backups locais") files_area="backups" ;;
        "Logs locais") files_area="logs" ;;
        "Instalar gerenciador"*)
            local confirm_install
            confirm_install=$(hub_choose "Instalar pacote 'mc' do repositorio oficial Arch?" \
                "Sim, instalar" "Cancelar") || return 0
            if [ "$confirm_install" = "Sim, instalar" ]; then
                sudo "$manager_script" setup-files || true
                read -r -p "Enter para voltar..." _ || true
            fi
            ;;
        "← Voltar") return 0 ;;
    esac
    if [ -n "$files_area" ]; then
        # Abre direto na pasta escolhida; o manager executa o mc
        # como usuario do jogo, jamais como root.
        if ! sudo "$manager_script" files "$files_area"; then
            read -r -p "Enter para voltar..." _ || true
        fi
    fi
    return 0
}

# UI controller only: Voice Chat validation and persistence remain with the manager.
# Keep the Minecraft-only guard in main(); cancelled operations do nothing.
hub_minecraft_voicechat_menu() {
    local manager_script="$1"
    local vc_choice
    vc_choice=$(hub_choose "Simple Voice Chat — Minecraft" \
        "Status e diagnostico" \
        "Editar configuracao" \
        "Alterar porta UDP" \
        "Ajuda Tailscale / firewall" \
        "← Voltar") || return 0
    case "$vc_choice" in
        "Status e diagnostico")
            sudo "$manager_script" voicechat status || true
            read -r -p "Enter para voltar..." _ || true
            ;;
        "Alterar porta UDP")
            local vc_port
            if command -v gum >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
                vc_port=$(gum input --header="Porta UDP do Voice Chat (1024-65535):" --placeholder="24454") || return 0
            else
                printf "Porta UDP do Voice Chat (1024-65535; Enter cancela): "
                IFS= read -r vc_port || return 0
            fi
            [ -n "$vc_port" ] || return 0
            sudo "$manager_script" voicechat set-port "$vc_port" || true
            read -r -p "Enter para voltar..." _ || true
            ;;
        "Editar configuracao")
            sudo "$manager_script" voicechat edit || true
            ;;
        "Ajuda Tailscale / firewall")
            sudo "$manager_script" voicechat network || true
            read -r -p "Enter para voltar..." _ || true
            ;;
        "← Voltar") return 0 ;;
    esac
    return 0
}

# UI only: manager scripts launch monitoring tools with their existing privileges.
# Returning from this controller resumes the unchanged main menu.
hub_monitoring_menu() {
    local manager_script="$1"
    local mon_choice
    mon_choice=$(hub_choose "Monitoramento:" \
        "btop (CPU/RAM/processos)" \
        "ncdu (uso de disco)" \
        "← Voltar") || return 0
    case "$mon_choice" in
        "btop"*) sudo "$manager_script" monitor cpu ;;
        "ncdu"*) sudo "$manager_script" monitor disk ;;
        "← Voltar") return 0 ;;
    esac
    return 0
}

main() {
    case "${1:-}" in
        --doctor|doctor|diagnose) show_diagnostics; return 0 ;;
        --help|-h) echo "Uso: crias-tui [--doctor|--help]"; return 0 ;;
        "") ;;
        *) echo "Opcao desconhecida: $1" >&2; return 2 ;;
    esac

    # Detecta stack
    local stack
    stack="$(detect_stack)"

    if [ -z "$stack" ]; then
        echo "${YELLOW}Nenhum stack do Crias-Server detectado.${NC}"
        echo "  Nenhuma unit/manager foi localizada. A instalacao pode estar incompleta."
        show_diagnostics
        return 0
    fi

    # Em TTY, recuperar o menu por setas se o gum tiver sido removido.
    hub_ensure_gum || true

    local manager_script
    manager_script="$(get_manager_script "$stack")"
    local service
    service="$(get_service_name "$stack")"

    # Menu principal
    while true; do
        show_header "$stack" "$service"

        local choice
        if [ "$stack" = "minecraft" ]; then
            choice=$(hub_choose "Menu principal — Minecraft" \
                "🎮 Servidor" \
                "💾 Backup" \
                "📁 Arquivos" \
                "🎙️ Voice Chat" \
                "📊 Monitoramento" \
                "🔄 Atualizações" \
                "⚙️  Sistema" \
                "🩺 Diagnóstico" \
                "🚪 Sair") || break
        else
            choice=$(hub_choose "Menu principal — Terraria" \
                "🎮 Servidor" \
                "💾 Backup" \
                "📁 Arquivos" \
                "📊 Monitoramento" \
                "🔄 Atualizações" \
                "⚙️  Sistema" \
                "🩺 Diagnóstico" \
                "🚪 Sair") || break
        fi

        case "$choice" in
            "🎮 Servidor")
                local srv_choice
                if [ "$stack" = "minecraft" ]; then
                    srv_choice=$(hub_choose "Servidor — Minecraft" \
                        "Status do servidor" "Console SSH (estavel)" "Progresso Chunky (ao vivo)" \
                        "Logs do servidor" "Memoria Java (Xms/Xmx)" \
                        "Iniciar servidor" "Reiniciar servidor" "Parar servidor" \
                        "Console em tela cheia (avancado)" "Ajuda: Chunky" \
                        "Configurar console RCON" "← Voltar") || continue
                else
                    srv_choice=$(hub_choose "Servidor — Terraria" \
                        "Status do servidor" "Console interativo" "Logs do servidor" \
                        "Iniciar servidor" "Reiniciar servidor" "Parar servidor" "← Voltar") || continue
                fi
                case "$srv_choice" in
                    "Iniciar servidor") sudo "$manager_script" start ;;
                    "Parar servidor") sudo "$manager_script" stop ;;
                    "Reiniciar servidor") sudo "$manager_script" restart ;;
                    "Status do servidor") sudo "$manager_script" status || true; read -r -p "Enter para voltar..." _ || true ;;
                    "Console SSH (estavel)"|"Console interativo")
                        if ! sudo "$manager_script" console; then
                            echo "[Hub] Console encerrado com erro. Verifique Servidor → Logs ou Diagnostico."
                            read -r -p "Enter para voltar..." _ || true
                        fi
                        ;;
                    "Console em tela cheia (avancado)")
                        if ! sudo "$manager_script" console --tui; then
                            echo "[Hub] Sessao RCON encerrada. Use Console SSH para evitar conexoes persistentes."
                            read -r -p "Enter para voltar..." _ || true
                        fi
                        ;;
                    "Progresso Chunky (ao vivo)")
                        local chunk_interval
                        chunk_interval=$(hub_choose "Atualizar progresso do Chunky a cada:" \
                            "10 segundos (recomendado)" "5 segundos" "30 segundos" "60 segundos" "← Voltar") || continue
                        case "$chunk_interval" in
                            "5 segundos") chunk_interval=5 ;;
                            "10 segundos"*) chunk_interval=10 ;;
                            "30 segundos") chunk_interval=30 ;;
                            "60 segundos") chunk_interval=60 ;;
                            *) continue ;;
                        esac
                        sudo "$manager_script" chunky watch "$chunk_interval" || true
                        ;;
                    "Memoria Java (Xms/Xmx)")
                        hub_minecraft_memory_menu "$manager_script"
                        ;;
                    "Ajuda: Chunky")
                        cat <<'CHUNKY_HELP'
=== Chunky: pre-geracao segura ===
1. Faça um backup do mundo antes de iniciar.
2. Abra Console SSH (estavel) e digite um comando por vez:
   chunky world minecraft:overworld
   chunky shape square
   chunky center 0 0
   chunky radius 1500
   chunky selection
   chunky start
3. Atualizacoes automaticas no log: chunky quiet 10
   Ou abra Servidor -> Progresso Chunky (ao vivo).
   Consultar manualmente: chunky progress
   Pausar:      chunky pause
   Retomar:     chunky continue
4. Digite sair para deixar o console. O Chunky continua no
   servidor enquanto o Minecraft estiver rodando.
Obs.: o identificador da dimensao varia conforme a versao.
      Se world falhar, consulte chunky world e suas sugestoes.
      Comece pequeno; acompanhe o uso de RAM e disco.
CHUNKY_HELP
                        read -r -p "Enter para voltar..." _ || true
                        ;;
                    "Configurar console RCON")
                        sudo "$manager_script" setup-console || true
                        read -r -p "Enter para voltar..." _ || true
                        ;;
                    "Logs do servidor")
                        if [ "$stack" = "minecraft" ]; then
                            local log_choice
                            log_choice=$(hub_choose "Logs do Minecraft:" \
                                "Recentes (150 linhas)" \
                                "Avisos e erros" \
                                "Boot atual" \
                                "Acompanhar ao vivo" \
                                "← Voltar") || continue
                            case "$log_choice" in
                                "Recentes"*) sudo "$manager_script" logs recent ;;
                                "Avisos"*) sudo "$manager_script" logs alerts ;;
                                "Boot atual") sudo "$manager_script" logs boot ;;
                                "Acompanhar"*) sudo "$manager_script" logs follow ;;
                                "← Voltar") continue ;;
                            esac
                            read -r -p "Enter para voltar..." _ || true
                        else
                            sudo "$manager_script" logs
                        fi
                        ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "📁 Arquivos")
                hub_files_menu "$stack" "$manager_script"
                ;;
            "🎙️ Voice Chat")
                if [ "$stack" != "minecraft" ]; then continue; fi
                hub_minecraft_voicechat_menu "$manager_script"
                ;;
            "📊 Monitoramento")
                hub_monitoring_menu "$manager_script"
                ;;
            "🔄 Atualizações")
                local update_choice updater
                updater="/usr/local/bin/crias-update"
                if [ ! -x "$updater" ]; then
                    echo "[ERRO] Atualizador indisponivel. Atualize as ferramentas do Hub pela release mais recente."
                    read -r -p "Enter para voltar..." _ || true
                    continue
                fi
                update_choice=$(hub_choose "Atualizacoes (separadas do modpack e do mundo):" \
                    "Verificar release Crias-Server" \
                    "Atualizar Hub e ferramentas Crias-Server" \
                    "Verificar pacotes Arch" \
                    "Atualizar pacotes Arch (manutencao)" \
                    "← Voltar") || continue
                case "$update_choice" in
                    "Verificar release"*)
                        "$updater" check || true
                        read -r -p "Enter para voltar..." _ || true
                        ;;
                    "Atualizar Hub"*)
                        local update_confirm
                        update_confirm=$(hub_choose "Confirmar update SOMENTE do Hub/scripts? Minecraft/Terraria nao reiniciam." \
                            "Aplicar atualizacao Crias-Server" "Cancelar") || continue
                        if [ "$update_confirm" = "Aplicar atualizacao Crias-Server" ]; then
                            sudo "$updater" apply || true
                            read -r -p "Enter para voltar..." _ || true
                        fi
                        ;;
                    "Verificar pacotes Arch")
                        "$updater" arch-check || true
                        read -r -p "Enter para voltar..." _ || true
                        ;;
                    "Atualizar pacotes Arch"*)
                        local arch_confirm
                        arch_confirm=$(hub_choose "Atualizar Arch requer jogos PARADOS e confirmacao digitada. Continuar?" \
                            "Iniciar verificacao de manutencao" "Cancelar") || continue
                        if [ "$arch_confirm" = "Iniciar verificacao de manutencao" ]; then
                            sudo "$updater" arch-apply || true
                            read -r -p "Enter para voltar..." _ || true
                        fi
                        ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "💾 Backup")
                local bk_choice
                bk_choice=$(hub_choose "Backups do servidor" \
                    "Backup agora" \
                    "Configurar backups automaticos" \
                    "← Voltar") || continue
                case "$bk_choice" in
                    "Backup agora") sudo "$manager_script" backup ;;
                    "Configurar backups automaticos") sudo "$manager_script" setup-cron ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "⚙️  Sistema")
                local sys_choice
                sys_choice=$(hub_choose "Sistema:" \
                    "Reconfigurar hardware (tier)" \
                    "Health check" \
                    "Hardware report" \
                    "← Voltar") || continue
                case "$sys_choice" in
                    "Reconfigurar hardware"*)
                        local tier_choice
                        tier_choice=$(hub_choose "Forçar tier?" \
                            "Auto" "LOW" "MID" "HIGH" "← Voltar") || continue
                        case "$tier_choice" in
                            "Auto") sudo "$manager_script" reconfigure-hardware ;;
                            "LOW"|"MID"|"HIGH") sudo "$manager_script" reconfigure-hardware "$tier_choice" ;;
                            "← Voltar") continue ;;
                        esac
                        ;;
                    "Health check"*)
                        sudo "$manager_script" health; read -r -p "Enter..." ;;
                    "Hardware report"*)
                        sudo "$manager_script" hardware-report; read -r -p "Enter..." ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "🩺 Diagnóstico")
                show_diagnostics
                read -r -p "Enter para voltar..." _ || true
                ;;
            "🚪 Sair")
                break
                ;;
        esac
    done

    echo ""
    printf '%b\n' "${GREEN}Crias-Server Hub encerrado.${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
