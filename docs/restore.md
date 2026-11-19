# Restore de Backups

Runbook para restaurar mundos e configuração a partir de backups gerados pelo `backup-cron.sh`.

## Escopo do backup

O conteúdo do arquivo depende da versão que o gerou:

- **Backups atuais (CR-14)**: mundos + `server.properties` + `config/` + `mods/`
  (Minecraft) ou `worlds/` + `config/` + `Worlds/` + `Mods/` (Terraria com
  tModLoader). `mods/` e `Mods/` podem ser excluídos com `BACKUP_INCLUDE_MODS=false`
  no `runtime.env`.
- **Backups legados**: apenas os diretórios de mundo (`world/`, `world_nether/`,
  `world_the_end/` para Minecraft; `worlds/` + `config/` para Terraria).

**Nunca presuma que uma entrada existe**: liste o conteúdo do archive primeiro
(passo 4) e restaure apenas o que estiver presente. Backups antigos podem não
ter `world_nether/`; servidores vanilla guardam as dimensões dentro do próprio
`world/` e não têm pastas separadas.

## Pré-requisitos

- Acesso SSH ao host com permissão `sudo`
- Backup disponível em `/opt/<stack>/backups/` ou em armazenamento externo
- Servidor parado durante o restore

## Passo a passo (exemplo Minecraft)

### 1. Parar o serviço

```bash
sudo systemctl stop minecraft
```

### 2. Snapshot do estado atual (segurança)

```bash
sudo cp -a /opt/minecraft-server /opt/minecraft-server.pre-restore-$(date +%Y%m%d-%H%M%S)
```

### 3. Listar backups disponíveis

```bash
ls -lh /opt/minecraft-server/backups/
# minecraft-backup-YYYYMMDD-HHMMSS.tar.zst
```

### 4. Extrair backup em diretório temporário E listar o conteúdo

```bash
tmpdir=$(mktemp -d)
sudo tar -I "zstd -d" -xf /opt/minecraft-server/backups/minecraft-backup-YYYYMMDD-HHMMSS.tar.zst -C "$tmpdir"
ls -la "$tmpdir"
```

O `ls` decide o que o passo 5 vai restaurar: **só restaure entradas que
existem no archive** (CR-26 — o fluxo antigo copiava `world_nether/` e
`world_the_end/` incondicionalmente e falhava em backups sem essas pastas).

### 5. Substituir APENAS as entradas presentes no backup

```bash
# ATENÇÃO: --delete remove arquivos não presentes no backup
sudo rsync -a --delete "$tmpdir/world/" /opt/minecraft-server/world/

# Dimensões separadas existem apenas em servidores Bukkit/Spigot/Paper-like;
# restaure SOMENTE se apareceram no ls do passo 4:
sudo rsync -a --delete "$tmpdir/world_nether/" /opt/minecraft-server/world_nether/
sudo rsync -a --delete "$tmpdir/world_the_end/" /opt/minecraft-server/world_the_end/

# Configuração (presente em backups atuais; opcional em legados):
sudo rsync -a --delete "$tmpdir/config/" /opt/minecraft-server/config/
sudo cp -a "$tmpdir/server.properties" /opt/minecraft-server/server.properties

# Mods (presente em backups atuais com BACKUP_INCLUDE_MODS=true):
sudo rsync -a --delete "$tmpdir/mods/" /opt/minecraft-server/mods/
```

> **Nota**: mundos com `level-name` customizado têm pastas com o nome
> correspondente (ex.: `reino/`, `reino_nether/`) — o backup usa o nome
> efetivo lido de `server.properties`.

### 6. Ajustar permissões

```bash
sudo chown -R minecraft:minecraft /opt/minecraft-server
```

### 7. Iniciar serviço e monitorar

```bash
sudo systemctl start minecraft
sudo journalctl -u minecraft -f
```

### 8. Verificar integridade in-game

Entrar no servidor e confirmar que mundos/características estão corretas.

### 9. Limpar diretório temporário

```bash
rm -rf "$tmpdir"
```

## Exemplo Terraria

Mesmo fluxo, mas com diretórios diferentes:

```bash
sudo systemctl stop terraria
sudo cp -a /opt/terraria-server /opt/terraria-server.pre-restore-$(date +%Y%m%d-%H%M%S)

tmpdir=$(mktemp -d)
sudo tar -I "zstd -d" -xf /opt/terraria-server/backups/terraria-backup-YYYYMMDD-HHMMSS.tar.zst -C "$tmpdir"
ls -la "$tmpdir"

# Restaure apenas o que aparecer no ls acima:
sudo rsync -a --delete "$tmpdir/worlds/" /opt/terraria-server/worlds/
sudo rsync -a --delete "$tmpdir/config/" /opt/terraria-server/config/

# tModLoader (presente apenas quando o servidor usa tML):
sudo rsync -a --delete "$tmpdir/Worlds/" /opt/terraria-server/Worlds/
sudo rsync -a --delete "$tmpdir/Mods/" /opt/terraria-server/Mods/

sudo chown -R terraria:terraria /opt/terraria-server
sudo systemctl start terraria
sudo journalctl -u terraria -f

rm -rf "$tmpdir"
```

## Backup remoto

Se o backup estiver em outro host, copie primeiro:

```bash
# Do host de origem para o servidor
scp user@origem:/path/backup.tar.zst /opt/minecraft-server/backups/

# Ou via rsync (mais eficiente para backups grandes)
rsync -avz user@origem:/path/backups/ /opt/minecraft-server/backups/
```

## Observações

- **`DRY_RUN`**: backups gerados em modo `DRY_RUN=true` (CI) **não são válidos** para restore em produção — são apenas simulações.
- **Teste de restore**: deve ser parte do plano de manutenção (periodicidade recomendada: mensal).
- **RCON save-lock**: backups do Minecraft com RCON habilitado são consistentes (sem chunks parcialmente salvos). Backups sem RCON são best-effort. Se um backup falhar no meio, o `save-on` é restaurado automaticamente (EXIT trap), mas o arquivo `.tar.zst` do ciclo falho não é publicado como consistente.
- **Permissões**: sempre ajuste `chown` após extrair — o backup preserva permissões mas o `rsync` pode não aplicar corretamente se o usuário mudou.
- **Backup não é imagem completa do host**: o archive cobre mundos + configuração essencial + mods, não o binário do servidor (re-baixável pelo installer) nem unidades systemd.

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação (seção 4: backup)
- [security.md](security.md) — Segurança e operação
