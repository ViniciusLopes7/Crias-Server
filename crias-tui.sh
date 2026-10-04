#!/bin/bash
# crias-tui.sh
#
# Hub central TUI para o Crias-Server. Detecta qual stack está instalado e
# apresenta um menu interativo (gum) com as ações principais, sem precisar
# lembrar comandos do manager.
#
# Embedado na ISO em /usr/local/bin/crias-tui (via sync-airootfs.sh).
# Também deployado pelo install.sh em /opt/<stack>/crias-tui.sh.
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

detect_stack() {
    if [ -d /opt/minecraft-server ] && [ -f /opt/minecraft-server/mc-manager.sh ]; then
        echo "minecraft"
    elif [ -d /opt/terraria-server ] && [ -f /opt/terraria-server/tt-manager.sh ]; then
        echo "terraria"
    else
        echo ""
    fi
}

get_manager_script() {
    local stack="$1"
    if [ "$stack" = "minecraft" ]; then
        echo "/opt/minecraft-server/mc-manager.sh"
    elif [ "$stack" = "terraria" ]; then
        echo "/opt/terraria-server/tt-manager.sh"
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
    # Detecta stack
    local stack
    stack="$(detect_stack)"

    if [ -z "$stack" ]; then
        echo "${YELLOW}Nenhum stack do Crias-Server detectado.${NC}"
        echo "  /opt/minecraft-server/ ou /opt/terraria-server/ não encontrados."
        echo ""
        echo "Para instalar: sudo /opt/crias-server/install.sh"
        echo "Ou: curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash"
        exit 0
    fi

    local manager_script
    manager_script="$(get_manager_script "$stack")"
    local service
    service="$(get_service_name "$stack")"

    # Verifica se gum está disponível
    if ! command -v gum >/dev/null 2>&1; then
        echo "${YELLOW}gum não disponível. Use o manager diretamente:${NC}"
        echo "  sudo $manager_script"
        exit 1
    fi

    # Menu principal
    while true; do
        show_header "$stack" "$service"

        local choice
        choice=$(gum choose --header="Crias-Server Hub — selecione:" \
            "🎮 Servidor" \
            "📊 Monitoramento" \
            "💾 Backup" \
            "⚙️  Sistema" \
            "🚪 Sair") || break

        case "$choice" in
            "🎮 Servidor")
                local srv_choice
                srv_choice=$(gum choose --header="Servidor ($stack):" \
                    "Start" "Stop" "Restart" "Status" "Console" "Logs" "← Voltar") || continue
                case "$srv_choice" in
                    "Start") sudo "$manager_script" start ;;
                    "Stop") sudo "$manager_script" stop ;;
                    "Restart") sudo "$manager_script" restart ;;
                    "Status") sudo "$manager_script" status; read -r -p "Enter..." ;;
                    "Console") sudo "$manager_script" console ;;
                    "Logs") sudo "$manager_script" logs ;;
                    "← Voltar") continue ;;
                esac
                ;;
            "📊 Monitoramento")
                local mon_choice
                mon_choice=$(gum choose --header="Monitoramento:" \
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
                bk_choice=$(gum choose --header="Backup:" \
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
                sys_choice=$(gum choose --header="Sistema:" \
                    "Reconfigurar hardware (tier)" \
                    "Health check" \
                    "Hardware report" \
                    "← Voltar") || continue
                case "$sys_choice" in
                    "Reconfigurar hardware"*)
                        local tier_choice
                        tier_choice=$(gum choose --header="Forçar tier?" \
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
