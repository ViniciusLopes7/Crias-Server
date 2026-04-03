#!/bin/bash

# ============================================
# Minecraft Server Auto-Installer
# Adrenaline Modpack + Chunky + QoL + Tailscale
# Para: Arch Linux Minimal | i3-6006U | 4GB RAM
# ============================================

set -e  # Sair em caso de erro

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Variáveis
MINECRAFT_USER="minecraft"
SERVER_DIR="/opt/minecraft-server"
ADRENALINE_VERSION=""  # Deixe vazio para última versão

# Versões dos mods (atualizadas para 1.21.11)
ESSENTIAL_COMMANDS_VERSION="0.38.6-mc1.21.11"
UNIVERSAL_GRAVES_VERSION="3.10.2+1.21.11"
TABTPS_VERSION="1.3.30"
STYLED_CHAT_VERSION="2.11.0+1.21.11"
CHUNKY_VERSION="1.4.55"

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
        read -p "Deseja continuar mesmo assim? (s/N): " -n 1 -r
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
        openssh
    
    print_step "Habilitando e iniciando OpenSSH (sshd)..."
    systemctl enable --now sshd
    
    print_success "Dependências instaladas"
}

create_user() {
    print_step "Criando usuário minecraft..."
    
    if id "$MINECRAFT_USER" &>/dev/null; then
        print_warning "Usuário $MINECRAFT_USER já existe"
    else
        useradd -m -s /bin/bash "$MINECRAFT_USER"
        print_success "Usuário $MINECRAFT_USER criado"
    fi
    
    # Criar diretório do servidor
    mkdir -p "$SERVER_DIR"
    chown "$MINECRAFT_USER:$MINECRAFT_USER" "$SERVER_DIR"
}

install_mrpack_install() {
    print_step "Instalando mrpack-install..."
    
    MRPACK_URL="https://github.com/nothub/mrpack-install/releases/download/v0.16.10/mrpack-install-linux"
    
    curl -fsSL -o "/tmp/mrpack-install" "$MRPACK_URL"
    install -m 755 "/tmp/mrpack-install" "/usr/local/bin/mrpack-install"
    
    print_success "mrpack-install instalado"
}

install_adrenaline() {
    print_step "Instalando Adrenaline Modpack..."
    
    cd "$SERVER_DIR"
    
    if [ -z "$ADRENALINE_VERSION" ]; then
        # Instalar última versão
        mrpack-install adrenaline --server-dir "$SERVER_DIR" --server-file server.jar
    else
        # Instalar versão específica
        mrpack-install adrenaline "$ADRENALINE_VERSION" --server-dir "$SERVER_DIR" --server-file server.jar
    fi
    
    # Aceitar EULA
    echo "eula=true" > "$SERVER_DIR/eula.txt"
    
    print_success "Adrenaline instalado"
}

