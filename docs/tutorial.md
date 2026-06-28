# Tutorial de Operação — Crias-Server

Fluxo único: instalar → operar → troubleshoot. Para detalhes específicos de cada stack, veja [minecraft/README.md](minecraft/README.md) ou [terraria/README.md](terraria/README.md).

## 1. Instalação

### Pré-requisitos

- Arch Linux (ou distro com `pacman` + `systemd`)
- Acesso root (`sudo`)
- Conexão com internet (para baixar pacotes e binários)

### Passo a passo

```bash
# 1. Clonar o repositório (ou usar ISO bootável)
git clone https://github.com/ViniciusLopes7/Crias-Server.git
cd Crias-Server

# 2. (Opcional) Editar config.env com suas preferências
nano config.env

# 3. Rodar o instalador
chmod +x install.sh
sudo ./install.sh
```

### O que o instalador pergunta

1. **Qual stack?** Minecraft ou Terraria
2. **Opções globais** (opcional revisar):
   - Forçar tier de hardware (LOW/MID/HIGH ou vazio para auto)
   - Instalar Tailscale? (recomendado)
   - Aplicar tuning de sistema? (zram/scheduler/cpupower)
   - Limpar stack oposto após instalar?
3. **Parâmetros específicos do jogo**:
   - Minecraft: usuário, diretório, porta, MOTD, versão, loader, modpack, QoL mods
   - Terraria: usuário, diretório, porta, nome do mundo, MOTD, URL de download
4. **Instalar agente de controle remoto?** (crias-agent — opcional, para controle via Discord)

### Instalação não-interativa (CI/automação)

```bash
sudo -E NON_INTERACTIVE=true \
        ACCEPT_EULA=true \
        SERVER_TYPE=minecraft \
        INSTALL_AGENT=true \
        ./install.sh
```

### Validação em DRY_RUN (sem alterar o host)

```bash
sudo -E NON_INTERACTIVE=true DRY_RUN=true SERVER_TYPE=minecraft ./install.sh
```

---

## 2. Operação diária

### Start/Stop/Status

```bash
# Minecraft
sudo systemctl start minecraft
sudo systemctl stop minecraft
sudo systemctl status minecraft
mcstatus   # alias (após source /etc/profile.d/crias-server.sh)

# Terraria
sudo systemctl start terraria
sudo systemctl stop terraria
sudo systemctl status terraria
ttstatus   # alias
```

### Console

```bash
# Minecraft (requer mcrcon instalado via AUR)
mcconsole
# Ctrl+A, D para sair do console sem parar o servidor

# Terraria (apenas logs em tempo real — sem RCON nativo)
ttconsole
# Ctrl+C para sair
```

### Logs

```bash
# Acompanhar logs em tempo real
mclogs    # alias para: sudo journalctl -u minecraft -f
ttlogs    # alias para: sudo journalctl -u terraria -f

# Últimas 50 linhas
sudo journalctl -u minecraft -n 50 --no-pager
sudo journalctl -u terraria -n 50 --no-pager
```

### Carregar aliases de shell

O instalador cria `/etc/profile.d/crias-server.sh` com autoload dos aliases. Para usar imediatamente na sessão atual:

```bash
source /etc/profile.d/crias-server.sh
```

Ou abra um novo terminal (aliases carregam automaticamente em shells de login).

---

## 3. Tuning de hardware

### Como funciona

Durante a instalação, o sistema detecta:

- RAM total e disponível
- Cores e threads de CPU
- Tipo de disco (HDD/SSD/NVME)
- Filesystem (ZFS/Btrfs/LVM detectados — tuning de bloco pode ser pulado)

Com base nisso, aplica tier **LOW**, **MID** ou **HIGH** que afeta:

- Parâmetros do jogo (max-players, view-distance, simulation-distance, heap)
- Limites de serviço systemd (`MemoryMax`)
- Políticas de host (zram, swappiness, scheduler, cpupower governor)
- Retenção de backup (LOW=5 dias, MID=7, HIGH=10)

| Tier | Critério aproximado | Foco |
|------|---------------------|------|
| LOW  | ≤3 GB RAM ou ≤2 cores | Estabilidade em host fraco |
| MID  | ≤12 GB RAM ou ≤6 cores | Equilíbrio entre desempenho e consumo |
| HIGH | >12 GB RAM e >6 cores | Melhor throughput e capacidade |

### Override manual

Em `config.env`:

```bash
FORCE_HARDWARE_TIER="HIGH"   # LOW, MID, HIGH ou vazio para auto
```

### Recalibrar após mudança de hardware

Se você trocar VM, adicionar RAM, mudar de HDD para SSD, etc.:

```bash
# Detectar novo hardware e reaplicar tuning
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware

# Forçar tier específico
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware HIGH
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware LOW

# Reiniciar para aplicar no runtime
sudo systemctl restart minecraft
# ou
sudo systemctl restart terraria
```

### Ver perfil aplicado

```bash
mchw   # Minecraft (alias)
tthw   # Terraria (alias)
```

---

## 4. Backup

### Backup imediato

