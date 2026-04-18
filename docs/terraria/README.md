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

## Arquivos relevantes em runtime

- /opt/terraria-server/runtime.env
- /opt/terraria-server/hardware-profile.env
- /opt/terraria-server/config/serverconfig.txt
