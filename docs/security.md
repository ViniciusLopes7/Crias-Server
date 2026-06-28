# Segurança e Operação

Pontos operacionais que não devem ficar espalhados nos scripts: firewall, logs, health checks, hardening systemd, cleanup do stack oposto.

## Firewall

O projeto **não** abre portas automaticamente. Se o servidor estiver em rede pública, libere apenas o necessário.

- **Minecraft**: porta configurada em `server.properties` (default: `25565`)
- **Terraria**: porta configurada em `config/serverconfig.txt` (default: `7777`)
- **crias-agent**: `127.0.0.1:8473` apenas (não expor direto — usar Tailscale Funnel)

### Exemplo: restringir acesso à interface Tailscale (nftables)

```nft
# /etc/nftables.conf
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback
        iifname "lo" accept

        # Tailscale
        iifname "tailscale0" tcp dport 25565 accept comment "Minecraft"
        iifname "tailscale0" tcp dport 7777 accept comment "Terraria"

        # SSH (ajuste porta se necessário)
        tcp dport 22 accept comment "SSH"
    }
}
```

```bash
sudo systemctl enable --now nftables
```

## Logs e rotação

| Stack | Arquivo de log | Rotação |
|-------|----------------|---------|
| Minecraft | `$MINECRAFT_SERVER_DIR/logs/*.log` | `/etc/logrotate.d/crias-minecraft` (diário, 14 dias, compressão) |
| Terraria | `journalctl -u terraria` (sem arquivo) | Configurar `SystemMaxUse=500M` em `/etc/systemd/journald.conf` |
| crias-agent | `/var/log/crias-agent/` + journalctl | Limitado por `MemoryMax=32M` no systemd |

Se mudar o diretório do servidor, reinstale ou reaplique a configuração para atualizar o caminho do `logrotate`.

## Health checks

```bash
# Minecraft: porta + RCON
sudo /opt/minecraft-server/mc-manager.sh health

# Terraria: apenas porta (sem RCON nativo)
sudo /opt/terraria-server/tt-manager.sh health

# crias-agent: porta + RCON via gRPC GetHealth
# (validado pelo bot Discord automaticamente a cada 5 min)
```

## Hardening systemd

Todos os templates `.service` do projeto aplicam hardening:

```ini
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RemoveIPC=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallArchitectures=native
```

> **Atenção**: `MemoryDenyWriteExecute=yes` **NÃO** é aplicado em `minecraft.service`/`terraria.service` porque JVM/Mono precisam de JIT. É aplicado em `crias-agent.service` (Go é AOT-compiled).

### Editar units (cuidado com `Conflicts=`)

As units de Minecraft e Terraria têm `Conflicts=terraria.service` e `Conflicts=minecraft.service` respectivamente — impede ambos rodarem simultaneamente.

`Conflicts=` **não pode** ser sobrescrito por drop-in (`/etc/systemd/system/servicename.d/*.conf`). Para alterar:

```bash
sudo systemctl edit --full minecraft.service
# editar Conflicts= no editor
sudo systemctl daemon-reload
sudo systemctl restart minecraft
```

Documente qualquer alteração de unit no runbook operacional para evitar conflitos durante updates de pacote via `pacman`.

## MAC (AppArmor / SELinux)

O repositório **não** embarca perfis AppArmor ou SELinux.

- Se você usa AppArmor ou SELinux, trate-os como configuração local do host.
- O instalador não gera nem gerencia políticas MAC automaticamente.

## Rollback em caso de falha

Se a instalação falhar, o rollback é **best-effort**:
- Artefatos gerados (`.service`, logrotate, scripts em `/opt/`) são removidos
- Se o diretório `/opt/<stack>` **não** pré-existia, é removido inteiro
- Se pré-existia, apenas artefatos do installer são removidos (dados do usuário preservados)

O rollback é disparado automaticamente via `trap EXIT` em `run_stack_install`.

---

## Política de cleanup do stack oposto

Quando `CLEANUP_OTHER_STACK=true` (default), o instalador detecta stack oposto e pergunta se deseja desativá-lo.

### O que é desativado (não destrutivo)

- `systemctl stop <stack>` + `systemctl disable <stack>`
- Remoção do autoload de aliases em `/etc/profile.d/crias-server.sh`
- Remoção de entradas de crontab do backup

### O que NÃO é feito

- Dados em `/opt/` são **preservados**
- Usuários do sistema são **preservados**
- Backups existentes são **preservados**

Operações destrutivas adicionais (remoção de `/opt` ou usuário) exigem comando manual opt-in separado.

### Recarregar shell após cleanup

```bash
source /etc/profile.d/crias-server.sh
# ou abra um novo terminal
```

### Recomendação antes de cleanup

1. Faça backup externo dos mundos e arquivos importantes.
2. Revise manualmente o que será desativado.
3. Confirme que o stack selecionado para manter é o correto.

---

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação
- [tailscale.md](tailscale.md) — Conexão via Tailscale
- [../README.md](../README.md) — README principal (hardening do crias-agent)
