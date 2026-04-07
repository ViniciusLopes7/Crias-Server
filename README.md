# Minecraft Server 1.21.11 + Adrenaline + QoL + Tailscale
## Setup Otimizado para Arch Linux | i3-6006U | 4GB RAM | HDD

---

## ✅ Status da Revisão

| Componente | Versão | Status |
|------------|--------|--------|
| Minecraft | 1.21.11 | ✅ Atualizado |
| Java | 21 (OpenJDK) | ✅ Atualizado |
| Adrenaline | Latest | ✅ Atualizado |
| Essential Commands | 0.38.6 | ✅ Atualizado |
| Universal Graves | 3.10.2 | ✅ Atualizado |
| TabTPS | 1.3.30 | ✅ Atualizado |
| Styled Chat | 2.11.0 | ✅ Atualizado |
| Chunky | 1.4.55 | ✅ Atualizado |
| Tailscale | Latest | ✅ Atualizado |

---

## 📦 Visão Geral

Este pacote contém tudo necessário para configurar um servidor Minecraft 1.21.11 otimizado para hardware limitado:

- **Adrenaline Modpack** - Otimizações de performance
- **Chunky** - Pré-geração de chunks
- **Essential Commands** - /home, /spawn, /tpa, /back
- **Universal Graves** - Túmulos ao morrer
- **TabTPS** - TPS no TAB
- **Styled Chat** - Chat formatado
- **Tailscale** - VPN mesh (acesso remoto seguro)

### Hardware Alvo
- **CPU**: Intel i3-6006U (2C/4T @ 2.0GHz)
- **RAM**: 4GB DDR3
- **Armazenamento**: HDD 1TB
- **SO**: Arch Linux Minimal

---

## 📁 Arquivos do Pacote

| Arquivo | Tamanho | Descrição |
|---------|---------|-----------|
| `README.md` | - | Este arquivo |
| `TUTORIAL.md` | ~15KB | Tutorial completo explicativo |
| `docs/Tailscale.md` | ~8KB | Guia de conexão para Linux/Windows |
| `docs/InstalacaoManual.md` | ~17KB | Documentação técnica completa |
| `docs/` | - | Guias modulares (Chunky, Styled Chat, comandos) |
| `install.sh` | ~16KB | **Instalador automatizado** |
| `start-server.sh` | ~3KB | Script de inicialização |
| `mc-manager.sh` | ~16KB | Gerenciamento + comandos facilitados |
| `minecraft.service` | ~1KB | Serviço systemd |
| `backup-cron.sh` | ~5KB | Backup automático |
| `setup-cron.sh` | ~4KB | Configurador de cron |

---

## 🚀 Instalação Rápida

### 1. Preparar Arquivos

```bash
# Criar pasta e entrar
mkdir ~/minecraft-setup && cd ~/minecraft-setup

# Copiar todos os arquivos do pacote para cá
# (use scp, pendrive, ou qualquer método)

# Verificar arquivos
ls -la
```

### 2. Executar Instalador

```bash
chmod +x *.sh
sudo ./install.sh
```

O instalador vai:

- ✅ Atualizar o sistema
- ✅ Instalar Java 21, Screen, ferramentas
- ✅ Criar usuário "minecraft"
- ✅ Instalar Adrenaline Modpack
- ✅ Baixar mods de QoL (versões atualizadas)
- ✅ Instalar Tailscale
- ✅ Configurar server.properties
- ✅ Configurar mods
- ✅ Criar serviço systemd
- ✅ Criar atalhos de comandos

**Tempo estimado:** 5-10 minutos

### 3. Configurar Tailscale

```bash
# Conectar Tailscale
sudo tailscale up

# Siga as instruções (link no navegador)
# Faça login e autorize

# Ver IP do Tailscale
sudo tailscale ip -4
# ANOTE ESTE IP!
```

### 4. Iniciar Servidor

```bash
sudo systemctl start minecraft
```

---

## 🎮 Comandos de Uso

