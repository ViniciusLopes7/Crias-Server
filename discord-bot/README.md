# discord-bot/README.md

Bot Discord em Python (discord.py 2.x) para controle remoto do **Crias-Server**. Conecta ao agente Go via gRPC sobre Tailscale Funnel (HTTPS).

## Como funciona

```
┌──────────────────────┐
│   Usuário no Discord  │
│   /mc start           │
└──────────┬───────────┘
           │ slash command
           ▼
┌──────────────────────┐
│   discord-bot (Py)   │  Railway (Python 3.12, container serverless)
│   discord.py 2.x     │  ~50MB RAM idle
└──────────┬───────────┘
           │ gRPC over HTTPS
           │ (metadata: x-api-token)
           ▼
┌──────────────────────┐
│  Tailscale Funnel    │  HTTPS proxy público
│  https://host.ts.net │  (sem VPN no bot)
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  crias-agent (Go)    │  localhost:8473 no notebook
└──────────────────────┘
```

## Slash Commands

| Comando | Permissão | Descrição |
|---------|-----------|-----------|
| `/mc start` | Admin | Liga o servidor |
| `/mc stop` | Admin | Desliga graceful |
| `/mc restart` | Admin | Reinicia |
| `/mc status` | Todos | Online/offline, players, RAM, tier |
| `/mc players` | Todos | Lista quem está online |
| `/mc say <msg>` | Mod+ | Manda mensagem no chat do jogo via RCON |
| `/mc logs [n]` | Admin | Últimas N linhas do journalctl |
| `/mc console` | Admin | Ativa/desativa stream de console no canal #console |
| `/mc health` | Admin | Health check passivo |

## Canais Discord sugeridos

- `#controle` — notificações automáticas (server start/stop, player join/leave, health warnings)
- `#chat-minecraft` — bridge Discord ↔ Minecraft (via `/mc say` e eventos)
- `#console` — stream de logs (opcional, ativável via `/mc console`)

## Deploy no Railway

### 1. Configurar variáveis de ambiente

No painel do Railway, defina (vide `.env.example`):

```
DISCORD_TOKEN=<bot_token_do_discord_dev_portal>
DISCORD_GUILD_ID=<guild_id_opcional>
DISCORD_ADMIN_ROLE_IDS=<role_id_1>,<role_id_2>
DISCORD_MODERATOR_ROLE_IDS=<role_id_3>
DISCORD_CONTROLE_CHANNEL_ID=<channel_id>
CRIAS_AGENT_HOST=https://<seu-host>.<seu-tailnet>.ts.net
CRIAS_AGENT_TOKEN=<64_hex_chars_gerados_pelo_install_sh>
```

### 2. Deploy

```bash
# Opção A: conectar repo do GitHub no painel do Railway
# Railway detecta railway.json automaticamente.

# Opção B: Railway CLI
npm install -g @railway/cli
railway login
railway link
railway up
```

### 3. Sincronizar slash commands

Na primeira execução, o bot sincroniza slash commands automaticamente:
- Se `DISCORD_GUILD_ID` estiver definido: sync imediato no guild (1-2s).
- Caso contrário: sync global (pode levar até 1h para aparecer no Discord).

## Desenvolvimento local

### Pré-requisitos

- Python 3.11+
- [Poetry](https://python-poetry.org/) (recomendado) OU pip + venv

### Setup

```bash
cd discord-bot/

# Opção A: Poetry (recomendado)
poetry install
poetry shell

# Opção B: pip + venv
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install -e .
```

### Gerar código protobuf

```bash
# Requer grpcio-tools (já instalado via requirements.txt)
mkdir -p src/crias_bot/grpc_gen
python -m grpc_tools.protoc \
    -I ../discord-agent/proto \
    --python_out=src/crias_bot/grpc_gen \
    --grpc_python_out=src/crias_bot/grpc_gen \
    ../discord-agent/proto/crias.proto

# Fix import path (protoc gera import absoluto; precisamos relativo ao pacote).
sed -i 's/^import crias_pb2 as crias__pb2/from crias_bot.grpc_gen import crias_pb2 as crias__pb2/' \
    src/crias_bot/grpc_gen/crias_pb2_grpc.py

# Criar __init__.py
touch src/crias_bot/grpc_gen/__init__.py
```

> **Atenção:** O `sed` acima é necessário porque `protoc` gera `import crias_pb2`
> (absoluto), mas o pacote está dentro de `crias_bot.grpc_gen`. Sem o fix,
> o `from crias_bot.agent_client import AgentClient` falha com
> `ModuleNotFoundError: No module named 'crias_pb2'`.

### Configurar .env

```bash
cp .env.example .env
# Editar .env com seus valores
```

### Rodar

```bash
python -m crias_bot
# ou
poetry run crias-bot
```

### Testes

```bash
pytest -v
```

## Reconexão com backoff exponencial

O `AgentClient` reconecta automaticamente quando o agente fica indisponível:

```python
# Em src/crias_bot/agent_client.py
delay = 1.0
while True:
    try:
        await self._channel.channel_ready()
        return
    except (grpc.RpcError, asyncio.TimeoutError, OSError):
        await asyncio.sleep(min(delay, self.max_reconnect_delay))  # até 60s
        delay *= 2  # 1s → 2s → 4s → 8s → 16s → 32s → 60s
```

Logs esperados durante outage do agente:
```
[WARNING] crias-bot.agent_client: conexão falhou (tentativa 3); tentando novamente em 4s
[INFO] crias-bot.agent_client: conectado ao agente em https://host.ts.net
```

## Cache de status

Para evitar spamar o agente com `GetStatus` a cada `/mc status`, o cliente cacheia a resposta por `STATUS_CACHE_SECONDS` (default 15s). Em guilds ativos com 50+ membros usando `/mc status` simultaneamente, isso reduz a carga no agente em ~95%.

Para desabilitar cache em um comando específico:
```python
status = await agent.get_status(use_cache=False)
```

## Estrutura do projeto

```
discord-bot/
├── pyproject.toml           # Poetry config + deps
├── requirements.txt          # pip fallback
├── Dockerfile                # Railway build
├── railway.json              # Railway config
├── .env.example              # template de env vars
├── src/crias_bot/
│   ├── __init__.py
│   ├── __main__.py           # entry point (python -m crias_bot)
│   ├── config.py             # carrega .env e valida
│   ├── agent_client.py       # cliente gRPC async com cache + reconnect
│   ├── bot.py                # CriasBot (discord.py) + MinecraftCog
│   └── grpc_gen/             # código protobuf gerado (não commitado)
└── tests/
    └── test_config.py        # testes de parsing de config
```

## Roadmap

- [x] MVP: Start/Stop/Restart/Status/Players/Say/Health
- [x] Reconexão com backoff exponencial
- [x] Cache de GetStatus (15s)
- [x] Bridge de eventos (ServerStarted/Stopped, PlayerJoined/Left, HealthWarning)
- [ ] `/mc console` stream no canal #console
- [ ] `/mc logs [n]` via StreamConsole tail
- [ ] `/mc autoshutdown on/off` (ativa feature do agente)
- [ ] Bridge chat Discord ↔ Minecraft (mensagens do Discord aparecem no jogo)
- [ ] Métricas (latência gRPC, cache hit rate)