```bash
mcbackup   # Minecraft (alias)
ttbackup   # Terraria (alias)
```

### Configurar timer systemd

```bash
mcsetupcron   # Minecraft (alias)
ttsetupcron   # Terraria (alias)
```

O script pergunta a frequência:
1. Diário às 03:00
2. Duas vezes por dia (03:00 e 15:00)
3. A cada 4 horas
4. Semanal (domingo às 03:00)
5. Personalizado (linha `OnCalendar=` ou `OnUnitActiveSec=`)

### Verificar backups

```bash
ls -lh /opt/minecraft-server/backups/
ls -lh /opt/terraria-server/backups/

# Logs do timer
sudo journalctl -u minecraft-backup.service -n 50
sudo journalctl -u terraria-backup.service -n 50
```

### Restore

Veja [restore.md](restore.md).

---

## 5. Cleanup do stack oposto

Se `CLEANUP_OTHER_STACK=true` (default), o instalador detecta stack oposto e pergunta se deseja desativá-lo.

**O que é desativado (não destrutivo):**
- `systemctl stop <stack>` + `systemctl disable <stack>`
- Remoção do autoload de aliases em `/etc/profile.d/crias-server.sh`
- Remoção de entradas de crontab do backup

**O que NÃO é feito:**
- Dados em `/opt/` são preservados
- Usuários do sistema são preservados
- Backups existentes são preservados

---

## 6. Banner e identidade visual

O instalador tenta exibir um banner ASCII antes do header padrão. Ordem de busca:

1. `assets/images/branding/banner.txt`
2. `assets/branding/banner.txt`
3. `/etc/crias/banner.txt`

Para customizar, substitua `assets/images/branding/banner.txt` antes da instalação.

---

## 7. Troubleshooting

### Servidor não inicia

```bash
# 1. Verificar status detalhado
sudo systemctl status minecraft
# ou
sudo systemctl status terraria

# 2. Ver logs
sudo journalctl -u minecraft -n 50 --no-pager
# ou
sudo journalctl -u terraria -n 50 --no-pager

# 3. Health check (Minecraft: porta + RCON; Terraria: só porta)
sudo /opt/minecraft-server/mc-manager.sh health
sudo /opt/terraria-server/tt-manager.sh health
```

### OutOfMemoryError (Minecraft)

Heap está em `/opt/minecraft-server/runtime.env`. Para reduzir:

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware LOW
sudo systemctl restart minecraft
```

### Servidor lento (TPS baixo)

```bash
# Minecraft: instalar TabTPS (já vem com QoL mods) e ver TPS na tab list
# Ou via console:
mcconsole
# digite: tps

# Verificar hardware profile
mchw
tthw
```

### Porta em uso

```bash
sudo ss -tlnp | grep -E '25565|7777'

# Matar processo se necessário
sudo fuser -k 25565/tcp
```

### Tailscale não conecta

```bash
sudo systemctl status tailscaled
sudo tailscale status
sudo tailscale up --force-reauth
```

Veja [tailscale.md](tailscale.md) para mais detalhes.

### Backup falha

```bash
# Verificar se serviço está ativo (backup pula se offline)
sudo systemctl is-active minecraft
# ou
sudo systemctl is-active terraria

# Verificar espaço em disco
df -h /opt/

# Verificar logs do timer
sudo journalctl -u minecraft-backup.service -n 50
sudo journalctl -u terraria-backup.service -n 50
```

### Console interativo não abre (Minecraft)

Requer `mcrcon` instalado via AUR:

```bash
yay -S mcrcon
# ou
git clone https://aur.archlinux.org/mcrcon.git
cd mcrcon && makepkg -si
```

---

## 8. Modo DRY_RUN

Para testar o installer sem alterar o host:

```bash
sudo -E NON_INTERACTIVE=true DRY_RUN=true SERVER_TYPE=minecraft ./install.sh
```

Em DRY_RUN:
- `pacman -S` é pulado
- `useradd` é pulado
- `systemctl` é pulado
- Downloads são pulados (não consome rede)
- Templates `.service` são gerados mas não escritos em `/etc/systemd/system/`
- Variável `DRY_RUN=true` é propagada para subprocessos

Útil para:
- Validar `config.env` antes de instalar de verdade
- CI (testes de contrato)
- Debug de lógica do installer

---

## 9. Segurança e operação

Para pontos operacionais que não devem ser esquecidos no dia a dia (firewall, rotação de logs, health checks, limitações de MAC), veja [security.md](security.md).

---

## 10. Veja também

- [minecraft/README.md](minecraft/README.md) — Stack Minecraft (comandos, mods, troubleshooting)
- [minecraft/mods.md](minecraft/mods.md) — Guias dos mods QoL (Chunky, EssentialCommands, etc.)
- [terraria/README.md](terraria/README.md) — Stack Terraria
- [tailscale.md](tailscale.md) — Conexão via Tailscale (VPN + Funnel)
- [restore.md](restore.md) — Restore de backups
- [security.md](security.md) — Firewall, logs, hardening
- [../README.md](../README.md) — README principal (visão geral)
- [../ROADMAP.md](../ROADMAP.md) — Status e próximos passos
