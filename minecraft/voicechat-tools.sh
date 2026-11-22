#!/usr/bin/env bash
# Simple Voice Chat server settings. Execute ONLY as Minecraft service user.
# Never restart the server, install mods or modify firewall rules.
set -euo pipefail
SERVER_DIR="${SERVER_DIR:-/opt/minecraft-server}"
CONF="$SERVER_DIR/config/voicechat/voicechat-server.properties"
GAME_PROPS="$SERVER_DIR/server.properties"

prop() {
    local file="$1" key="$2" default="$3" found
    found=""
    if [ -f "$file" ]; then
        found="$(awk -F= -v k="$key" '
            $1 ~ ("^[[:space:]]*" k "[[:space:]]*$") {
                v=substr($0,index($0,"=")+1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                last=v
            }
            END {print last}
        ' "$file")"
    fi
    printf '%s\n' "${found:-$default}"
}

check_conf() {
    if [ ! -f "$CONF" ] || [ -L "$CONF" ] || [ -L "$SERVER_DIR/config" ] || [ -L "$SERVER_DIR/config/voicechat" ]; then
        echo "[ERRO] Config de Simple Voice Chat ausente/insegura: $CONF" >&2
        echo "Verifique o mod no servidor e inicie Minecraft uma vez para gerar o arquivo." >&2
        return 1
    fi
}

status() {
    local port
    echo '=== Simple Voice Chat / Crias-Server ==='
    if [ -d "$SERVER_DIR/mods" ] && [ -n "$(find "$SERVER_DIR/mods" -maxdepth 1 -type f -iname '*voicechat*.jar' -print -quit 2>/dev/null)" ]; then
        echo 'Mod: jar detectado em mods/ (sem garantia de compatibilidade)'
    else
        echo 'Mod: jar nao encontrado em mods/'
    fi
    check_conf || return 1
    port="$(prop "$CONF" port 24454)"
    echo "Arquivo: $CONF"
    echo "Porta: $port/UDP"
    echo "Distancia: $(prop "$CONF" max_voice_distance 48) blocos"
    echo "Sussurro: $(prop "$CONF" whisper_distance 24) blocos"
    echo "voice_host: $(prop "$CONF" voice_host '<automatico>')"
    echo "bind_address: $(prop "$CONF" bind_address '<server-ip>')"
    if command -v ss >/dev/null 2>&1 && [[ "$port" =~ ^[0-9]+$ ]]; then
        if ss -H -lun | grep -Eq "[:.]$port[[:space:]]"; then
            echo "Socket: UDP $port em escuta no host"
        else
            echo "Socket: UDP $port nao identificado localmente"
        fi
    fi
    if command -v tailscale >/dev/null 2>&1; then
        echo "IP Tailscale: $(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    fi
    echo 'Escuta local NAO comprova conectividade dos jogadores. Teste /voicechat test <jogador> dentro do Minecraft.'
}

set_port() {
    local port="$1" gameport tmp
    if ! [[ "$port" =~ ^[0-9]{4,5}$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        echo '[ERRO] Porta UDP precisa ser um inteiro entre 1024 e 65535.' >&2
        return 2
    fi
    check_conf || return 1
    gameport="$(prop "$GAME_PROPS" server-port 25565)"
    if [ "$port" = "$gameport" ]; then
        echo '[ERRO] Use porta diferente da porta do Minecraft.' >&2
        return 2
    fi
    tmp="$(mktemp "$SERVER_DIR/config/voicechat/.crias-vc-XXXXXXXX")" || return 1
    (
        trap 'rm -f -- "$tmp"' EXIT
        awk -v p="$port" '
            /^[[:space:]]*port[[:space:]]*=/ {
                if (!written) {print "port="p; written=1}
                next
            }
            {print}
            END {if (!written) print "port="p}
        ' "$CONF" > "$tmp"
        chmod --reference="$CONF" "$tmp" || chmod 0600 "$tmp"
        mv -f -- "$tmp" "$CONF"
    ) || return 1
    echo "Porta ajustada para UDP $port. Minecraft nao foi reiniciado."
    echo 'Aplique no proximo restart planejado e ajuste o firewall de tailscale0.'
}

edit_conf() {
    check_conf || return 1
    if [ ! -t 0 ] || [ ! -t 1 ]; then echo '[ERRO] Editor precisa de TTY.' >&2; return 1; fi
    if ! command -v nano >/dev/null 2>&1; then echo '[ERRO] nano nao instalado.' >&2; return 1; fi
    nano "$CONF"
    echo 'Edicao encerrada. Reinicie o Minecraft quando for conveniente.'
}

network() {
    local port
    port="$(prop "$CONF" port 24454)"
    echo '=== Voice Chat sobre Tailscale ==='
    echo "Libere UDP $port apenas para a interface tailscale0:"
    echo "  iifname \"tailscale0\" udp dport $port accept"
    echo 'Não exponha essa porta na WAN nem altere SSH sem plano de recuperacao.'
    echo 'Se Minecraft conecta diretamente pelo IP Tailscale, mantenha voice_host= e bind_address= vazios.'
    echo 'O cliente também precisa ter Simple Voice Chat. Teste /voicechat test <jogador> dentro do jogo.'
    echo 'Uma porta UDP em escuta local nao comprova que os clientes conseguem usar voz.'
    echo 'Este comando NAO modifica o firewall.'
}

case "${1:-}" in
    status) [ "$#" -eq 1 ] || exit 2; status ;;
    set-port) [ "$#" -eq 2 ] || exit 2; set_port "$2" ;;
    edit) [ "$#" -eq 1 ] || exit 2; edit_conf ;;
    network) [ "$#" -eq 1 ] || exit 2; network ;;
    *) echo 'Uso: voicechat {status|set-port PORTA|edit|network}' >&2; exit 2 ;;
esac
