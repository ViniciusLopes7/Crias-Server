# discord-agent — Crias Agent

Go binary que faz ponte entre o servidor de jogo (Minecraft/Terraria) e o
bot Discord. Escuta gRPC em `localhost:8473`, exposto externamente via
**Tailscale Funnel** (HTTPS). Não replica lógica do `mc-manager.sh` —
apenas delega via `sudo systemctl` e `mcrcon`.

## Visão de Alto Nível

```
┌──────────────────────┐
│   Discord (Railway)  │  discord.py + slash commands
│   discord-bot/       │
└──────────┬───────────┘
           │  gRPC over HTTPS
           │  Tailscale Funnel: https://<host>.ts.net
           ▼
┌──────────────────────┐
│  crias-agent (Go)    │  systemd: crias-agent.service
│  localhost:8473      │  MemoryMax=32M, CPUQuota=10%
└──────────┬───────────┘
           │  Delegação (subprocess)
           ▼
   sudo systemctl start/stop/restart minecraft
   sudo -u minecraft mc-manager.sh backup
   mcrcon say/list/save-*
```

## Protocolo gRPC

Definido em [proto/crias.proto](proto/crias.proto). Dois serviços:

### `ServerControl` — comandos unários + stream de console

| RPC | Descrição |
|-----|-----------|
| `StartServer` | `sudo systemctl start <service>` |
| `StopServer` | `sudo systemctl stop <service>` (graceful) |
| `RestartServer` | `sudo systemctl restart <service>` |
| `GetStatus` | systemd active + RCON players + uptime + tier |
| `GetHealth` | porta em escuta + RCON responsivo (passivo) |
| `SendRconCommand` | executa comando whitelistado (`say`, `list`, `tp`, etc.) |
| `StreamConsole` | stream de `journalctl -u <service> -f` |

### `EventBus` — push de eventos

| RPC | Descrição |
|-----|-----------|
| `SubscribeEvents` | stream bidi: cliente recebe `ServerEvent` push |

**Eventos emitidos:**
- `ServerStarted` / `ServerStopped` (após start/stop/restart)
- `PlayerJoined` / `PlayerLeft` (polling RCON a cada 30s)
- `HealthWarning` (serviço inativo ou RCON indisponível)
- `ConsoleOutput` (futuro; stream separado via `StreamConsole`)

## Autenticação

Cada RPC deve incluir metadata gRPC:
```
x-api-token: <64-hex-chars>
```

Token é gerado automaticamente pelo `install.sh` via
`openssl rand -hex 32`. Armazenado em `/etc/crias/agent.yaml` (chmod 0640,
owner `root:crias-agent`).

## Configuração

Arquivo `/etc/crias/agent.yaml`:

```yaml
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "<64-hex>"

server:
  stack: "minecraft"              # ou "terraria"
  service_name: "minecraft"
  manager_script: "/opt/minecraft-server/mc-manager.sh"
  server_dir: "/opt/minecraft-server"
  rcon:
    enabled: true
    host: "127.0.0.1"
    port: 25575
    password: "<from-server.properties>"

features:
  auto_shutdown:
    enabled: false                # default off; bot Discord ativa via /mc autoshutdown
    empty_minutes: 30
  health_check:
    interval_seconds: 300
    passive: true                 # só notifica, não reinicia
```

Veja [agent.example.yaml](agent.example.yaml) para template completo.

## Sudoers

O agente roda como usuário `crias-agent` (sem shell login). Pode executar
apenas comandos whitelistados via sudoers:

```sudoers
# /etc/sudoers.d/crias-agent
crias-agent ALL=(root) NOPASSWD: /usr/bin/systemctl start minecraft, \
                                   /usr/bin/systemctl stop minecraft, \
                                   /usr/bin/systemctl restart minecraft, \
                                   /usr/bin/systemctl status minecraft, \
                                   /usr/bin/systemctl is-active minecraft
crias-agent ALL=(minecraft) NOPASSWD: /opt/minecraft-server/backup-cron.sh, \
                                      /opt/minecraft-server/mc-manager.sh *
```

Gerado automaticamente pelo `install.sh` quando `INSTALL_AGENT=true`.

## systemd Unit

`crias-agent.service` com hardening agressivo (vide `install.sh`):

```ini
[Service]
Type=simple
User=crias-agent
Group=crias-agent
WorkingDirectory=/opt/crias-agent
ExecStart=/opt/crias-agent/crias-agent
Restart=on-failure
RestartSec=5

MemoryMax=32M
CPUQuota=10%
TasksMax=10
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/crias-agent /var/log/crias-agent
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
RemoveIPC=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes   # Go é AOT: seguro aplicar
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallArchitectures=native
UMask=0027
```

## Build

Requer Go 1.22+ e `protoc` (com `protoc-gen-go` + `protoc-gen-go-grpc`).

