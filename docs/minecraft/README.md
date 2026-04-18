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

## Arquivos relevantes em runtime

- /opt/minecraft-server/runtime.env
- /opt/minecraft-server/hardware-profile.env
- /opt/minecraft-server/server.properties
