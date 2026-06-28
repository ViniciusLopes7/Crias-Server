# Stack Minecraft

Documentação específica do stack Minecraft. Para visão geral, veja [../README.md](../README.md).

## Componentes instalados

| Arquivo | Função |
|---------|--------|
| `/opt/minecraft-server/start-server.sh` | Launcher runtime (JAVA_OPTS como array, valida Java 21+) |
| `/opt/minecraft-server/mc-manager.sh` | CLI de gerenciamento (start/stop/status/console/backup/health/...) |
| `/opt/minecraft-server/backup-cron.sh` | Backup com RCON save-lock + zstd + flock |
| `/opt/minecraft-server/setup-cron.sh` | Configura timer systemd de backup |
| `/opt/minecraft-server/minecraft.service` | Unit systemd (gerada via envsubst com hardening) |
| `/opt/minecraft-server/server.properties` | Config do servidor (gerado pelo installer) |
| `/opt/minecraft-server/runtime.env` | Tuning aplicado (heap, GC, G1 region size) |
| `/opt/minecraft-server/hardware-profile.env` | Perfil de hardware detectado + tier |
| `/opt/minecraft-server/server-icon.png` | Ícone do servidor (64x64 PNG) |
| `/opt/minecraft-server/comandos.sh` | Aliases de shell (autoload via `/etc/profile.d/`) |

## Operação diária

### Comandos principais

```bash
sudo systemctl start minecraft                              # iniciar
sudo systemctl stop minecraft                               # parar (graceful)
sudo systemctl restart minecraft                            # reiniciar
sudo systemctl status minecraft                             # status systemd
sudo /opt/minecraft-server/mc-manager.sh status             # status + hardware
sudo /opt/minecraft-server/mc-manager.sh console            # console RCON interativo
sudo /opt/minecraft-server/mc-manager.sh backup             # backup imediato
sudo /opt/minecraft-server/mc-manager.sh health             # porta + RCON
sudo /opt/minecraft-server/mc-manager.sh hardware-report    # perfil aplicado
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware        # recalibrar tier
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware HIGH   # forçar tier
sudo /opt/minecraft-server/setup-cron.sh                    # configurar timer de backup
```

### Aliases de shell

O installer gera `/opt/minecraft-server/comandos.sh` e adiciona autoload em `/etc/profile.d/crias-server.sh`. Para usar imediatamente:

```bash
source /etc/profile.d/crias-server.sh
```

| Alias | Equivalente |
|-------|-------------|
| `mcstart` | `sudo systemctl start minecraft` |
| `mcstop` | `sudo systemctl stop minecraft` |
| `mcrestart` | `sudo systemctl restart minecraft` |
| `mcstatus` | `sudo mc-manager.sh status` |
| `mclogs` | `sudo journalctl -u minecraft -f` |
| `mcconsole` | `sudo mc-manager.sh console` |
| `mcbackup` | `sudo mc-manager.sh backup` |
| `mcsetupcron` | `sudo mc-manager.sh setup-cron` |
| `mcdir` | `cd /opt/minecraft-server` |
| `mcprops` | `sudo nano /opt/minecraft-server/server.properties` |
| `mchw` | `sudo mc-manager.sh hardware-report` |
| `mcreconfig` | `sudo mc-manager.sh reconfigure-hardware` |

## Server Icon

O installer copia automaticamente `assets/images/branding/server-icon.png` para `/opt/minecraft-server/server-icon.png`. Requisitos do Minecraft:

- Formato: PNG
- Dimensões: **64x64 pixels**
- Tamanho máximo: ~100 KB

Para customizar, substitua `assets/images/branding/server-icon.png` **antes** da instalação, ou após instalar:

```bash
sudo cp seu_icon.png /opt/minecraft-server/server-icon.png
sudo chown minecraft:minecraft /opt/minecraft-server/server-icon.png
```

## Backup com RCON save-lock

Para garantir backups consistentes com servidor online, o `backup-cron.sh` usa RCON para pausar saves durante o `tar`:

1. `save-off` + `save-all` (pausa saves, força flush)
2. Aguarda 3s para flush completar
3. `tar -I zstd` dos diretórios `world/`, `world_nether/`, `world_the_end/`
4. `save-on` (reativa saves)

### Pré-requisitos: mcrcon

`mcrcon` não está nos repositórios oficiais do Arch Linux. Instale via AUR:

```bash
yay -S mcrcon
# ou construir manualmente:
git clone https://aur.archlinux.org/mcrcon.git
cd mcrcon && makepkg -si
```

### Configurar RCON no server.properties

O installer **não** configura RCON automaticamente (você precisa definir a senha). Edite `/opt/minecraft-server/server.properties`:

```properties
enable-rcon=true
rcon.password=sua_senha_segura_aqui
rcon.port=25575
```

Depois reinicie o servidor: `sudo systemctl restart minecraft`.

> **Atenção:** se `rcon.password` contiver aspas duplas (`"`) ou newlines, o `crias-agent` não conseguirá gerar o `agent.yaml` válido. Use senha alfanumérica.

### Sem RCON

Se `mcrcon` não estiver disponível ou RCON desabilitado, o backup roda em modo **best-effort** (sem pausar saves) — pode haver inconsistência rara em chunks salvos no momento do `tar`.

## Mods

Veja [mods.md](mods.md) para guias detalhados de:

- **Chunky** — pré-geração de chunks
- **Essential Commands** — home, tpa, spawn, rtp, back, nickname
- **Universal Graves** — tumba ao morrer
- **TabTPS** — monitor de TPS/MSPT
- **Styled Chat + Placeholder API** — customização de chat + títulos

Para listar a lista de mods instalados (CSV configurável em `config.env`):

```bash
grep MINECRAFT_QOL_MODS config.env
```

## Arquivos de runtime relevantes

| Arquivo | O que contém |
|---------|--------------|
| `/opt/minecraft-server/runtime.env` | `MIN_RAM`, `MAX_RAM`, `GC_MAX_PAUSE`, `G1_REGION_SIZE`, `BACKUP_RETENTION_DAYS`, `BACKUP_ZSTD_LEVEL` |
| `/opt/minecraft-server/hardware-profile.env` | `HW_TOTAL_RAM_MB`, `HW_CPU_CORES`, `HW_DISK_TYPE`, `HW_TIER`, todos os `MC_*` |
| `/opt/minecraft-server/server.properties` | Config padrão do Minecraft (porta, MOTD, view-distance, max-players, etc.) |

## Troubleshooting

### Servidor não inicia

```bash
sudo journalctl -u minecraft -n 50 --no-pager
sudo /opt/minecraft-server/mc-manager.sh health
```

Causas comuns:
- Java 21+ não instalado: `sudo pacman -S jdk21-openjdk`
- Porta 25565 em uso: `sudo ss -tlnp | grep 25565`
- `eula.txt` faltando: `echo "eula=true" > /opt/minecraft-server/eula.txt`

### OutOfMemoryError

Heap está em `/opt/minecraft-server/runtime.env` (`MIN_RAM`, `MAX_RAM`). Reduza via `reconfigure-hardware`:

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware LOW
sudo systemctl restart minecraft
```

### Backup falha

```bash
# Verificar se RCON está respondendo
sudo /opt/minecraft-server/mc-manager.sh health

# Verificar último backup
ls -lh /opt/minecraft-server/backups/

# Ver logs do timer systemd
sudo journalctl -u minecraft-backup.service -n 50
```

### Console interativo não abre

Requer `mcrcon` instalado (AUR). Veja a seção "Backup com RCON save-lock" acima para instruções de instalação.

## Veja também

- [mods.md](mods.md) — Guias dos mods QoL
- [../tutorial.md](../tutorial.md) — Tutorial de operação passo-a-passo
- [../tailscale.md](../tailscale.md) — Conexão via Tailscale
- [../restore.md](../restore.md) — Restore de backups
- [../security.md](../security.md) — Firewall, logs, hardening