install_mods_qol() {
    print_step "Instalando mods de Qualidade de Vida..."
    
    cd "$SERVER_DIR"
    mkdir -p mods
    
    print_step "Baixando mods de QoL (versões atualizadas para 1.21.11)..."
    
    # Chunky - Pré-geração de chunks (ESSENCIAL)
    print_step "Baixando Chunky v${CHUNKY_VERSION}..."
    curl -fsSL -o "$SERVER_DIR/mods/chunky.jar" \
        "https://cdn.modrinth.com/data/fALzjamp/versions/1CpEkmcD/Chunky-Fabric-${CHUNKY_VERSION}.jar" || \
    curl -fsSL -o "$SERVER_DIR/mods/chunky.jar" \
        "https://github.com/pop4959/Chunky/releases/download/${CHUNKY_VERSION}/Chunky-${CHUNKY_VERSION}.jar"
    
    # Essential Commands - Comandos básicos (/home, /spawn, /tpa, /back)
    print_step "Baixando Essential Commands v${ESSENTIAL_COMMANDS_VERSION}..."
    curl -fsSL -o "$SERVER_DIR/mods/essential-commands.jar" \
        "https://cdn.modrinth.com/data/6VdDUivB/versions/${ESSENTIAL_COMMANDS_VERSION}/essential-commands-${ESSENTIAL_COMMANDS_VERSION}.jar" || \
    curl -fsSL -o "$SERVER_DIR/mods/essential-commands.jar" \
        "https://github.com/John-Paul-R/Essential-Commands/releases/download/${ESSENTIAL_COMMANDS_VERSION}/essential-commands-${ESSENTIAL_COMMANDS_VERSION}.jar"
    
    # Universal Graves - Sistema de túmulos
    print_step "Baixando Universal Graves v${UNIVERSAL_GRAVES_VERSION}..."
    curl -fsSL -o "$SERVER_DIR/mods/universal-graves.jar" \
        "https://cdn.modrinth.com/data/3i7fqf9n/versions/rZeFZ5ip/graves-${UNIVERSAL_GRAVES_VERSION}.jar" || \
    curl -fsSL -o "$SERVER_DIR/mods/universal-graves.jar" \
        "https://github.com/Patbox/UniversalGraves/releases/download/${UNIVERSAL_GRAVES_VERSION}/graves-${UNIVERSAL_GRAVES_VERSION}.jar"
    
    # TabTPS - Mostra TPS na lista de jogadores
    print_step "Baixando TabTPS v${TABTPS_VERSION}..."
    curl -fsSL -o "$SERVER_DIR/mods/tabtps.jar" \
        "https://cdn.modrinth.com/data/cUhi3iB2/versions/hTiqRp4H/tabtps-fabric-mc1.21.11-${TABTPS_VERSION}.jar" || \
    curl -fsSL -o "$SERVER_DIR/mods/tabtps.jar" \
        "https://github.com/jpenilla/TabTPS/releases/download/v${TABTPS_VERSION}/tabtps-fabric-mc1.21.11-${TABTPS_VERSION}.jar"
    
    # Styled Chat - Melhora formatação do chat
    print_step "Baixando Styled Chat v${STYLED_CHAT_VERSION}..."
    curl -fsSL -o "$SERVER_DIR/mods/styled-chat.jar" \
        "https://cdn.modrinth.com/data/doqSKB0e/versions/nW0Cfq7D/styled-chat-${STYLED_CHAT_VERSION}.jar" || \
    curl -fsSL -o "$SERVER_DIR/mods/styled-chat.jar" \
        "https://github.com/Patbox/StyledChat/releases/download/${STYLED_CHAT_VERSION}/styled-chat-${STYLED_CHAT_VERSION}.jar"
    
    # Verificar downloads
    print_step "Verificando downloads..."
    for mod in chunky essential-commands universal-graves tabtps styled-chat; do
        if [ -f "$SERVER_DIR/mods/${mod}.jar" ]; then
            size=$(du -h "$SERVER_DIR/mods/${mod}.jar" | cut -f1)
            print_success "${mod}.jar baixado (${size})"
        else
            print_warning "${mod}.jar não encontrado, tentando mirror alternativo..."
        fi
    done
    
    # Ajustar permissões
    chown -R "$MINECRAFT_USER:$MINECRAFT_USER" "$SERVER_DIR/mods"
    
    print_success "Mods de QoL instalados"
}

install_tailscale() {
    print_step "Instalando Tailscale..."
    
    # Verificar se já está instalado
    if command -v tailscale &> /dev/null; then
        print_warning "Tailscale já está instalado"
        tailscale version
        return 0
    fi
    
    # Instalar Tailscale no Arch
    pacman -S --needed --noconfirm tailscale
    
    # Habilitar e iniciar serviço
    systemctl enable tailscaled
    systemctl start tailscaled
    
    print_success "Tailscale instalado e iniciado"
    print_step "Para conectar: sudo tailscale up"
    print_step "Para ver status: sudo tailscale status"
}

