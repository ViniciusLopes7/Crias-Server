# Tutorial de Operação — Crias-Server

Instalar → operar → troubleshoot. Para detalhes específicos de cada stack, veja [mminecraft/README.md](mminecraft/README.md) ou [terraria/README.md](terraria/README.md).

## 1. Instalação

### Pré-requisitos

- **Arch Linux instalado** (use a [ISO oficial](https://archlinux.org/download/) + `archinstall`)
- Acesso root (`sudo`)
- Conexão com internet (pacman, downloads, mods)

### Fluxo principal (recomendado)

```bash
# 1. Instale o Arch Linux (se ainda não tem):
#    - Baixe a ISO oficial em https://archlinux.org/download/
#    - Boot pela USB/CD
#    - Rode: archinstall
#    - Crie usuário, timezone, hostname, disco, network
#    - Reboot

# 2. Após reboot, login com o usuário criado no archinstall

# 3. Baixe o Crias-Server (bootstrap com verificação SHA256):
curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash
# O bootstrap baixa a release do GitHub, verifica checksum, extrai em /opt/crias-server/
# e roda o install.sh automaticamente.

# 4. Siga o TUI (menus interativos com gum):
#    - Stack: Minecraft ou Terraria
#    - Opções globais (Tailscale, tuning, SSH, monitor)
#    - Opções do jogo (porta, loader, versão, modpack, MOTD, server icon)
#    - Resumo → Confirmar → instala
```

### Fluxo alternativo (git clone)

```bash
git clone https://github.com/ViniciusLopes7/Crias-Server.git
cd Crias-Server
sudo ./install.sh
```

### Instalação não-interativa (CI/automação)

```bash
sudo -E NON_INTERACTIVE=true \
        ACCEPT_EULA=true \
        SERVER_TYPE=minecraft \
        ./install.sh
```

### Validação em DRY_RUN (sem alterar o host)

```bash
sudo -E NON_INTERACTIVE=true DRY_RUN=true SERVER_TYPE=minecraft ./install.sh
```

### Flags importantes em `config.env`

| Flag | Default | Descrição |
|------|---------|-----------|
| `NON_INTERACTIVE` | `false` | Desativa prompts (exige `SERVER_TYPE`) |
| `DRY_RUN` | `false` | Evita operações destrutivas |
| `ACCEPT_EULA` | `false` | Aceita EULA Mojang (necessário p/ Minecraft) |
| `SSH_USER` | `crias` | Nome do usuário SSH (customizável, com validação) |
| `INSTALL_MONITOR_TOOLS` | `false` | Instala btop + ncdu no host |
| `MINECRAFT_SERVER_ICON_URL` | vazio | URL de um PNG 64x64 para `server-icon.png` |
| `BACKUP_REMOTE_PATH` | vazio | `user@host:/path/` para rsync de backup remoto |
| `BACKUP_NOTIFY_WEBHOOK` | vazio | URL de webhook Discord para notificações de backup |

---

## 2. Operação diária

### Start / Stop / Status

```bash
# Minecraft
sudo systemctl start minecraft
sudo systemctl stop minecraft
sudo systemctl status minecraft

# Terraria
sudo systemctl start terraria
sudo systemctl stop terraria
sudo systemctl status terraria
```

### Hub TUI (menu interativo — não precisa lembrar comandos)

```bash
sudo crias-tui
# Menu: Servidor / Monitoramento / Backup / Sistema / Sair
```

### Console do jogo

```bash
# Minecraft (requer mcrcon via AUR)
mcconsole

# Terraria (logs em tempo real — sem RCON nativo)
ttconsole
```

### Logs

```bash
# Acompanhar em tempo real
mclogs    # alias: sudo journalctl -u minecraft -f
ttlogs    # alias: sudo journalctl -u terraria -f

# Últimas 50 linhas
sudo journalctl -u minecraft -n 50 --no-pager
```

### Monitoramento (btop / ncdu)

```bash
# CPU/RAM/processos
sudo mc-manager.sh monitor        # ou: sudo crias-tui → Monitoramento → btop

# Uso de disco (no diretório do servidor)
sudo mc-manager.sh monitor disk   # ncdu interativo

# Aliases após source /etc/profile.d/crias-server.sh
mcstatus   # status do Minecraft
ttstatus   # status do Terraria
mchw       # perfil de hardware do Minecraft
tthw       # perfil de hardware do Terraria
```

---

## 3. Tuning de hardware

O sistema detecta RAM, CPU e tipo de disco automaticamente e aplica um tier:

| Tier | Critério | Foco |
|------|----------|------|
| LOW | ≤3 GB RAM ou ≤2 cores | Estabilidade em host fraco |
| MID | ≤12 GB RAM ou ≤6 cores | Equilíbrio |
| HIGH | >12 GB RAM e >6 cores | Throughput máximo |

**Override manual** em `config.env`:
```bash
FORCE_HARDWARE_TIER="HIGH"   # LOW, MID, HIGH ou vazio para auto
```

**Recalibrar após mudança de hardware:**
```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware HIGH  # forçar tier
```

Veja [hardware-tuning.md](hardware-tuning.md) para detalhes.

---

## 4. Backup

### Backup imediato

```bash
mcbackup   # alias para: sudo /opt/minecraft-server/mc-manager.sh backup
ttbackup   # alias para: sudo /opt/terraria-server/tt-manager.sh backup
```

### Configurar timer systemd

```bash
mcsetupcron   # pergunta frequência: diário, 2x/dia, 4h, semanal
ttsetupcron
```

### Backup remoto (rsync)

Se `BACKUP_REMOTE_PATH` estiver setado em `config.env`, o backup sincroniza automaticamente via rsync após criar o `.tar.zst` local:
```bash
BACKUP_REMOTE_PATH="user@server:/backups/crias/"
```

### Notificação Discord

Se `BACKUP_NOTIFY_WEBHOOK` estiver setado, recebe notificação (embed verde/vermelho) no Discord após cada backup:
```bash
BACKUP_NOTIFY_WEBHOOK="https://discord.com/api/webhooks/..."
```

### Restore

Veja [restore.md](restore.md).

---

## 5. SSH

Se você respondeu "sim" a "Habilitar SSH" durante a instalação:

- Usuário criado com `sudo` (nome customizável via `SSH_USER` em `config.env`)
- `PermitRootLogin no` (root proibido via SSH)
- Conexão: `ssh <usuario>@<ip-do-servidor>`

Veja [security.md](security.md) para hardening adicional.

---

## 6. MOTD personalizado

O MOTD do Minecraft aceita códigos de cor (`§6` = gold, `§l` = bold, etc.) e `\n` para nova linha.

**Gerador visual:** https://comunidademc.com.br/ferramentas/motd/

Durante a instalação, o TUI mostra:
1. `tui_help "motd"` — explica os códigos + link do gerador
2. `tui_input` — você cola o MOTD gerado
3. `motd_preview` — preview colorido (mapeia § para ANSI)

Ou edite direto em `config.env`:
```bash
MINECRAFT_MOTD="§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r"
```

---

## 7. Server icon

Durante a instalação, o TUI pergunta se quer configurar um `server-icon.png`:
- Você fornece uma URL de imagem PNG 64x64
- O instalador baixa e coloca em `$SERVER_DIR/server-icon.png`
- Se o download falhar, o servidor funciona sem icon (warning)

Ou via `config.env`:
```bash
MINECRAFT_SERVER_ICON_URL="https://exemplo.com/icon.png"
```

---

## 8. Controle remoto via Discord (opcional)

Se `INSTALL_AGENT=true`, o instalador configura:
- **crias-agent** (Go) — gRPC em localhost:8473
- **crias-bot** (Python) — discord.py no Railway

Slash commands: `/mc start|stop|restart|status|players|say|console|health`

Veja [discord-agent/README.md](../discord-agent/README.md) e [discord-bot/README.md](../discord-bot/README.md).

---

## 9. Troubleshooting

### Servidor não inicia

```bash
sudo systemctl status minecraft
sudo journalctl -u minecraft -n 50 --no-pager
sudo /opt/minecraft-server/mc-manager.sh health
```

### OutOfMemoryError (Minecraft)

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware LOW
sudo systemctl restart minecraft
```

### Porta em uso

```bash
sudo ss -tlnp | grep -E '25565|7777'
sudo fuser -k 25565/tcp
```

### Sem internet na VM (VirtualBox)

```bash
systemctl start NetworkManager
nmcli device connect enp0s3
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

### Backup falha

```bash
sudo systemctl is-active minecraft    # backup pula se servidor offline
df -h /opt/                            # verifica espaço
sudo journalctl -u minecraft-backup.service -n 50
```

---

## 10. Veja também

- [mminecraft/README.md](mminecraft/README.md) — Stack Minecraft
- [terraria/README.md](terraria/README.md) — Stack Terraria
- [hardware-tuning.md](hardware-tuning.md) — Tiers e recalibração
- [restore.md](restore.md) — Restore de backups
- [security.md](security.md) — Firewall, SSH, hardening
- [tui.md](tui.md) — Como o TUI funciona
- [../CHANGELOG.md](../CHANGELOG.md) — Histórico de versões
- [../ROADMAP.md](../ROADMAP.md) — Próximos passos