```bash
cd discord-agent/

# Instalar plugins protoc (uma vez):
make install-deps

# Regenerar código proto:
make proto

# Build linux/amd64:
make build

# Docker (multi-stage, scratch final):
make docker
# ou:
docker build -t crias-agent:latest .
```

> **Nota sobre arquiteturas**: apenas `linux/amd64` é lançado oficialmente (a
> ISO é x86_64). Para cross-compilar para outra arquitetura:
> ```bash
> make build BUILD_OS=linux BUILD_ARCH=arm64  # experimental, sem CI
> ```

## Testes

```bash
make test        # roda go test -race
make lint        # roda go vet
```

Cobertura atual:
- `internal/config/` — Load, defaults, validações
- `internal/rcon/` — parse de resposta "list", whitelist de comandos
- `internal/events/` — bus pub/sub com filtros, slow subscriber não bloqueia

## Deploy

### Via install.sh (recomendado)

No servidor alvo:
```bash
sudo INSTALL_AGENT=true ./install.sh
```

Ou interativo:
```bash
sudo ./install.sh
# → "Instalar agente de controle remoto (crias-agent)? [y/N]: y"
```

O `install.sh`:
1. Cria usuário `crias-agent`
2. Baixa binário do último release `agent-*` do GitHub
3. Gera token aleatório (32 bytes hex)
4. Lê RCON config de `server.properties`
5. Gera `/etc/crias/agent.yaml`
6. Configura sudoers `/etc/sudoers.d/crias-agent`
7. Instala systemd unit
8. Habilita e inicia `crias-agent.service`
9. Imprime token + instruções para configurar no Railway

### Via release GitHub (manual)

```bash
# Baixar binário da última release agent-*
curl -L https://github.com/ViniciusLopes7/Crias-Server/releases/download/agent-latest/crias-agent-linux-amd64 \
    -o /opt/crias-agent/crias-agent
chmod 755 /opt/crias-agent/crias-agent

# Validar checksum
sha256sum -c crias-agent-linux-amd64.sha256

# Configurar /etc/crias/agent.yaml + sudoers + systemd unit
# (ver install.sh para referência)
```

### Tailscale Funnel

Após instalar Tailscale no host:
```bash
sudo tailscale up
# Ativar Funnel na porta do agente:
sudo tailscale funnel 8473
```

Isso expõe `https://<seu-host>.<seu-tailnet>.ts.net` publicamente.
O bot Discord conecta neste endpoint sem precisar estar na VPN.

## Segurança

| Camada | Implementação |
|--------|---------------|
| Rede | Tailscale Funnel (HTTPS público) + agente em 127.0.0.1 |
| Transporte | gRPC sobre HTTP/2; TLS terminado pelo Funnel |
| Authn | Metadata `x-api-token` em cada RPC (validado por interceptor) |
| Authz | Comandos RCON whitelistados; sem shell arbitrário |
| Sudoers | `crias-agent` só pode systemctl start/stop/restart/status e mc-manager.sh |
| systemd | Hardening completo (MemoryMax=32M, CPUQuota=10%, SystemCallFilter, etc.) |
| Logs | Não loga token nem senhas; `ReadWritePaths` restrito |

## Troubleshooting

### Agente não inicia

```bash
sudo systemctl status crias-agent
sudo journalctl -u crias-agent -n 50 --no-pager
```

Erros comuns:
- `auth_token não pode ser vazio` — agent.yaml mal gerado. Reexecute install.sh.
- `conectar rcon: ...` — RCON não configurado no server.properties. Veja `enable-rcon=true` e `rcon.password=...`.

### Token perdido

```bash
sudo grep auth_token /etc/crias/agent.yaml
# OU regerar:
sudo ./install.sh  # detecta instalação existente e reconfigura
```

### Bot Discord não conecta

1. Verifique Tailscale Funnel ativo: `sudo tailscale funnel status`
2. Teste HTTPS do bot: `curl -k https://<host>.ts.net` (deve retornar erro gRPC, não conexão recusada)
3. Verifique token no Railway: `CRIAS_AGENT_TOKEN` deve bater com `/etc/crias/agent.yaml`

### RCON não responde

```bash
# Testar mcrcon manualmente:
sudo -u minecraft MCRCON_PASS=<password> mcrcon -H 127.0.0.1 -P 25575 list
# Verificar server.properties:
grep -E '^(enable-rcon|rcon\.port|rcon\.password)' /opt/minecraft-server/server.properties
```

## Roadmap

- [x] MVP: Start/Stop/Restart/Status + EventBus
- [x] RCON: PlayerList + SendRconCommand whitelisted
- [x] StreamConsole via journalctl -f
- [x] HealthMonitor passivo (eventos HealthWarning)
- [x] PlayerMonitor (eventos PlayerJoined/PlayerLeft)
- [ ] Auto-shutdown: desligar servidor vazio por N minutos
- [ ] Wake-on-LAN endpoint
- [ ] Métricas Prometheus (memory, gRPC latência, eventos emitidos)
- [ ] TLS nativo (sem depender de Tailscale Funnel)
