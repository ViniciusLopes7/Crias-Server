# Runbook de Restauração de Mundos e Configuração

Este documento descreve passos mínimos para restaurar um servidor Minecraft ou Terraria a partir de backups gerados por `backup-cron.sh`.

Pré-requisitos:
- Acesso SSH ao host com permissão `sudo`.
- Ter o arquivo de backup desejado disponível em `/opt/<stack>/backups/` ou em armazenamento externo.

Passos rápidos (exemplo Minecraft):

1. Pare o serviço:

```bash
sudo systemctl stop minecraft
```

2. Faça um snapshot do estado atual (por segurança):

```bash
sudo cp -a /opt/minecraft-server /opt/minecraft-server.pre-restore-$(date +%Y%m%d-%H%M%S)
```

3. Extraia o backup desejado para uma pasta temporária e verifique o conteúdo:

```bash
tmpdir=$(mktemp -d)
sudo tar -I "zstd -d" -xf /opt/minecraft-server/backups/minecraft-backup-YYYYMMDD-HHMMSS.tar.zst -C "$tmpdir"
ls -la "$tmpdir"
```

4. Substitua os mundos (ou arquivos necessários) com cuidado:

```bash
sudo rsync -a --delete "$tmpdir/worlds/" /opt/minecraft-server/
```

5. Ajuste permissões:

```bash
sudo chown -R minecraft:minecraft /opt/minecraft-server
```

6. Inicie o serviço e monitore logs:

```bash
sudo systemctl start minecraft
sudo journalctl -u minecraft -f
```

7. Verifique integridade in-game e confirme players podem entrar.

Observações:
- Para backups remotos, primeiro copie o arquivo para o host com `scp` ou `rsync`.
- Se usar `DRY_RUN` no instalador, backups gerados no CI não são válidos para restore em produção.
- Teste de restore deve ser parte do plano de manutenção (periodicidade recomendada: mensal).
