# Tutorial de Operacao - Crias-Server

Este tutorial descreve o fluxo novo modular (Minecraft ou Terraria) e como operar tuning por hardware no dia a dia.

## 1. Instalacao

```bash
chmod +x install.sh
sudo ./install.sh
```

No inicio do instalador:

1. Escolha a stack (Minecraft ou Terraria).
2. Revise opcoes globais (tailscale, cleanup, override de tier).
3. Revise parametros especificos do jogo selecionado.

## 2. Como funciona o tuning automatico

Durante a instalacao, o sistema detecta:

- RAM total/disponivel
- Cores/threads de CPU
- Tipo de disco (HDD, SSD, NVME)

Com base nisso, aplica tier LOW, MID ou HIGH.

O tier tambem define limites de memoria do servico systemd (MemoryMax), alem dos parametros do jogo.

Para forcar tier manualmente, use em config.env:

```bash
FORCE_HARDWARE_TIER="MID"
```

## 3. Recalibracao de hardware

Use quando trocar VM, aumentar RAM, mudar de disco, etc.

Minecraft:

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
```

Terraria:

```bash
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware
```

Voce tambem pode forcar tier no comando:

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware HIGH
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware LOW
```

## 4. Operacao diaria

### Minecraft

```bash
sudo systemctl start minecraft
sudo systemctl stop minecraft
sudo systemctl status minecraft
sudo /opt/minecraft-server/mc-manager.sh console
sudo /opt/minecraft-server/mc-manager.sh backup
```

### Terraria

```bash
sudo systemctl start terraria
sudo systemctl stop terraria
sudo systemctl status terraria
sudo /opt/terraria-server/tt-manager.sh console
sudo /opt/terraria-server/tt-manager.sh backup
```

### Aliases (opcional, recomendado)

O instalador cria os arquivos de aliases e adiciona autoload no ~/.bashrc automaticamente.

As entradas sao idempotentes (nao duplicam em reinstalacoes).

Para usar imediatamente na sessao atual:

```bash
source ~/.bashrc
```

Atalhos mais usados:

- `mcstart`, `mclogs`, `mcconsole`, `mcbackup`, `mcreconfig`
- `ttstart`, `ttlogs`, `ttconsole`, `ttbackup`, `ttreconfig`

Observacao: os aliases que interagem com o processo do jogo (`mcconsole`, `mcbackup`, `mcreconfig`, `ttconsole`, `ttbackup`, `ttreconfig`) executam o gerenciador de runtime como o `MINECRAFT_USER`/`TERRARIA_USER` automaticamente (usando `sudo -u`). Isso evita problemas quando o nome do usuario do servidor foi alterado.

`mcstatus`/`ttstatus` agora apresentam um resumo conciso via `mc-manager.sh status` / `tt-manager.sh status` em vez de `systemctl status`, tornando mais facil identificar PID, uso de CPU/RAM e uptime.

## 5. Backups

Cada stack possui:

- Script de backup imediato
- Script de setup de cron
- Retencao dinamica baseada no tier

Configuracao de cron:

```bash
sudo /opt/minecraft-server/setup-cron.sh
sudo /opt/terraria-server/setup-cron.sh
```

## 6. Restauração

Se precisar voltar um mundo ou configuração, siga o runbook em:

- [docs/shared/Restore.md](docs/shared/Restore.md)

## 7. Cleanup do stack oposto

Se habilitado, o instalador remove o stack nao selecionado.

Remocoes previstas:

- Servico systemd oposto
- Usuario oposto
- Diretorio /opt do stack oposto
- Entradas de cron associadas

A remocao destrutiva exige confirmacao explicita.

## 8. Banner e identidade visual

O instalador tenta exibir um banner customizado antes do header padrão. O arquivo é lido nesta ordem:

- `assets/images/branding/banner.txt`
- `assets/branding/banner.txt`
- `/etc/crias/banner.txt`

## 9. Estrutura sem legados

Os scripts legados na raiz foram removidos para manter o repositorio limpo.

Use sempre os caminhos modulares:

- minecraft/start-server.sh
- minecraft/mc-manager.sh
- minecraft/backup-cron.sh
- minecraft/setup-cron.sh
- terraria/start-terraria.sh
- terraria/tt-manager.sh
- terraria/backup-cron.sh
- terraria/setup-cron.sh

## 8. Dica de troubleshooting

- Ver perfil aplicado:

```bash
sudo /opt/minecraft-server/mc-manager.sh hardware-report
sudo /opt/terraria-server/tt-manager.sh hardware-report
```

- Ver logs de servico:

```bash
sudo journalctl -u minecraft -f
sudo journalctl -u terraria -f
```
