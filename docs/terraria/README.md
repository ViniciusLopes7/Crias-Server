# Stack Terraria

## Componentes

- terraria/install.sh
- terraria/start-terraria.sh
- terraria/tt-manager.sh
- terraria/backup-cron.sh
- terraria/setup-cron.sh
- terraria/terraria.service

## Comandos principais

```bash
sudo systemctl start terraria
sudo systemctl stop terraria
sudo /opt/terraria-server/tt-manager.sh status
sudo /opt/terraria-server/tt-manager.sh console
sudo /opt/terraria-server/tt-manager.sh backup
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware
```

## Aliases de comandos

O instalador gera o arquivo abaixo com aliases prontos para operacao diaria e configura autoload automaticamente no ~/.bashrc do usuario operador:

- /opt/terraria-server/comandos.sh

As entradas sao idempotentes (nao duplicam em reinstalacoes).

Para usar imediatamente na sessao atual:

```bash
source ~/.bashrc
```

Aliases disponiveis:

- ttstart
- ttstop
- ttrestart
- ttstatus
- ttlogs
- ttconsole
- ttbackup
- ttdir
- tthw
- ttreconfig

## Arquivos relevantes em runtime

- /opt/terraria-server/runtime.env
- /opt/terraria-server/hardware-profile.env
- /opt/terraria-server/config/serverconfig.txt