configure_server() {
    print_step "Configurando servidor..."
    
    # Configurar server.properties
    cat > "$SERVER_DIR/server.properties" << 'EOF'
# Minecraft server properties
# Otimizado para hardware limitado + QoL
# Versão: 1.21.11

# Rede
server-port=25565
server-ip=
online-mode=true
max-players=10
network-compression-threshold=256
prevent-proxy-connections=false

# Distâncias (CRÍTICO PARA PERFORMANCE)
view-distance=6
simulation-distance=4

# Performance
max-tick-time=60000
max-world-size=29999984
sync-chunk-writes=false
enable-jmx-monitoring=false
enable-status=true

# Entidades
entity-broadcast-range-percentage=75
max-build-height=256
spawn-animals=true
spawn-monsters=true
spawn-npcs=true
spawn-protection=0

# Geração
generate-structures=true
level-type=minecraft:normal
level-name=world

# Outros
motd=§6§l🏰 REINO DOS CRIAS 🏰\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r
pvp=true
gamemode=survival
difficulty=normal
allow-flight=false
allow-nether=true
force-gamemode=false
hardcore=false
white-list=false
enforce-whitelist=false
EOF

    # Configurar Essential Commands
    mkdir -p "$SERVER_DIR/config/essentialcommands"
    cat > "$SERVER_DIR/config/essentialcommands/config.toml" << 'EOF'
# Essential Commands Config
# Configuração otimizada para servidor com pouca RAM

[teleportation]
# Permitir teleporte entre dimensões
allow_teleport_between_dimensions = true
# Tempo de espera para teleporte (segundos)
teleport_request_timeout_seconds = 120
# Custo de experiência para teleporte (0 = gratuito)
teleport_cost = 0

[home]
# Máximo de homes por jogador
max_homes = 3
# Permitir home em qualquer dimensão
allow_home_in_any_dimension = true

[spawn]
# Permitir spawn em qualquer dimensão
allow_spawn_in_any_dimension = true

[back]
# Habilitar comando /back
enable_back = true
# Salvar localização ao morrer
save_back_on_death = true

[rtp]
# Habilitar teleporte aleatório
enable_rtp = true
# Raio máximo
rtp_radius = 10000
# Raio mínimo
rtp_min_radius = 1000

[nicknames]
# Permitir apelidos
enable_nicknames = true
# Prefixo de apelido
nickname_prefix = "~"
EOF

    # Configurar Universal Graves
    mkdir -p "$SERVER_DIR/config/universal_graves"
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

    # Configurar Styled Chat
    mkdir -p "$SERVER_DIR/config/styledchat"
    cat > "$SERVER_DIR/config/styledchat/config.json" << 'EOF'
{
  "formats": {
    "chat": "<yellow>[<gray>%server:tabtps_tps%<yellow>] <white>%player:displayname% <gold>» <white>${message}",
    "joined": "<gold>🔔 O cria <white>%player:displayname% <yellow>chegou no Reino!",
    "left": "<red>🚪 <white>%player:displayname% <gray>partiu em viagem...",
    "death": "<dark_red>☠ <white>%player:displayname% <red>pereceu em combate: <gray>%message%"
  }
}
EOF

    # Copiar scripts e ícone
    cp /tmp/minecraft-server-scripts/start-server.sh "$SERVER_DIR/"
    cp /tmp/minecraft-server-scripts/mc-manager.sh "$SERVER_DIR/"
    cp /tmp/minecraft-server-scripts/backup-cron.sh "$SERVER_DIR/"
    cp /tmp/minecraft-server-scripts/setup-cron.sh "$SERVER_DIR/"
    
    # Ícone do servidor (opcional)
    if [ -f "/tmp/minecraft-server-scripts/server-icon.png" ]; then
        cp /tmp/minecraft-server-scripts/server-icon.png "$SERVER_DIR/"
        print_success "Ícone do servidor (server-icon.png) instalado"
    fi
    
    chmod +x "$SERVER_DIR/start-server.sh"
    chmod +x "$SERVER_DIR/mc-manager.sh"
    chmod +x "$SERVER_DIR/backup-cron.sh"
    chmod +x "$SERVER_DIR/setup-cron.sh"
    
    # Criar aliases/atalhos
    cat > "$SERVER_DIR/comandos.sh" << 'EOF'
#!/bin/bash
# Atalhos rápidos para comandos do servidor
# Uso: source ./comandos.sh

alias mcstart='sudo systemctl start minecraft'
alias mcstop='sudo systemctl stop minecraft'
alias mcrestart='sudo systemctl restart minecraft'
alias mcstatus='sudo systemctl status minecraft'
alias mclogs='sudo journalctl -u minecraft -f'
alias mcconsole='/opt/minecraft-server/mc-manager.sh console'
alias mcbackup='/opt/minecraft-server/mc-manager.sh backup'
alias mcinfo='/opt/minecraft-server/mc-manager.sh status'
alias mcchunky='/opt/minecraft-server/mc-manager.sh chunky'
alias mctps='/opt/minecraft-server/mc-manager.sh tps'
alias mctailscale='sudo tailscale status'

echo "=========================================="
echo "   Atalhos Minecraft Server Carregados"
echo "=========================================="
echo ""
echo "  mcstart    - Iniciar servidor"
echo "  mcstop     - Parar servidor"
echo "  mcrestart  - Reiniciar servidor"
echo "  mcstatus   - Status do serviço"
echo "  mclogs     - Ver logs"
echo "  mcconsole  - Acessar console"
echo "  mcbackup   - Fazer backup"
echo "  mcinfo     - Informações detalhadas"
echo "  mcchunky   - Menu do Chunky"
echo "  mctps      - Ver TPS"
echo "  mctailscale- Status do Tailscale"
echo ""
echo "=========================================="
EOF

    chmod +x "$SERVER_DIR/comandos.sh"
    
    # Ajustar permissões
    chown -R "$MINECRAFT_USER:$MINECRAFT_USER" "$SERVER_DIR"
    
    print_success "Servidor configurado"
}

