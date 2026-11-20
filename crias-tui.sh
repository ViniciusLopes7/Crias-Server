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
                systemctl show "$service.service" --no-pager -p ActiveState -p SubState -p Result -p NRestarts -p Restart -p StartLimitBurst -p StartLimitIntervalUSec -p MemoryMax -p MemoryCurrent -p MemoryPeak -p MemorySwapMax 2>/dev/null || true
            fi
        done
    fi
    if command -v journalctl >/dev/null 2>&1; then
        echo "--- Ultimos eventos OOM (se disponiveis) ---"
        journalctl -k -b --no-pager 2>/dev/null | grep -Ei "memory cgroup out of memory|out of memory: killed process|oom-kill" | tail -n 8 || true
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

    local manager_script
    manager_script="$(get_manager_script "$stack")"
    local service
    service="$(get_service_name "$stack")"

    # Menu principal
    while true; do
        show_header "$stack" "$service"

        local choice
        choice=$(hub_choose "Crias-Server Hub — selecione:" \
            "🎮 Servidor" \
            "📊 Monitoramento" \
            "💾 Backup" \
            "⚙️  Sistema" \
            "🩺 Diagnóstico" \
            "🚪 Sair") || break

        case "$choice" in
            "🎮 Servidor")
                local srv_choice
                srv_choice=$(hub_choose "Servidor ($stack):" \
                    "Start" "Stop" "Restart" "Status" "Console" "Logs" "← Voltar") || continue
                case "$srv_choice" in
                    "Start") sudo "$manager_script" start ;;
                    "Stop") sudo "$manager_script" stop ;;
                    "Restart") sudo "$manager_script" restart ;;
                    "Status") sudo "$manager_script" status; read -r -p "Enter..." ;;
                    "Console") sudo "$manager_script" console ;;
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
