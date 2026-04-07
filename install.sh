#!/bin/bash

# ============================================
# Minecraft Server Auto-Installer
# Adrenaline Modpack + Chunky + QoL + Tailscale
# Para: Arch Linux Minimal | i3-6006U | 4GB RAM
# ============================================

set -eo pipefail  # Sair em caso de erro e falhas no pipe

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Variáveis Default
MINECRAFT_USER="minecraft"
SERVER_DIR="/opt/minecraft-server"
SERVER_PORT=25565
SERVER_RAM="2560M"
ONLINE_MODE="false"

MINECRAFT_VERSION="1.21.11"
LOADER_TYPE="fabric"

INSTALL_MODPACK="true"
ADRENALINE_VERSION=""
INSTALL_QOL_MODS="true"
INSTALL_TAILSCALE="true"

VIEW_DISTANCE=6
SIMULATION_DISTANCE=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carregar config.env se existir
if [ -f "$SCRIPT_DIR/config.env" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/config.env"
fi

# ============================================
# PROMPTS INTERATIVOS
# ============================================

ask_confirm() {
    local prompt="$1"
    local default_ans="${2:-Y}"
    local ans
    local prompt_text

    if [ "${default_ans^^}" == "Y" ]; then
        prompt_text="$prompt [Y/n]: "
    else
        prompt_text="$prompt [y/N]: "
    fi

    read -r -p "$prompt_text" ans
    if [ -z "$ans" ]; then
        ans="$default_ans"
    fi

    if [[ "${ans^^}" == "Y" || "${ans^^}" == "YES" || "${ans^^}" == "S" || "${ans^^}" == "SIM" ]]; then
        return 0
    else
        return 1
    fi
}

ask_value() {
    local prompt="$1"
    local default_val="$2"
    local var_name="$3"
    local ans
    
    read -r -p "$prompt [$default_val]: " ans
    if [ -z "$ans" ]; then
        printf -v "$var_name" '%s' "$default_val"
    else
        printf -v "$var_name" '%s' "$ans"
    fi
}

validate_java_ram_value() {
    local value="${1^^}"
    [[ "$value" =~ ^[0-9]+[MG]$ ]]
}

# ============================================
# FUNÇÕES
# ============================================

print_header() {
    echo "=========================================="
    echo "  Minecraft Server Auto-Installer"
    echo "  Adrenaline + Chunky + QoL + Tailscale"
    echo "=========================================="
    echo ""
}

print_step() {
    echo -e "${BLUE}[PASSO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCESSO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Este script precisa ser executado como root (sudo)"
        exit 1
    fi
}

check_arch() {
    if [ ! -f "/etc/arch-release" ]; then
        print_warning "Este script foi projetado para Arch Linux"
        read -r -p "Deseja continuar mesmo assim? (s/N): " -n 1
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            exit 1
        fi
    fi
}

install_dependencies() {
    print_step "Atualizando sistema..."
    pacman -Syu --noconfirm
    
    print_step "Instalando dependências..."
    pacman -S --needed --noconfirm \
        jdk21-openjdk \
        screen \
        htop \
        iotop \
        nano \
        curl \
        wget \
        tar \
        gzip \
        base-devel \
        zram-generator \
        cpupower \
        lm_sensors \
        openssh \
        jq
    
    print_step "Habilitando e iniciando OpenSSH (sshd)..."
    systemctl enable --now sshd
    
    print_success "Dependências instaladas"
}

create_user() {
    print_step "Criando usuário minecraft..."
    
    if id "$MINECRAFT_USER" &>/dev/null; then
        print_warning "Usuário ${MINECRAFT_USER} já existe"
    else
        useradd -m -s /bin/bash "$MINECRAFT_USER"
        print_success "Usuário ${MINECRAFT_USER} criado"
    fi
    
    # Criar diretório do servidor
    mkdir -p "$SERVER_DIR"
    chown "${MINECRAFT_USER}:${MINECRAFT_USER}" "$SERVER_DIR"
}

install_mrpack_install() {
    print_step "Instalando mrpack-install..."
    
    local mrpack_url
    mrpack_url=$(curl -s https://api.github.com/repos/nothub/mrpack-install/releases/latest | jq -r '.assets[] | select(.name=="mrpack-install-linux") | .browser_download_url')
    
    if [ -z "$mrpack_url" ] || [ "$mrpack_url" == "null" ]; then
        mrpack_url="https://github.com/nothub/mrpack-install/releases/latest/download/mrpack-install-linux"
    fi
    
    curl -fsSL -o "/tmp/mrpack-install" "$mrpack_url"
    install -m 755 "/tmp/mrpack-install" "/usr/local/bin/mrpack-install"
    
    print_success "mrpack-install instalado"
}

install_server_base() {
    cd "$SERVER_DIR" || exit 1
    
    if [ "$INSTALL_MODPACK" == "true" ]; then
        print_step "Instalando Modpack Adrenaline..."
        if [ -z "$ADRENALINE_VERSION" ]; then
            mrpack-install adrenaline --server-dir "$SERVER_DIR" --server-file server.jar
        else
            mrpack-install adrenaline "$ADRENALINE_VERSION" --server-dir "$SERVER_DIR" --server-file server.jar
        fi
        print_success "Adrenaline instalado"
    else
        print_step "Instalando $LOADER_TYPE versão $MINECRAFT_VERSION..."
        mrpack-install "$LOADER_TYPE" "$MINECRAFT_VERSION" --server-dir "$SERVER_DIR" --server-file server.jar
        print_success "$LOADER_TYPE $MINECRAFT_VERSION instalado"
    fi
    
    echo "eula=true" > "$SERVER_DIR/eula.txt"
}

install_mods_qol() {
    print_step "Instalando mods de Qualidade de Vida para MC $MINECRAFT_VERSION..."
    
    cd "$SERVER_DIR" || exit 1
    mkdir -p mods
    
    download_mod() {
        local name=$1
        local slug=$2
        print_step "Buscando $name..."
        
        local api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$LOADER_TYPE%22%5D&game_versions=%5B%22$MINECRAFT_VERSION%22%5D"
        local modrinth_url
        modrinth_url=$(curl -s "$api_url" | jq -r '.[0].files[0].url // empty')
        
        if [ -n "$modrinth_url" ] && [ "$modrinth_url" != "null" ]; then
            curl -fsSL -o "$SERVER_DIR/mods/${name}.jar" "$modrinth_url"
            print_success "${name}.jar instalado."
        else
            print_warning "Nenhuma versão exata do $name para MC $MINECRAFT_VERSION ($LOADER_TYPE). Instalando latest..."
            local fallback_url
            fallback_url=$(curl -s "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$LOADER_TYPE%22%5D" | jq -r '.[0].files[0].url // empty')
            if [ -n "$fallback_url" ]; then
                curl -fsSL -o "$SERVER_DIR/mods/${name}.jar" "$fallback_url"
                print_success "${name}.jar (latest) instalado."
            else
                print_error "Falha ao baixar $name. Mod pode não existir para $LOADER_TYPE."
            fi
        fi
    }

    # Baixando slugs padronizados do Modrinth
    download_mod "chunky" "chunky"
    
    # Alguns mods QoL são exclusivos do Fabric.
    if [ "$LOADER_TYPE" == "fabric" ] || [ "$LOADER_TYPE" == "quilt" ]; then
        download_mod "essential-commands" "essential-commands"
        download_mod "universal-graves" "universal-graves"
        download_mod "tabtps" "tabtps"
        download_mod "styled-chat" "styled-chat"
        download_mod "polymer" "polymer"
        download_mod "placeholder-api" "placeholder-api"
    else
        print_warning "Mods QoL focados em Fabric/Quilt pulados pois o loader escolhido é $LOADER_TYPE."
    fi
    
    chown -R "${MINECRAFT_USER}:${MINECRAFT_USER}" "$SERVER_DIR/mods"
    print_success "Mods instalados!"
}

install_tailscale() {
    print_step "Instalando Tailscale..."
    
    if command -v tailscale &> /dev/null; then
        print_warning "Tailscale já está instalado"
        tailscale version
        return 0
    fi
    
    pacman -S --needed --noconfirm tailscale
    
    systemctl enable tailscaled
    systemctl start tailscaled
    
    print_success "Tailscale instalado e iniciado"
}

configure_server() {
    print_step "Configurando servidor..."
    
    cat > "$SERVER_DIR/server.properties" << EOF
# Minecraft server properties
server-port=$SERVER_PORT
server-ip=
online-mode=$ONLINE_MODE
max-players=10
network-compression-threshold=256
prevent-proxy-connections=false

view-distance=$VIEW_DISTANCE
simulation-distance=$SIMULATION_DISTANCE

max-tick-time=60000
max-world-size=29999984
sync-chunk-writes=false
enable-jmx-monitoring=false
enable-status=true

entity-broadcast-range-percentage=75
max-build-height=256
spawn-animals=true
spawn-monsters=true
spawn-npcs=true
spawn-protection=0
EOF

    mkdir -p "$SERVER_DIR/config/essentialcommands" "$SERVER_DIR/config/universal_graves"
    
    if [ ! -f "$SERVER_DIR/config/essentialcommands/config.toml" ]; then
        cat > "$SERVER_DIR/config/essentialcommands/config.toml" << 'EOF'
[teleportation]
allow_teleport_between_dimensions = true
teleport_request_timeout_seconds = 120
teleport_cost = 0

[home]
max_homes = 3
allow_home_in_any_dimension = true

[spawn]
allow_spawn_in_any_dimension = true

[back]
enable_back = true
save_back_on_death = true

[rtp]
enable_rtp = true
rtp_radius = 10000
rtp_min_radius = 1000

[nicknames]
enable_nicknames = true
nickname_prefix = "~"
EOF
    fi

    if [ ! -f "$SERVER_DIR/config/universal_graves/config.json" ]; then
        cat > "$SERVER_DIR/config/universal_graves/config.json" << 'EOF'
{
  "protection_time": 300,
  "breaking_time": 1800,
  "drop_items_on_expiration": true,
  "message_on_grave_break": true,
  "message_on_grave_expire": true,
  "hologram": true,
  "title": true,
  "gui": true
}
EOF
    fi

    # Copiar e atualizar scripts
    for script in start-server.sh mc-manager.sh backup-cron.sh setup-cron.sh; do
        if [ -f "/tmp/minecraft-server-scripts/$script" ]; then
            cp "/tmp/minecraft-server-scripts/$script" "$SERVER_DIR/"
        fi
    done
    
    if [ -f "$SERVER_DIR/start-server.sh" ]; then
        sed -i "s|SERVER_DIR=.*|SERVER_DIR=\"$SERVER_DIR\"|g" "$SERVER_DIR/start-server.sh"
        sed -i "s|MIN_RAM=.*|MIN_RAM=\"$SERVER_RAM\"|g" "$SERVER_DIR/start-server.sh"
        sed -i "s|MAX_RAM=.*|MAX_RAM=\"$SERVER_RAM\"|g" "$SERVER_DIR/start-server.sh"
    fi

    for script in mc-manager.sh backup-cron.sh setup-cron.sh; do
        if [ -f "$SERVER_DIR/$script" ]; then
            sed -i "s|/opt/minecraft-server|$SERVER_DIR|g" "$SERVER_DIR/$script"
        fi
    done
    if [ -f "$SERVER_DIR/mc-manager.sh" ]; then
        sed -i "s|^SERVER_USER=.*|SERVER_USER=\"$MINECRAFT_USER\"|g" "$SERVER_DIR/mc-manager.sh"
    fi
    
    if [ -f "/tmp/minecraft-server-scripts/server-icon.png" ]; then
        cp /tmp/minecraft-server-scripts/server-icon.png "$SERVER_DIR/"
    fi
    
    chmod +x "$SERVER_DIR"/*.sh 2>/dev/null || true
    
    cat > "$SERVER_DIR/comandos.sh" << EOF
#!/bin/bash
alias mcstart='sudo systemctl start minecraft'
alias mcstop='sudo systemctl stop minecraft'
alias mcrestart='sudo systemctl restart minecraft'
alias mcstatus='sudo systemctl status minecraft'
alias mclogs='sudo journalctl -u minecraft -f'
alias mcconsole='sudo $SERVER_DIR/mc-manager.sh console'
alias mcbackup='sudo $SERVER_DIR/mc-manager.sh backup'
alias mcchunky='sudo $SERVER_DIR/mc-manager.sh chunky'
alias mctailscale='sudo tailscale status'

alias mcdir='cd $SERVER_DIR'
alias mcprops='sudo nano $SERVER_DIR/server.properties'
alias mcmod='sudo $SERVER_DIR/mc-manager.sh mod'
EOF
    chmod +x "$SERVER_DIR/comandos.sh"
    chown -R "${MINECRAFT_USER}:${MINECRAFT_USER}" "$SERVER_DIR"
    print_success "Servidor configurado"
}

configure_system() {
    print_step "Configurando otimizações do sistema..."
    
    cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = min(ram, 4096)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
    systemctl daemon-reload
    systemctl start systemd-zram-setup@zram0.service || true

    echo "vm.swappiness=180" > /etc/sysctl.d/99-zram.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.d/99-zram.conf
    
    echo 'ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-scheduler.rules
    echo 'ACTION=="add|change", KERNEL=="sda", ATTR{queue/read_ahead_kb}="4096"' > /etc/udev/rules.d/61-hdd-readahead.rules
    udevadm control --reload-rules || true
    udevadm trigger || true

    systemctl enable cpupower || true
    if [ -f /etc/default/cpupower ]; then
        sed -i "s/governor='ondemand'/governor='performance'/g" /etc/default/cpupower
    fi
    cpupower frequency-set -g performance || true

    systemctl --user mask pipewire wireplumber pulseaudio 2>/dev/null || true
    pacman -Rns --noconfirm bluez bluez-utils 2>/dev/null || true

    if ! grep -q "^${MINECRAFT_USER} soft nofile" /etc/security/limits.conf; then
        echo "${MINECRAFT_USER} soft nofile 65536" >> /etc/security/limits.conf
        echo "${MINECRAFT_USER} hard nofile 65536" >> /etc/security/limits.conf
    fi
    
    sysctl -p 2>/dev/null || true
    print_success "Sistema configurado"
}

install_service() {
    print_step "Instalando serviço systemd..."
    
    if [ -f "/tmp/minecraft-server-scripts/minecraft.service" ]; then
        cp /tmp/minecraft-server-scripts/minecraft.service /etc/systemd/system/minecraft.service
        sed -i "s|^User=.*|User=$MINECRAFT_USER|g" /etc/systemd/system/minecraft.service
        sed -i "s|^Group=.*|Group=$MINECRAFT_USER|g" /etc/systemd/system/minecraft.service
        sed -i "s|/opt/minecraft-server|$SERVER_DIR|g" /etc/systemd/system/minecraft.service

        systemctl daemon-reload
        systemctl enable minecraft
        print_success "Serviço instalado"
    else
        print_warning "Arquivo minecraft.service não encontrado para instalar."
    fi
}

main() {
    print_header
    check_root
    check_arch
    
    echo -e "${CYAN}--- Configuração Básica ---${NC}"
    ask_value "Usuário do servidor" "$MINECRAFT_USER" MINECRAFT_USER
    ask_value "Diretório de instalação" "$SERVER_DIR" SERVER_DIR
    ask_value "Porta do Servidor" "$SERVER_PORT" SERVER_PORT
    
    ask_value "Versão do Minecraft (Ex: 1.21.11, 1.20.4)" "$MINECRAFT_VERSION" MINECRAFT_VERSION
    
    echo -e "${CYAN}Escolha o Loader do Servidor:${NC}"
    echo "  1) Fabric (Recomendado, aceita mods QoL)"
    echo "  2) Paper  (Plugins tradicionais)"
    echo "  3) Vanilla"
    echo "  4) Forge"
    echo "  5) NeoForge"
    read -r -p "Sua escolha (1-5) [1]: " loader_choice
    case "$loader_choice" in
        2) LOADER_TYPE="paper" ;;
        3) LOADER_TYPE="vanilla" ;;
        4) LOADER_TYPE="forge" ;;
        5) LOADER_TYPE="neoforge" ;;
        *) LOADER_TYPE="fabric" ;;
    esac

    ask_value "Memória RAM do Servidor (ex: 2560M)" "$SERVER_RAM" SERVER_RAM
    SERVER_RAM="${SERVER_RAM^^}"

    while ! validate_java_ram_value "$SERVER_RAM"; do
        print_warning "Formato inválido. Use inteiro + unidade (ex: 2560M, 2G)."
        ask_value "Memória RAM do Servidor" "2560M" SERVER_RAM
        SERVER_RAM="${SERVER_RAM^^}"
    done
    
    if ask_confirm "Habilitar modo Pirata (online-mode=false)?" "Y"; then
        ONLINE_MODE="false"
    else
        ONLINE_MODE="true"
    fi
    
    if [ "$LOADER_TYPE" == "fabric" ]; then
        if ask_confirm "Instalar Modpack Adrenaline (Performance) limitando a versão?" "Y"; then
            INSTALL_MODPACK="true"
        else
            INSTALL_MODPACK="false"
        fi
        
        if ask_confirm "Instalar Mods QoL (Chunky, Graves, etc)?" "Y"; then
            INSTALL_QOL_MODS="true"
        else
            INSTALL_QOL_MODS="false"
        fi
    else
        INSTALL_MODPACK="false"
        INSTALL_QOL_MODS="false"
        print_warning "Modpack e Mods QoL nativos foram pulados (loader=$LOADER_TYPE não compatível primariamente)."
    fi
    
    if ask_confirm "Instalar e configurar VPN Tailscale?" "Y"; then
        INSTALL_TAILSCALE="true"
    else
        INSTALL_TAILSCALE="false"
    fi
    echo ""

    mkdir -p /tmp/minecraft-server-scripts
    # Oculta erros se os scripts não estiverem localmente (podem já estar resolvidos)
    cp -r "./"* /tmp/minecraft-server-scripts/ 2>/dev/null || true
    
    print_step "Preparando instalação..."
    
    install_dependencies
    create_user
    install_mrpack_install
    
    install_server_base
    
    if [ "$INSTALL_QOL_MODS" == "true" ]; then
        install_mods_qol
    fi
    
    if [ "$INSTALL_TAILSCALE" == "true" ]; then
        install_tailscale
    fi
    
    configure_server
    configure_system
    install_service
    
    echo -e "${GREEN}Instalação concluída no diretório: $SERVER_DIR${NC}"
}

if [ ! -f "start-server.sh" ]; then
    print_warning "Arquivos complementares (start-server, mc-manager) não achados na pasta atual. Prosseguindo..."
fi

main