### Atalhos Rápidos (Recomendado)

```bash
# Carregar atalhos (adicione ao ~/.bashrc)
source /opt/minecraft-server/comandos.sh

# Agora use:
mcstart      # Iniciar servidor
mcstop       # Parar servidor
mcrestart    # Reiniciar servidor
mcstatus     # Status do serviço
mclogs       # Ver logs
mcconsole    # Acessar console
mcbackup     # Fazer backup
mcchunky     # Menu do Chunky
mctailscale  # Status do Tailscale
mcdir        # Ir para a pasta do servidor
mcprops      # Editar server.properties
mcmod        # Gerenciar mods (add/remove/list)
```

### Gerenciamento Completo

```bash
# Básico
/opt/minecraft-server/mc-manager.sh start      # Iniciar
/opt/minecraft-server/mc-manager.sh stop       # Parar
/opt/minecraft-server/mc-manager.sh restart    # Reiniciar
/opt/minecraft-server/mc-manager.sh status     # Status
/opt/minecraft-server/mc-manager.sh console    # Console

# Comandos facilitados
/opt/minecraft-server/mc-manager.sh chunky     # Menu do Chunky
/opt/minecraft-server/mc-manager.sh players    # Listar jogadores
/opt/minecraft-server/mc-manager.sh say "Oi!"  # Enviar mensagem
/opt/minecraft-server/mc-manager.sh whitelist  # Gerenciar whitelist
/opt/minecraft-server/mc-manager.sh mod add chunky   # Instalar mod
/opt/minecraft-server/mc-manager.sh mod remove chunky # Remover mod

# Manutenção
/opt/minecraft-server/mc-manager.sh backup     # Backup
/opt/minecraft-server/mc-manager.sh update     # Atualizar modpack
```

### Via Systemd

```bash
sudo systemctl start minecraft     # Iniciar
sudo systemctl stop minecraft      # Parar
sudo systemctl restart minecraft   # Reiniciar
sudo systemctl status minecraft    # Status
sudo journalctl -u minecraft -f    # Logs
```

---

## 🌐 Como Conectar

### Método 1: Tailscale (Recomendado)

**No servidor:**
```bash
sudo tailscale ip -4
# Exemplo: 100.64.123.45
```

**No seu PC:**
```bash
# Instalar Tailscale
curl -fsSL https://tailscale.com/install.sh | sh  # Ubuntu/Debian
sudo pacman -S tailscale                           # Arch
sudo dnf install tailscale                         # Fedora

# Conectar
sudo tailscale up
```

**No Minecraft:**
- Server Address: `100.64.123.45:25565`

### Método 2: IP Local (mesma rede)

```bash
# No servidor
ip addr show | grep "inet " | head -1
# Exemplo: 192.168.1.50
```

**No Minecraft:**
- Server Address: `192.168.1.50:25565`

📖 **Guia completo:** `docs/Tailscale.md`

---

## 📝 Comandos no Jogo

### Essential Commands
```
/home                    - Ir para home
/sethome <nome>          - Definir home (máx: 3)
/delhome <nome>          - Deletar home
/spawn                   - Ir para spawn
/tpa <jogador>           - Pedir teleporte
/tpaccept / tpadeny      - Aceitar/recusar
/back                    - Voltar ao local anterior
/rtp                     - Teletransporte aleatório
/nickname set <jogador> <apelido> - Definir apelido
```

### Chunky
```
/chunky start            - Iniciar pré-geração
/chunky pause            - Pausar
/chunky continue         - Continuar
/chunky status           - Ver progresso
/chunky radius 1000      - Definir raio
```

### Spark (Profiler)
```
/spark health            - Saúde do servidor
/spark tps               - Ver TPS
```

---

## ⚡ Configurações de Performance

