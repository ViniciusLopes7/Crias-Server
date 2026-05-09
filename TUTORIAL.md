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

O instalador cria os arquivos de aliases e adiciona autoload automaticamente via /etc/profile.d/crias-server.sh.

As entradas sao idempotentes (nao duplicam em reinstalacoes).

Para usar imediatamente na sessao atual:

```bash
source /etc/profile.d/crias-server.sh
```

Atalhos mais usados:

- `mcstart`, `mclogs`, `mcconsole`, `mcbackup`, `mcreconfig`
- `ttstart`, `ttlogs`, `ttconsole`, `ttbackup`, `ttreconfig`

Observacao: os comandos do `mc-manager.sh`/`tt-manager.sh` lidam com permissao automaticamente (executando `sudo` quando necessario e rodando backups como o usuario do servidor quando possivel). Isso evita problemas quando o nome do usuario do servidor foi alterado.

`mcstatus`/`ttstatus` apresentam um resumo via `systemctl status` (e voce pode usar `mclogs`/`ttlogs` para acompanhar logs em tempo real).

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

Se habilitado, o instalador executa uma desativacao segura do stack nao selecionado.

Por padrao o que acontece:

- Desativacao (stop + disable) da unidade systemd do stack oposto.
- Remocao do autoload de aliases gerado pelo instalador.
- Remocao de entradas de cron criadas pelo instalador (quando aplicavel).

Operacoes destrutivas como excluir `/opt` ou remover usuarios nao fazem parte do fluxo padrao e requerem um comando opt-in separado com confirmacao explicita.

## 8. Banner e identidade visual

O instalador tenta exibir um banner customizado antes do header padrão. O arquivo é lido nesta ordem:

- `assets/images/branding/banner.txt`
- `assets/branding/banner.txt`
- `/etc/crias/banner.txt`

## 9. Estrutura sem legados

Use sempre os caminhos modulares abaixo para operacao diaria e manutencao:

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
