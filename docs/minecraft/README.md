# Stack Minecraft

## Componentes

- minecraft/install.sh
- minecraft/start-server.sh
- minecraft/mc-manager.sh
- minecraft/backup-cron.sh
- minecraft/setup-cron.sh
- minecraft/minecraft.service

## Comandos principais

```bash
sudo systemctl start minecraft
sudo systemctl stop minecraft
sudo /opt/minecraft-server/mc-manager.sh status
sudo /opt/minecraft-server/mc-manager.sh console
sudo /opt/minecraft-server/mc-manager.sh backup
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
```

## Aliases de comandos

O instalador gera o arquivo abaixo com aliases prontos para operacao diaria e configura autoload automaticamente no ~/.bashrc do usuario operador:

- /opt/minecraft-server/comandos.sh

As entradas sao idempotentes (nao duplicam em reinstalacoes).

Para usar imediatamente na sessao atual:

```bash
source ~/.bashrc
```

Aliases disponiveis:

- mcstart
- mcstop
- mcrestart
- mcstatus
- mclogs
- mcconsole
- mcbackup
- mcdir
- mcprops
- mchw
- mcreconfig

## Arquivos relevantes em runtime

- /opt/minecraft-server/runtime.env
- /opt/minecraft-server/hardware-profile.env
- /opt/minecraft-server/server.properties