configure_system() {
    print_step "Configurando otimizações do sistema..."
    
    # ZRAM Config
    cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = min(ram, 4096)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
    systemctl daemon-reload
    systemctl start systemd-zram-setup@zram0.service || true

    # Swappiness para ZRAM
    echo "vm.swappiness=180" > /etc/sysctl.d/99-zram.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.d/99-zram.conf
    
    # I/O Scheduler HDD
    echo 'ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-scheduler.rules
    echo 'ACTION=="add|change", KERNEL=="sda", ATTR{queue/read_ahead_kb}="4096"' > /etc/udev/rules.d/61-hdd-readahead.rules
    udevadm control --reload-rules || true
    udevadm trigger || true

    # CPU Governor
    systemctl enable cpupower || true
    if [ -f /etc/default/cpupower ]; then
        sed -i "s/governor='ondemand'/governor='performance'/g" /etc/default/cpupower
    fi
    cpupower frequency-set -g performance || true

    # Desabilitar/Remover serviços inúteis para esse servidor (Headless + Cabeado)
    print_step "Removendo e desabilitando pacotes não utilizados (Bluetooth, Áudio, Wi-Fi)..."
    
    # 1. Parar serviços que possam estar rodando antes de remover
    systemctl disable --now bluetooth.service 2>/dev/null || true
    systemctl disable --now iwd.service 2>/dev/null || true
    systemctl disable --now wpa_supplicant.service 2>/dev/null || true
    systemctl --user mask pipewire wireplumber pulseaudio 2>/dev/null || true
    
    # 2. Desinstalar (se existirem) para economizar RAM máxima
    # Usando --noconfirm para não travar o script se não existir
    pacman -Rns --noconfirm bluez bluez-utils 2>/dev/null || true
    pacman -Rns --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pulseaudio 2>/dev/null || true
    pacman -Rns --noconfirm wpa_supplicant iwd dialog 2>/dev/null || true

    # Limites de arquivos
    if ! grep -q "minecraft soft nofile" /etc/security/limits.conf; then
        echo "minecraft soft nofile 65536" >> /etc/security/limits.conf
        echo "minecraft hard nofile 65536" >> /etc/security/limits.conf
    fi
    
    # Aplicar sysctl
    sysctl -p 2>/dev/null || true
    
    print_success "Sistema configurado"
}

