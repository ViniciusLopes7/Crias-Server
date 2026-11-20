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

### 5. Substituir APENAS as entradas presentes no backup (script com guards)

O bloco abaixo é um script completo: descobre o `level-name`, testa cada
entrada com `-d`/`-f` ANTES de restaurar e usa `--delete` apenas onde a
entrada existe no backup (CR-28 — o exemplo antigo restaurava
`world_nether/` incondicionalmente e quebrava em mundos legacy).

```bash
#!/bin/bash
# restore-mc.sh — restaura entradas PRESENTES no backup extraído em $tmpdir.
set -euo pipefail

server=/opt/minecraft-server
tmpdir="${1:?uso: restore-mc.sh <dir-do-backup-extraido>}"

[ -d "$tmpdir" ] || { echo "ERRO: $tmpdir nao existe" >&2; exit 1; }

# Mundo efetivo: level-name do server.properties DO BACKUP (nao do alvo).
level="world"
if [ -f "$tmpdir/server.properties" ]; then
    level="$(awk -F= '$1=="level-name"{v=substr($0,index($0,"=")+1)} END{if(v!="")print v}' "$tmpdir/server.properties")"
    level="${level:-world}"
fi
echo "Mundo efetivo: $level"

# Mundo principal (obrigatório no backup — CR-05 garante).
[ -d "$tmpdir/$level" ] || { echo "ERRO: backup sem o diretorio do mundo ($level)" >&2; exit 1; }
sudo rsync -a --delete "$tmpdir/$level/" "$server/$level/"

# Dimensões separadas: SÓ se existirem no backup.
for dim in "${level}_nether" "${level}_the_end"; do
    if [ -d "$tmpdir/$dim" ]; then
        sudo rsync -a --delete "$tmpdir/$dim/" "$server/$dim/"
    else
        echo "skip: $dim ausente no backup (normal em mundos vanilla)"
    fi
done

# Configuração e properties: SÓ se presentes.
[ -d "$tmpdir/config" ] && sudo rsync -a --delete "$tmpdir/config/" "$server/config/"
[ -f "$tmpdir/server.properties" ] && sudo cp -a "$tmpdir/server.properties" "$server/server.properties"

# Mods: SÓ se presentes (BACKUP_INCLUDE_MODS=true no momento do backup).
[ -d "$tmpdir/mods" ] && sudo rsync -a --delete "$tmpdir/mods/" "$server/mods/"

echo "Restore concluído. Ajuste permissões (passo 6) e inicie o serviço."
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
- **RCON save-lock**: backups do Minecraft com RCON habilitado são consistentes (sem chunks parcialmente salvos). Sem RCON, o backup falha por padrão; `BACKUP_REQUIRE_CONSISTENT=false` permite explicitamente o modo best-effort, que pode ser inconsistente. Se um backup falhar no meio, o `save-on` é restaurado automaticamente (EXIT trap), mas o arquivo `.tar.zst` do ciclo falho não é publicado como consistente.
- **Permissões**: sempre ajuste `chown` após extrair — o backup preserva permissões mas o `rsync` pode não aplicar corretamente se o usuário mudou.
- **Backup não é imagem completa do host**: o archive cobre mundos + configuração essencial + mods, não o binário do servidor (re-baixável pelo installer) nem unidades systemd.

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação (seção 4: backup)
- [security.md](security.md) — Segurança e operação
