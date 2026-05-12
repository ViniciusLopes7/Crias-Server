# Seguranca e Operacao

Guia rapido para pontos operacionais que nao devem ficar espalhados nos scripts.

## Firewall

O projeto nao abre portas automaticamente. Se voce usar o servidor em rede publica, libere apenas o necessario.

- Minecraft: porta configurada em `server.properties`.
- Terraria: porta configurada em `config/serverconfig.txt`.
- Se a maquina estiver em Tailscale, prefira restringir o acesso apenas a `tailscale0`.

Exemplo de regra minima em `nftables`:

```nft
add rule inet filter input iifname "tailscale0" tcp dport 25565 accept
add rule inet filter input iifname "tailscale0" tcp dport 7777 accept
```

## Logs e rotacao

- Minecraft escreve logs de arquivo em `$MINECRAFT_SERVER_DIR/logs/*.log` e o instalador gera `/etc/logrotate.d/crias-minecraft`.
- Terraria usa principalmente `journalctl -u terraria` para acompanhamento operacional.

Se voce mudar o diretorio do servidor, reinstale ou reaplique a configuracao para atualizar o caminho do `logrotate`.

## Health checks

- Minecraft: `sudo /opt/minecraft-server/mc-manager.sh health`
- Terraria: `sudo /opt/terraria-server/tt-manager.sh health`

Esses comandos verificam a porta de rede e, no caso do Minecraft, tentam validar RCON quando disponivel.

## MAC

O repositório nao embarca perfis AppArmor ou SELinux.

- Se voce usa AppArmor ou SELinux, trate-os como configuracao local do host.
- Evite assumir que o instalador vai gerenciar politicas MAC automaticamente.

## Rollback

Se a instalacao falhar, o rollback e best-effort: artefatos gerados sao removidos, e instalacoes novas sem diretorio preexistente podem ter o diretorio inteiro descartado.