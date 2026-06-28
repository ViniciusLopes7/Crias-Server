# Stack Terraria

Documentação específica do stack Terraria. Para visão geral, veja [../README.md](../README.md).

## Componentes instalados

| Arquivo | Função |
|---------|--------|
| `/opt/terraria-server/start-terraria.sh` | Launcher runtime |
| `/opt/terraria-server/tt-manager.sh` | CLI de gerenciamento (start/stop/status/console/backup/health/...) |
| `/opt/terraria-server/backup-cron.sh` | Backup com zstd + flock |
| `/opt/terraria-server/setup-cron.sh` | Configura timer systemd de backup |
| `/opt/terraria-server/terraria.service` | Unit systemd (gerada via envsubst com hardening) |
| `/opt/terraria-server/config/serverconfig.txt` | Config do servidor |
| `/opt/terraria-server/runtime.env` | Tuning aplicado (backup retention, zstd level) |
| `/opt/terraria-server/hardware-profile.env` | Perfil de hardware detectado + tier |
| `/opt/terraria-server/comandos.sh` | Aliases de shell (autoload via `/etc/profile.d/`) |

## Operação diária

### Comandos principais

```bash
sudo systemctl start terraria                                   # iniciar
sudo systemctl stop terraria                                    # parar (graceful)
sudo systemctl restart terraria                                 # reiniciar
sudo systemctl status terraria                                  # status systemd
sudo /opt/terraria-server/tt-manager.sh status                  # status + hardware
sudo /opt/terraria-server/tt-manager.sh console                 # logs em tempo real (sem RCON nativo)
sudo /opt/terraria-server/tt-manager.sh backup                  # backup imediato
sudo /opt/terraria-server/tt-manager.sh health                  # verifica porta
sudo /opt/terraria-server/tt-manager.sh hardware-report         # perfil aplicado
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware            # recalibrar tier
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware HIGH       # forçar tier
sudo /opt/terraria-server/setup-cron.sh                         # configurar timer de backup
```

### Aliases de shell

O installer gera `/opt/terraria-server/comandos.sh` e adiciona autoload em `/etc/profile.d/crias-server.sh`. Para usar imediatamente:

```bash
source /etc/profile.d/crias-server.sh
```

| Alias | Equivalente |
|-------|-------------|
| `ttstart` | `sudo systemctl start terraria` |
| `ttstop` | `sudo systemctl stop terraria` |
| `ttrestart` | `sudo systemctl restart terraria` |
| `ttstatus` | `sudo tt-manager.sh status` |
| `ttlogs` | `sudo journalctl -u terraria -f` |
| `ttconsole` | `sudo tt-manager.sh console` (logs em tempo real) |
| `ttbackup` | `sudo tt-manager.sh backup` |
| `ttsetupcron` | `sudo tt-manager.sh setup-cron` |
| `ttdir` | `cd /opt/terraria-server` |
| `tthw` | `sudo tt-manager.sh hardware-report` |
| `ttreconfig` | `sudo tt-manager.sh reconfigure-hardware` |

## Diferenças em relação ao Minecraft

- **Sem RCON nativo**: Terraria Dedicated Server não tem protocolo RCON. Console interativo via `tt-manager.sh console` mostra logs em tempo real (não aceita comandos).
- **Sem mods QoL**: não há ecossistema de mods equivalente ao Fabric/Quilt.
- **Backup**: sem `save-off`/`save-on` (sem RCON). Apenas `tar` + `zstd` dos diretórios `worlds/` e `config/`.
- **Health check**: só verifica se a porta está em escuta (não há RCON para validar).

## Arquivos de runtime relevantes

| Arquivo | O que contém |
|---------|--------------|
| `/opt/terraria-server/runtime.env` | `BACKUP_RETENTION_DAYS`, `BACKUP_ZSTD_LEVEL` |
| `/opt/terraria-server/hardware-profile.env` | `HW_TOTAL_RAM_MB`, `HW_CPU_CORES`, `HW_DISK_TYPE`, `HW_TIER`, `TT_*` |
| `/opt/terraria-server/config/serverconfig.txt` | Config do servidor (porta, maxplayers, motd, worldpath, autocreate) |

## Troubleshooting

### Servidor não inicia

```bash
sudo journalctl -u terraria -n 50 --no-pager
sudo /opt/terraria-server/tt-manager.sh health
```

Causas comuns:
- Porta 7777 em uso: `sudo ss -tlnp | grep 7777`
- `TerrariaServer.bin.x86_64` sem permissão: `sudo chmod +x /opt/terraria-server/TerrariaServer.bin.x86_64`
- Download do servidor falhou (URL mudou): verifique `TERRARIA_DOWNLOAD_URL` em `config.env`

### Backup falha

```bash
# Verificar se serviço está ativo (backup pula se offline)
sudo systemctl is-active terraria

# Verificar último backup
ls -lh /opt/terraria-server/backups/

# Ver logs do timer systemd
sudo journalctl -u terraria-backup.service -n 50
```

## Veja também

- [../tutorial.md](../tutorial.md) — Tutorial de operação passo-a-passo
- [../tailscale.md](../tailscale.md) — Conexão via Tailscale
- [../restore.md](../restore.md) — Restore de backups
- [../security.md](../security.md) — Firewall, logs, hardening
