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

# Menu numerado se gum nao estiver presente; mantem TUI acessivel.
hub_choose() {
    local header="$1" picked opt i=1
    shift
    if command -v gum >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
        gum choose --header="$header" "$@"
        return $?
    fi
    printf "%s\n" "$header" >&2
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
    local stack="$1"
    local service="$2"
    local status="parado"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        status="rodando"
    fi
    echo ""
    printf "${GREEN}╔══════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║        Crias-Server Hub                ${NC}  ${NC}\n"
    printf "${GREEN}╠══════════════════════════════════════════╣${NC}\n"
    printf "${GREEN}║  Stack: %-10s  Status: %-10s   ${NC}  ${NC}\n" "$stack" "$status"
    printf "${GREEN}╚══════════════════════════════════════════╝${NC}\n"
    echo ""
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
            choice=$(hub_choose "Crias-Server Hub (↑/↓ + Enter para navegar):" \
                "🎮 Servidor" \
                "📁 Arquivos" \
                "🎙️ Voice Chat" \
                "📊 Monitoramento" \
                "💾 Backup" \
                "⚙️  Sistema" \
                "🩺 Diagnóstico" \
                "🚪 Sair") || break
        else
            choice=$(hub_choose "Crias-Server Hub (↑/↓ + Enter para navegar):" \
                "🎮 Servidor" \
                "📁 Arquivos" \
                "📊 Monitoramento" \
                "💾 Backup" \
                "⚙️  Sistema" \
                "🩺 Diagnóstico" \
                "🚪 Sair") || break
        fi

        case "$choice" in
            "🎮 Servidor")
                local srv_choice
                if [ "$stack" = "minecraft" ]; then
                    srv_choice=$(hub_choose "Servidor ($stack):" \
                        "Start" "Stop" "Restart" "Status" "Console" "Configurar console RCON" "Logs" "← Voltar") || continue
                else
                    srv_choice=$(hub_choose "Servidor ($stack):" \
                        "Start" "Stop" "Restart" "Status" "Console" "Logs" "← Voltar") || continue
                fi
                case "$srv_choice" in
                    "Start") sudo "$manager_script" start ;;
                    "Stop") sudo "$manager_script" stop ;;
                    "Restart") sudo "$manager_script" restart ;;
                    "Status") sudo "$manager_script" status; read -r -p "Enter..." ;;
                    "Console") sudo "$manager_script" console ;;
                    "Configurar console RCON")
                        sudo "$manager_script" setup-console || true
                        read -r -p "Enter para voltar..." _ || true
                        ;;
                    "Logs")
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
                local files_choice
                files_choice=$(hub_choose "Arquivos do servidor ($stack):" \
                    "Abrir gerenciador de arquivos (Midnight Commander)" \
                    "Instalar gerenciador de arquivos" \
                    "← Voltar") || continue
                case "$files_choice" in
                    "Abrir gerenciador"*)
                        # O manager abre mc como usuario do jogo, nunca como root.
                        sudo "$manager_script" files || true
                        ;;
                    "Instalar gerenciador"*)
                        local confirm_install
                        confirm_install=$(hub_choose "Instalar pacote 'mc' do repositorio oficial Arch?" \
                            "Sim, instalar" "Cancelar") || continue
                        if [ "$confirm_install" = "Sim, instalar" ]; then
                            sudo "$manager_script" setup-files || true
                            read -r -p "Enter para voltar..." _ || true
                        fi
                        ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "🎙️ Voice Chat")
                if [ "$stack" != "minecraft" ]; then continue; fi
                local vc_choice
                vc_choice=$(hub_choose "Simple Voice Chat (Minecraft):" \
                    "Status e diagnostico" \
                    "Alterar porta UDP" \
                    "Editar configuracao" \
                    "Ajuda Tailscale / firewall" \
                    "← Voltar") || continue
                case "$vc_choice" in
                    "Status e diagnostico")
                        sudo "$manager_script" voicechat status || true
                        read -r -p "Enter para voltar..." _ || true
                        ;;
                    "Alterar porta UDP")
                        local vc_port
                        if command -v gum >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
                            vc_port=$(gum input --header="Porta UDP do Voice Chat (1024-65535):" --placeholder="24454") || continue
                        else
                            printf "Porta UDP do Voice Chat (1024-65535; Enter cancela): "
                            IFS= read -r vc_port || continue
                        fi
                        [ -n "$vc_port" ] || continue
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
                    "← Voltar") continue ;;
                esac
                ;;
            "📊 Monitoramento")
                local mon_choice
                mon_choice=$(hub_choose "Monitoramento:" \
                    "btop (CPU/RAM/processos)" \
                    "ncdu (uso de disco)" \
                    "← Voltar") || continue
                case "$mon_choice" in
                    "btop"*) sudo "$manager_script" monitor cpu ;;
                    "ncdu"*) sudo "$manager_script" monitor disk ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "💾 Backup")
                local bk_choice
                bk_choice=$(hub_choose "Backup:" \
                    "Backup agora" \
                    "Configurar timer systemd" \
                    "← Voltar") || continue
                case "$bk_choice" in
                    "Backup agora") sudo "$manager_script" backup ;;
                    "Configurar timer systemd") sudo "$manager_script" setup-cron ;;
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
    echo "${GREEN}Crias-Server Hub encerrado.${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