### Alocação de RAM
- **Mínima e Máxima**: 2560M (Xms e Xmx iguais para evitar re-alocação)
- **Recomendada**: 2560M (~2.5GB), deixando espaço para SO, Tailscale e ZRAM
- **Importante**: Java não aceita valor fracionário como `2.5G`; use `2560M` ou valores inteiros como `2G`/`3G`

### Configurações do Servidor
- **View Distance**: 6 chunks
- **Simulation Distance**: 4 chunks
- **Max Players**: 10 (recomendado: 5-8)
- **Sync Chunk Writes**: Desabilitado (melhora I/O em HDD)

### Flags JVM
```bash
-Xms2560M -Xmx2560M
-XX:+UseG1GC
-XX:+ParallelRefProcEnabled
-XX:MaxGCPauseMillis=200
-XX:+DisableExplicitGC
-XX:G1NewSizePercent=30
-XX:G1MaxNewSizePercent=40
-XX:G1HeapRegionSize=8M
-XX:G1ReservePercent=20
```

---

## 💾 Backup Automático

### Configurar
```bash
sudo /opt/minecraft-server/setup-cron.sh
```

### Manual
```bash
mcbackup
# ou
/opt/minecraft-server/mc-manager.sh backup
```

### Retenção
- Backups mantidos por **7 dias**
- Local: `/opt/minecraft-server/backups/`

---

## 📊 Monitoramento

```bash
htop                    # Uso de RAM e CPU
sudo iotop             # I/O do disco
tail -f /opt/minecraft-server/logs/latest.log  # Logs
mclogs                 # Logs do systemd
mcstatus               # Status detalhado
```

---

## 🛡️ Segurança

### Tailscale (Recomendado)
- Não precisa abrir portas no roteador
- Conexão criptografada
- IP fixo

### Comandos úteis
```bash
# Ver quem está conectado
sudo tailscale status

# Ver logs de acesso
sudo journalctl -u tailscaled -f
```

---

## ⚠️ Limitações do Hardware

Com **i3-6006U + 4GB RAM + HDD**:

| Aspecto | Recomendação |
|---------|--------------|
| Jogadores simultâneos | **5-8 máximo** |
| View Distance | 6 (não aumente) |
| Mods extras | Evite |
| Pré-geração | Execute antes de abrir |

---

## 🔧 Troubleshooting

### Servidor não inicia
```bash
sudo journalctl -u minecraft -n 50
sudo systemctl status minecraft
```

### OutOfMemoryError
```bash
# Reduzir MAX_RAM no start-server.sh
nano /opt/minecraft-server/start-server.sh
# Alterar: MAX_RAM="3072M"
# Para: MAX_RAM="2560M" (valor recomendado para este hardware)
```

### Não consegue conectar
```bash
# Verificar Tailscale
sudo tailscale status

# Verificar porta
sudo ss -tulpn | grep 25565
```

---

## 📖 Documentação

- **Tutorial completo:** `TUTORIAL.md`
- **Instalação manual detalhada:** `docs/InstalacaoManual.md`
- **Guia de conexão (Linux/Windows):** `docs/Tailscale.md`
- **Guia do Chunky:** `docs/Chunky.md`
- **Comandos do Essential Commands:** `docs/EssentialCommands.md`
- **Guia de títulos/chat:** `docs/StyledChat.md`

---

## 📞 Recursos

- [Adrenaline Modpack](https://modrinth.com/modpack/adrenaline)
- [Chunky](https://github.com/pop4959/Chunky)
- [Essential Commands](https://github.com/John-Paul-R/Essential-Commands)
- [Tailscale](https://tailscale.com)

---

## ✅ Checklist Pós-Instalação

- [ ] Instalação concluída
- [ ] Tailscale conectado
- [ ] IP do Tailscale anotado
- [ ] Servidor iniciado
- [ ] Pré-geração (Chunky) executada
- [ ] Backup automático configurado
- [ ] Atalhos carregados no ~/.bashrc
- [ ] Teste de conexão realizado

---

**Versão do Setup:** 3.0 (Revisado e Atualizado)  
**Data:** Março 2026