install_service() {
    print_step "Instalando serviço systemd..."
    
    cp /tmp/minecraft-server-scripts/minecraft.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable minecraft
    
    print_success "Serviço instalado"
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "   INSTALAÇÃO CONCLUÍDA!"
    echo "=========================================="
    echo ""
    echo -e "${GREEN}Servidor instalado em:${NC} $SERVER_DIR"
    echo ""
    echo "Comandos rápidos (atalhos):"
    echo "  source /opt/minecraft-server/comandos.sh  # Carregar atalhos"
    echo "  mcstart    - Iniciar servidor"
    echo "  mcstop     - Parar servidor"
    echo "  mcrestart  - Reiniciar servidor"
    echo "  mcstatus   - Ver status"
    echo "  mclogs     - Ver logs"
    echo "  mcconsole  - Acessar console"
    echo "  mcbackup   - Fazer backup"
    echo "  mcinfo     - Informações detalhadas"
    echo ""
    echo "Comandos do mc-manager:"
    echo "  /opt/minecraft-server/mc-manager.sh start|stop|restart|status|console|backup|update"
    echo ""
    echo "Tailscale (VPN):"
    echo "  sudo tailscale up     # Conectar à VPN"
    echo "  sudo tailscale status # Ver status"
    echo "  sudo tailscale ip -4  # Ver IP do Tailscale"
    echo ""
    echo "Mods instalados (versões atualizadas):"
    echo "  - Adrenaline (performance)"
    echo "  - Chunky ${CHUNKY_VERSION} (pré-geração de chunks)"
    echo "  - Essential Commands ${ESSENTIAL_COMMANDS_VERSION} (/home, /spawn, /tpa, /back)"
    echo "  - Universal Graves ${UNIVERSAL_GRAVES_VERSION} (túmulos ao morrer)"
    echo "  - TabTPS ${TABTPS_VERSION} (TPS no TAB)"
    echo "  - Styled Chat ${STYLED_CHAT_VERSION} (chat formatado)"
    echo ""
    echo "Comandos novos disponíveis no jogo:"
    echo "  /home, /sethome, /delhome - Gerenciar homes"
    echo "  /spawn - Ir para spawn"
    echo "  /tpa <jogador> - Pedir teleporte"
    echo "  /tpaccept, /tpadeny - Aceitar/recusar teleporte"
    echo "  /back - Voltar ao local anterior"
    echo "  /chunky start - Iniciar pré-geração"
    echo "  /chunky pause - Pausar pré-geração"
    echo "  /chunky status - Ver progresso"
    echo ""
    echo "Para iniciar agora:"
    echo "  sudo systemctl start minecraft"
    echo ""
    echo "Para ver logs:"
    echo "  sudo journalctl -u minecraft -f"
    echo ""
    echo "Para configurar backup automático:"
    echo "  sudo /opt/minecraft-server/setup-cron.sh"
    echo ""
    echo -e "${YELLOW}IMPORTANTE:${NC}"
    echo "- O servidor está configurado para usar 2.5GB de RAM"
    echo "- View distance: 6 chunks"
    echo "- Max players: 10 (recomendado: 5-8 para este hardware)"
    echo "- Bluetooth, Áudio e Wi-Fi totalmente removidos do sistema"
    echo "- ZRAM configurado para economizar RAM"
    echo ""
    echo -e "${GREEN}Divirta-se!${NC}"
    echo "=========================================="
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

main() {
    print_header
    check_root
    check_arch
    
    # Criar diretório temporário para scripts e copiar os arquivos
    mkdir -p /tmp/minecraft-server-scripts
    cp start-server.sh mc-manager.sh minecraft.service backup-cron.sh setup-cron.sh server-icon.png /tmp/minecraft-server-scripts/ 2>/dev/null || true
    
    # Extrair scripts embutidos (serão criados pelo usuário)
    print_step "Preparando arquivos..."
    
    install_dependencies
    create_user
    install_mrpack_install
    install_adrenaline
    install_mods_qol
    install_tailscale
    configure_server
    configure_system
    install_service
    
    print_summary
}

# === INÍCIO DAS CORREÇÕES ===
# Verificar se scripts existem
if [ ! -f "start-server.sh" ] || [ ! -f "mc-manager.sh" ] || [ ! -f "minecraft.service" ]; then
    print_error "Arquivos necessários não encontrados!"
    echo "Certifique-se de que os seguintes arquivos estão no mesmo diretório:"
    echo "  - start-server.sh"
    echo "  - mc-manager.sh"
    echo "  - minecraft.service"
    echo "  - backup-cron.sh"
    echo "  - setup-cron.sh"
    exit 1
fi

# Executar instalação
main

