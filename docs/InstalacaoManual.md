# Setup Completo - Minecraft Server 1.21.11 + Adrenaline + QoL + Tailscale
## Otimizado para: i3-6006U | 4GB RAM | HDD 1TB | Arch Linux Minimal

---

## Sumário
1. [Preparação do Sistema](#1-preparação-do-sistema)
2. [Instalação do Modpack Adrenaline](#2-instalação-do-modpack-adrenaline)
3. [Mods de Qualidade de Vida](#3-mods-de-qualidade-de-vida)
4. [Tailscale VPN](#4-tailscale-vpn)
5. [Configurações de Performance](#5-configurações-de-performance)
6. [Flags JVM Otimizadas](#6-flags-jvm-otimizadas)
7. [Otimizações do Sistema Linux](#7-otimizações-do-sistema-linux)
8. [Script de Inicialização](#8-script-de-inicialização)
9. [Serviço Systemd](#9-serviço-systemd)
10. [Comandos Facilitados](#10-comandos-facilitados)
11. [Chunky - Pré-Geração](#11-chunky---pré-geração)
12. [Backup Automático](#12-backup-automático)
13. [Troubleshooting](#13-troubleshooting)
14. [Recomendações Finais](#14-recomendações-finais)

---

## 1. Preparação do Sistema

### 1.1 Atualizar o Sistema
```bash
sudo pacman -Syu
```

### 1.2 Instalar Dependências Essenciais
```bash
# Java 21 (necessário para Minecraft 1.21.11)
sudo pacman -S jdk21-openjdk

# Ferramentas úteis
sudo pacman -S screen htop iotop nano curl wget tar gzip base-devel

# Verificar instalação do Java
java -version
```

### 1.3 Criar Usuário Dedicado (Recomendado)
```bash
sudo useradd -m -s /bin/bash minecraft
sudo passwd minecraft
sudo usermod -aG wheel minecraft
```

### 1.4 Configurar Diretórios
```bash
sudo mkdir -p /opt/minecraft-server
sudo chown minecraft:minecraft /opt/minecraft-server
su - minecraft
cd /opt/minecraft-server
```

---

## 2. Instalação do Modpack Adrenaline

### 2.1 Instalar mrpack-install
```bash
# Baixar mrpack-install
cd /opt/minecraft-server
curl -sSL -o "mrpack-install" "https://github.com/nothub/mrpack-install/releases/download/v0.16.10/mrpack-install-linux"

# Tornar executável
chmod +x mrpack-install

# Mover para PATH (opcional)
sudo mv mrpack-install /usr/local/bin/
```

### 2.2 Instalar Adrenaline Server
```bash
cd /opt/minecraft-server

# Instalar Adrenaline (última versão para 1.21.11)
mrpack-install adrenaline --server-dir /opt/minecraft-server --server-file server.jar

# Ou versão específica:
# mrpack-install adrenaline 1.26.0+1.21.1.fabric --server-dir /opt/minecraft-server --server-file server.jar
```

### 2.3 Aceitar EULA
```bash
echo "eula=true" > /opt/minecraft-server/eula.txt
```

---

## 3. Mods de Qualidade de Vida

### 3.1 Instalar Mods de QoL

Criar diretório de mods e baixar:

```bash
cd /opt/minecraft-server
mkdir -p mods
```

#### Chunky (Pré-geração de Chunks)
```bash
# Download do Chunky
curl -sSL -o "mods/chunky.jar" \
  "https://github.com/pop4959/Chunky/releases/download/1.4.55/Chunky-1.4.55.jar"
```

**Comandos do Chunky:**
```
/chunky start                    # Iniciar pré-geração
/chunky pause                    # Pausar
/chunky continue                 # Continuar
/chunky cancel                   # Cancelar
/chunky status                   # Ver progresso
/chunky radius 1000              # Definir raio (blocos)
/chunky center 0 0               # Definir centro
/chunky world world              # Selecionar mundo
```

#### Essential Commands
```bash
# Download do Essential Commands
curl -sSL -o "mods/essential-commands.jar" \
  "https://github.com/John-Paul-R/Essential-Commands/releases/download/0.38.6-mc1.21.11/essential-commands-0.38.6-mc1.21.11.jar"
```

**Comandos disponíveis:**
```
/home                    - Teletransportar para home padrão
/home <nome>             - Teletransportar para home específica
/sethome                 - Definir home padrão
/sethome <nome>          - Definir home nomeada (máx: 3)
/delhome <nome>          - Deletar home
/spawn                   - Ir para spawn
/tpa <jogador>           - Pedir teleporte para jogador
/tpahere <jogador>       - Pedir para jogador teleportar até você
/tpaccept                - Aceitar pedido de teleporte
/tpadeny                 - Recusar pedido de teleporte
/back                    - Voltar ao local anterior (morte/teleporte)
/rtp                     - Teletransporte aleatório
/nickname set <jogador> <apelido>  - Definir apelido
/nickname clear <jogador>          - Remover apelido
```

#### Universal Graves
```bash
# Download do Universal Graves
curl -sSL -o "mods/universal-graves.jar" \
  "https://github.com/Patbox/UniversalGraves/releases/download/3.10.2+1.21.11/graves-3.10.2+1.21.11.jar"
```

**Funcionalidade:**
- Cria um túmulo quando o jogador morre
- Itens e XP são guardados no túmulo
- Proteção configurável (padrão: 5 minutos)
- Holograma mostra localização
- Mensagens informam coordenadas do túmulo

#### TabTPS
```bash
# Download do TabTPS
curl -sSL -o "mods/tabtps.jar" \
  "https://github.com/jpenilla/TabTPS/releases/download/v1.3.30/tabtps-fabric-mc1.21.11-1.3.30.jar"
```

**Funcionalidade:**
- Mostra TPS (Ticks Por Segundo) na lista de jogadores (TAB)
- Mostra MSPT (Milissegundos Por Tick)
- Mostra uso de memória

#### Styled Chat
```bash
# Download do Styled Chat
curl -sSL -o "mods/styled-chat.jar" \
  "https://github.com/Patbox/StyledChat/releases/download/2.11.0+1.21.11/styled-chat-2.11.0+1.21.11.jar"
```

**Funcionalidade:**
- Formatação customizada do chat
- Placeholders para informações do servidor
- Mensagens de entrada/saída personalizadas

### 3.2 Configurar Mods

#### Configuração do Essential Commands
```bash
mkdir -p /opt/minecraft-server/config/essentialcommands
```

Criar arquivo `config/essentialcommands/config.toml`:
```toml
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
```

#### Configuração do Universal Graves
```bash
mkdir -p /opt/minecraft-server/config/universal_graves
```

Criar arquivo `config/universal_graves/config.json`:
```json
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
```

#### Configuração do Styled Chat
```bash
mkdir -p /opt/minecraft-server/config
```

Criar arquivo `config/styled-chat.json`:
```json
{
  "CONFIG_VERSION_DONT_TOUCH_THIS": 2,
  "defaultStyle": {
    "chat": "<yellow>${player}</yellow> <dark_gray>»</dark_gray> <white>${message}</white>",
    "join": "<gold>🔔</gold> <yellow>${player} chegou no Reino!</yellow>",
    "left": "<red>🚪</red> <yellow>${player} partiu em viagem...</yellow>",
    "death": "<dark_red>☠</dark_red> <red>${player}</red> <gray>${default_message}</gray>"
  }
}
```

---

## 4. Tailscale VPN

### 4.1 Instalar Tailscale

```bash
# Instalar no Arch Linux
sudo pacman -S tailscale

# Habilitar serviço
sudo systemctl enable tailscaled
sudo systemctl start tailscaled
```

### 4.2 Configurar Tailscale

```bash
# Conectar à rede Tailscale
sudo tailscale up

# Siga as instruções na tela para autenticar
# Você receberá um link para autenticar no navegador
```

### 4.3 Comandos Úteis

```bash
# Ver status
sudo tailscale status

# Ver IP do Tailscale
sudo tailscale ip -4

# Listar dispositivos na rede
sudo tailscale status

# Desconectar
sudo tailscale down

# Reconectar
sudo tailscale up
```

### 4.4 Conectar ao Servidor

1. Instale Tailscale no seu PC/celular
2. Conecte à mesma conta/rede
3. Use o IP Tailscale do servidor no Minecraft
4. **Não precisa abrir portas no roteador!**

---

## 5. Configurações de Performance

### 5.1 server.properties (Otimizado para hardware limitado)
```properties
# /opt/minecraft-server/server.properties
# Gerado automaticamente - EDITAR CONFORME ABAIXO

# === CONFIGURAÇÕES DE REDE ===
server-port=25565
server-ip=
online-mode=false
max-players=10
network-compression-threshold=256
prevent-proxy-connections=false

# === DISTÂNCIAS (CRÍTICO PARA PERFORMANCE) ===
view-distance=6
simulation-distance=4

# === PERFORMANCE ===
max-tick-time=60000
max-world-size=29999984
sync-chunk-writes=false
enable-jmx-monitoring=false
enable-status=true

# === ENTIDADES ===
max-build-height=256
spawn-animals=true
spawn-monsters=true
spawn-npcs=true
spawn-protection=0

# === GERAÇÃO DE MUNDO ===
generate-structures=true
level-type=minecraft:normal
level-name=world

# === OUTROS ===
motd=§aServidor Minecraft §7| §eAdrenaline§7+§6QoL §7| §6Otimizado
pvp=true
gamemode=survival
difficulty=normal
allow-flight=false
allow-nether=true
force-gamemode=false
hardcore=false
white-list=false
enforce-whitelist=false
```

---

## 6. Flags JVM Otimizadas

### 6.1 Análise do Hardware
- **CPU**: i3-6006U (2C/4T @ 2.0GHz) - Skylake
- **RAM**: 4GB total
- **Alocação recomendada**: 2560M (~2.5GB) para Minecraft
- **Formato válido no Java**: use `2560M` ou valores inteiros em G (ex: `2G`, `3G`), nunca `2.5G`
- **Reserva para SO/ZRAM**: ~1.5GB (suficiente após remover bluetooth/áudio/wifi)

### 6.2 Flags JVM Otimizadas (G1GC - Recomendado para <4GB)
```bash
# Salvar em: /opt/minecraft-server/start-server.sh

#!/bin/bash

# === CONFIGURAÇÕES ===
SERVER_DIR="/opt/minecraft-server"
SERVER_JAR="server.jar"
MIN_RAM="2560M"
MAX_RAM="2560M"

# === FLAGS JVM OTIMIZADAS PARA i3-6006U + 4GB RAM ===
JAVA_OPTS=""

# Memory Settings
JAVA_OPTS="$JAVA_OPTS -Xms${MIN_RAM}"
JAVA_OPTS="$JAVA_OPTS -Xmx${MAX_RAM}"
JAVA_OPTS="$JAVA_OPTS -XX:+UseG1GC"
JAVA_OPTS="$JAVA_OPTS -XX:+ParallelRefProcEnabled"
JAVA_OPTS="$JAVA_OPTS -XX:MaxGCPauseMillis=200"
JAVA_OPTS="$JAVA_OPTS -XX:+UnlockExperimentalVMOptions"
JAVA_OPTS="$JAVA_OPTS -XX:+DisableExplicitGC"
JAVA_OPTS="$JAVA_OPTS -XX:G1NewSizePercent=30"
JAVA_OPTS="$JAVA_OPTS -XX:G1MaxNewSizePercent=40"
JAVA_OPTS="$JAVA_OPTS -XX:G1HeapRegionSize=8M"
JAVA_OPTS="$JAVA_OPTS -XX:G1ReservePercent=20"
JAVA_OPTS="$JAVA_OPTS -XX:G1HeapWastePercent=5"
JAVA_OPTS="$JAVA_OPTS -XX:G1MixedGCLiveThresholdPercent=90"
JAVA_OPTS="$JAVA_OPTS -XX:G1RSetUpdatingPauseTimePercent=5"
JAVA_OPTS="$JAVA_OPTS -XX:SurvivorRatio=32"
JAVA_OPTS="$JAVA_OPTS -XX:MaxTenuringThreshold=1"
JAVA_OPTS="$JAVA_OPTS -XX:InitiatingHeapOccupancyPercent=15"

# Otimizações para pouca memória
JAVA_OPTS="$JAVA_OPTS -XX:+UseCompressedOops"
JAVA_OPTS="$JAVA_OPTS -XX:+UseStringDeduplication"

# Reduzir overhead de logging
JAVA_OPTS="$JAVA_OPTS -XX:+PerfDisableSharedMem"

# Otimizações de rede
JAVA_OPTS="$JAVA_OPTS -Djava.net.preferIPv4Stack=true"

# Fabric/Minecraft específico
JAVA_OPTS="$JAVA_OPTS -Dfabric.log.disable-ansi=true"
JAVA_OPTS="$JAVA_OPTS -Dlog4j2.formatMsgNoLookups=true"

# === INICIAR SERVIDOR ===
cd "$SERVER_DIR"

# Verificar se há RAM suficiente
AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
if [ "$AVAILABLE_RAM" -lt 2048 ]; then
    echo "AVISO: Pouca RAM disponível ($AVAILABLE_RAM MB). O servidor pode travar."
    echo "Considere fechar outros programas."
    sleep 3
fi

echo "Iniciando servidor Minecraft..."
echo "RAM Alocada: $MIN_RAM - $MAX_RAM"
echo "Diretório: $SERVER_DIR"
echo "=========================================="

exec java $JAVA_OPTS -jar "$SERVER_JAR" nogui
```

### 6.3 Tornar Script Executável
```bash
chmod +x /opt/minecraft-server/start-server.sh
```

---

## 7. Otimizações do Sistema Linux

### 7.1 Configurações de Swappiness
```bash
# Reduzir uso de swap (melhor para performance)
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
echo "vm.vfs_cache_pressure=50" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 7.2 Otimizações de I/O para HDD
```bash
# Configurar scheduler para HDD
echo 'ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="bfq"' | sudo tee /etc/udev/rules.d/60-scheduler.rules

# Aplicar regras
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### 7.3 Limites de Arquivos Abertos
```bash
# Aumentar limites para usuário minecraft
echo "minecraft soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "minecraft hard nofile 65536" | sudo tee -a /etc/security/limits.conf
```

### 7.4 Otimizações de Kernel (Opcional)
```bash
# Adicionar ao /etc/sysctl.conf
sudo tee -a /etc/sysctl.conf << 'EOF'

# Otimizações para servidor Minecraft
vm.max_map_count=262144
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 65536 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_congestion_control=bbr
EOF

sudo sysctl -p
```

---

## 8. Script de Inicialização

### 8.1 Script de Start/Stop/Restart Completo

Ver arquivo `mc-manager.sh` incluído no pacote.

---

## 9. Serviço Systemd

### 9.1 Criar Serviço
```bash
sudo tee /etc/systemd/system/minecraft.service << 'EOF'
[Unit]
Description=Minecraft Server (Adrenaline + QoL)
After=network.target

[Service]
Type=forking
User=minecraft
Group=minecraft
WorkingDirectory=/opt/minecraft-server

# Comando de inicialização usando screen
ExecStart=/usr/bin/screen -dmS minecraft /opt/minecraft-server/start-server.sh

# Comando de parada
ExecStop=/opt/minecraft-server/mc-manager.sh stop

# Timeout para parada
TimeoutStopSec=60

# Reiniciar em caso de falha
Restart=on-failure
RestartSec=30
StartLimitInterval=60s
StartLimitBurst=3

# Limites de recursos
LimitNOFILE=65536
LimitNPROC=4096

# Prioridade de CPU
Nice=-5

# OOM killer - não matar o servidor facilmente
OOMScoreAdjust=-800

# Ambiente
Environment="JAVA_HOME=/usr/lib/jvm/java-21-openjdk"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF
```

### 9.2 Habilitar e Iniciar Serviço
```bash
sudo systemctl daemon-reload
sudo systemctl enable minecraft
sudo systemctl start minecraft
```

---

## 10. Comandos Facilitados

### 10.1 Atalhos Rápidos

Criar arquivo `/opt/minecraft-server/comandos.sh`:
```bash
#!/bin/bash
# Atalhos rápidos para comandos do servidor
# Uso: source ./comandos.sh

alias mcstart='sudo systemctl start minecraft'
alias mcstop='sudo systemctl stop minecraft'
alias mcrestart='sudo systemctl restart minecraft'
alias mcstatus='sudo systemctl status minecraft'
alias mclogs='sudo journalctl -u minecraft -f'
alias mcconsole='sudo /opt/minecraft-server/mc-manager.sh console'
alias mcbackup='sudo /opt/minecraft-server/mc-manager.sh backup'
alias mcchunky='sudo /opt/minecraft-server/mc-manager.sh chunky'
alias mctailscale='sudo tailscale status'
alias mcdir='cd /opt/minecraft-server'
alias mcprops='sudo nano /opt/minecraft-server/server.properties'
alias mcmod='sudo /opt/minecraft-server/mc-manager.sh mod'

echo "Atalhos carregados:"
echo "  mcstart    - Iniciar servidor"
echo "  mcstop     - Parar servidor"
echo "  mcrestart  - Reiniciar servidor"
echo "  mcstatus   - Status do serviço"
echo "  mclogs     - Ver logs"
echo "  mcconsole  - Acessar console"
echo "  mcbackup   - Fazer backup"
echo "  mcchunky   - Menu do Chunky"
echo "  mctailscale- Status do Tailscale"
echo "  mcdir      - Ir para a pasta do servidor"
echo "  mcprops    - Editar server.properties"
echo "  mcmod      - Gerenciar mods (add/remove/list)"
```

### 10.2 Uso dos Atalhos
```bash
# Carregar atalhos
source /opt/minecraft-server/comandos.sh

# Usar atalhos
mcstart
mcstop
mcrestart
mcstatus
mcchunky
```

---

## 11. Chunky - Pré-Geração

### 11.1 Menu Interativo
```bash
/opt/minecraft-server/mc-manager.sh chunky
```

### 11.2 Comandos do Chunky
```
/chunky start                    # Iniciar pré-geração
/chunky pause                    # Pausar
/chunky continue                 # Continuar
/chunky cancel                   # Cancelar
/chunky status                   # Ver progresso
/chunky radius 1000              # Definir raio (blocos)
/chunky center 0 0               # Definir centro
/chunky world world              # Selecionar mundo
/chunky selection square         # Forma quadrada
/chunky selection circle         # Forma circular
```

### 11.3 Exemplo de Uso
```
# Configurar área de 1000 blocos de raio
/chunky radius 1000

# Definir centro no spawn
/chunky center 0 0

# Iniciar pré-geração
/chunky start

# Ver progresso
/chunky status
```

### 11.4 Dicas
- Execute antes de abrir para jogadores
- Pode pausar e continuar depois
- Use `/chunky status` para acompanhar progresso
- Para servidor com HDD, faça em horários de pouco uso

---

## 12. Backup Automático

### 12.1 Configurar Cron
```bash
sudo /opt/minecraft-server/setup-cron.sh
```

Ou manualmente:
```bash
sudo crontab -e
# Adicionar: 0 3 * * * /opt/minecraft-server/backup-cron.sh
```

### 12.2 Retenção
- Backups mantidos por **7 dias**
- Local: `/opt/minecraft-server/backups/`

---

## 13. Troubleshooting

### Problema: OutOfMemoryError
```bash
# Reduzir MAX_RAM para 2560M no script (já otimizado, considere fechar processos do SO)
nano /opt/minecraft-server/start-server.sh
```

### Problema: Servidor lento
```bash
# Verificar TPS
/opt/minecraft-server/mc-manager.sh tps

# Verificar recursos
/opt/minecraft-server/mc-manager.sh status
```

### Problema: Tailscale não conecta
```bash
# Verificar status
sudo tailscale status

# Reautenticar
sudo tailscale up --force-reauth
```

---

## 14. Recomendações Finais

### 14.1 Limitações do Hardware
Com **4GB de RAM** e **i3-6006U**:
- **Máximo de jogadores**: 5-8 simultâneos
- **View distance**: Mantenha em 6 ou menos
- **Evite**: Muitos mods adicionais

### 14.2 Checklist de Lançamento
1. [ ] Instalar servidor com install.sh
2. [ ] Configurar Tailscale
3. [ ] Executar pré-geração com Chunky
4. [ ] Configurar backup automático
5. [ ] Testar comandos de QoL
6. [ ] Abrir para jogadores

---

**Documento criado para**: Minecraft Server 1.21.11 + Adrenaline + QoL + Tailscale  
**Hardware alvo**: i3-6006U, 4GB RAM, HDD 1TB, Arch Linux Minimal  
**Data**: 2026
