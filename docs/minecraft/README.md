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

O instalador gera o arquivo abaixo com aliases prontos para operacao diaria e configura autoload automaticamente via /etc/profile.d/crias-server.sh:

- /opt/minecraft-server/comandos.sh

As entradas sao idempotentes (nao duplicam em reinstalacoes).

Para usar imediatamente na sessao atual:

```bash
source /etc/profile.d/crias-server.sh
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

## Backups consistentes (producao)

Para aumentar consistencia de backup com servidor online, o script tenta usar RCON para pausar saves durante o `tar`.

Observacao sobre `mcrcon`:

`mcrcon` nao e fornecido pelos repositórios oficiais do Arch Linux; ele esta disponível apenas no AUR. As instrucoes abaixo refletem isso:

- Instalar via AUR (ex: `yay`):

```bash
yay -S mcrcon
```

- Ou construir manualmente a partir do PKGBUILD do AUR:

```bash
git clone https://aur.archlinux.org/mcrcon.git
cd mcrcon
makepkg -si
```

Se preferir evitar dependencias AUR, documente uma alternativa no runbook (ex: usar `rcon-cli` em outra linguagem ou scripts que usem a API do servidor).

No `server.properties`, configure:

```bash
enable-rcon=true
rcon.password=sua_senha_segura
rcon.port=25575
```

Com RCON ativo, o backup executa `save-off` + `save-all`, aguarda flush e depois `save-on`.
Sem RCON, o backup roda em modo best-effort.
