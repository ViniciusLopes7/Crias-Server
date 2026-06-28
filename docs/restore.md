# Restore de Backups

Runbook para restaurar mundos e configuração a partir de backups gerados pelo `backup-cron.sh`.

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

### 4. Extrair backup em diretório temporário

```bash
tmpdir=$(mktemp -d)
sudo tar -I "zstd -d" -xf /opt/minecraft-server/backups/minecraft-backup-YYYYMMDD-HHMMSS.tar.zst -C "$tmpdir"
ls -la "$tmpdir"
# deve mostrar: world/ world_nether/ world_the_end/
```

### 5. Substituir mundos

```bash
# ATENÇÃO: --delete remove arquivos não presentes no backup
sudo rsync -a --delete "$tmpdir/world/" /opt/minecraft-server/world/
sudo rsync -a --delete "$tmpdir/world_nether/" /opt/minecraft-server/world_nether/
sudo rsync -a --delete "$tmpdir/world_the_end/" /opt/minecraft-server/world_the_end/
```

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

# Terraria tem worlds/ e config/
sudo rsync -a --delete "$tmpdir/worlds/" /opt/terraria-server/worlds/
sudo rsync -a --delete "$tmpdir/config/" /opt/terraria-server/config/

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
- **RCON save-lock**: backups do Minecraft com RCON habilitado são consistentes (sem chunks parcialmente salvos). Backups sem RCON são best-effort.
- **Permissões**: sempre ajuste `chown` após extrair — o backup preserva permissões mas o `rsync` pode não aplicar corretamente se o usuário mudou.

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação (seção 4: backup)
- [security.md](security.md) — Segurança e operação
