# Estudo de Viabilidade de GUI (F6)

> **Fase**: F6 (estudo — sem código). Documenta opções de interface gráfica para
> o Crias-Server, alinhado à visão de longo prazo: **TUI como hub central
> headless → eventualmente GUI web estilo CasaOS** (dashboard com ícones por
> categoria). Recomendação gateada por hardware tier.

## 1. Contexto e visão

O Crias-Server hoje é 100% console: TUI com `gum` no `install.sh`, CLI managers
(`mc-manager.sh` / `tt-manager.sh`), e controle remoto via Discord bot. Não há
GUI — a ISO não inclui X11/Wayland/nenhum web server.

A visão de longo prazo (registrada em F5) é evoluir para:
- **Headless (atual)**: TUI `gum` + managers + `crias-agent` gRPC + Discord bot.
  Já funciona. Ideal para VPS/containers/servidores sem monitor.
- **GUI web (futuro)**: um dashboard no browser estilo CasaOS — cartões/ícones
  por categoria (servidor, players, backups, mods, monitoramento, sistema), com
  ações rápidas (start/stop/backup) e status visual. Acessível via Tailscale
  Funnel (HTTPS) sem VPN no client.

Este estudo avalia as opções para chegar nesse GUI web, com recomendação
**gateada por tier** (LOW não recomenda, MID/HIGH sim) — coerente com o
princípio de que hosts limitados não devem competir RAM com um web server.

## 2. Opções avaliadas

| Opção | Tipo | Footprint (approx) | Licença | Fit Crias | Esforço |
|---|---|---|---|---|---|
| **Cockpit** | Web UI genérica (systemd/storage/network) | ~50-80MB installed, ~30-50MB RSS | LGPL-2.1+ | Médio | Baixo (pacman + enable) |
| **ttyd** | Web terminal (shell no browser) | ~5MB binary, ~5-10MB RSS | MIT | Baixo | Baixíssimo |
| **wetty** | Web terminal (Node.js) | ~30MB (Node runtime) | MIT | Baixo | Baixo |
| **CasaOS** (fork/inspiração) | Web UI home-server (Docker-centric) | ~50MB + Docker (~100MB) | Apache-2.0 | Baixo (Docker-centric) | Alto (refatorar pra systemd) |
| **sway + foot** (local Wayland) | GUI local (não web) | ~22MB | MIT | Nenhum (headless) | N/A |
| **Custom Go webapp** (recomendado) | Web UI tailor-made, reusa crias-agent gRPC | ~10-15MB binary, ~20-30MB RSS | MIT | Alto | Médio |

### 2.1 Cockpit

- **O que é**: project oficial, web UI em Go/C+JS na porta 9090 (HTTPS). Gerencia
  systemd, storage, network, users, updates via "bridge" plugins. PAM auth
  (system users), suporta 2FA via plugins.
- **Pró**: maduro, mantido pela Red Hat, já gerencia systemd (start/stop
  minecraft.service direto), storage (LVM/btrfs), logs (journalctl web),
  updates. Extensível via apps/plugins — dá pra escrever um "cockpit-crias"
  que mostra status do jogo/players/backups.
- **Contra**: genérico (não tem noção de "game server", "players online",
  "RCON"). A customização exigiria um plugin em JS. PAM auth = expõe system
  users (risco se brute-force). Footprint ~50MB RSS compete com heap do jogo
  em LOW tier. Pacote Arch `cockpit` em `extra` (não precisa de AUR).
- **Veredicto**: boa opção "pronta" se o usuário quer admin geral do host
  (não só do jogo). Para o dashboard CasaOS-style específico, é pesada demais.

### 2.2 ttyd

- **O que é**: web server minimalista que expõe um shell no browser via
  websocket. Binário C único ~5MB.
- **Pró**: minúsculo, instantâneo, dá shell remoto sem SSH client. Útil pra
  debug rápido via browser.
- **Contra**: **não é dashboard** — é só um terminal. Você ainda digita
  comandos. Não atende a visão CasaOS (ícones/cartões/status visual).
- **Veredicto**: complemento útil (debug remoto), mas não é a GUI principal.

### 2.3 wetty

- **O que é**: equivalente Node.js ao ttyd.
- **Pró**: ecossistema Node (fácil hackear).
- **Contra**: runtime Node (~30MB) é mais pesado que ttyd pra mesma função.
  Mesmo contra (não é dashboard).
- **Veredicto**: ttyd é melhor no mesmo nicho.

### 2.4 CasaOS (fork/inspiração de UI)

- **O que é**: Go+Vue, web UI home-server na 80/443. App store, file manager,
  gerenciamento de **containers Docker**. Apache-2.0.
- **Pró**: UI bonita (cartões/ícones por app) — exatamente a estética que o
  usuário quer. Open source, forkable.
- **Contra**: **Docker-centric** — gerencia containers, não systemd services.
  Crias-Server usa systemd (minecraft.service, terraria.service), não Docker.
  Forkar CasaOS pra falar systemd exigiria reescrever a camada de "apps"
  (currently → Docker API; target → systemctl). Footprint: ~50MB + Docker
  (~100MB) = ~150MB. Não cabe em LOW tier.
- **Veredicto**: **inspiração de design**, não base. A UI (cartões, ícones,
  layout) é referência; a arquitetura (Docker) não serve.

### 2.5 sway + foot (local Wayland)

- **O que é**: compositor Wayland (sway ~20MB) + terminal foot (~2MB).
- **Pró**: GUI local leve se o host tem monitor.
- **Contra**: game servers são **headless** (sem monitor). Wayland local não
  ajuda admin remota. Não atende visão CasaOS (que é web).
- **Veredicto**: fora de escopo. Game server = acesso remato via web.

### 2.6 Custom Go webapp (recomendado)

- **O que é**: um novo binário Go (`crias-web` ou similar) que serve uma SPA
  (HTML/JS embedded via `embed.FS`) numa porta custom (ex.: 8474). Backend
  chama o `crias-agent` gRPC existente (localhost:8473) para todas as ações
  (start/stop/status/players/say/console/health). Auth reusa o token do agent.
  Expõe via Tailscale Funnel (igual ao agent).
- **Pró**:
  - **Reusa infra existente**: crias-agent já tem gRPC RPCs + auth token +
    Tailscale Funnel. O webapp é só um thin layer HTTP→gRPC + UI estática.
  - **Tailor-made**: dashboard mostra exatamente o que importa (status do
    jogo, players online, RAM/tier, backups, mods, health). Cartões/ícones
    por categoria — visão CasaOS-style.
  - **Leve**: Go static binary ~10-15MB, RSS ~20-30MB. Cabe em MID/HIGH.
  - **Seguro**: mesmo modelo do agent (token auth, localhost bind, Tailscale
    Funnel pra HTTPS público sem expor portas).
  - **Consistente**: mesmo toolchain (Go 1.27, já bumped em F3), mesma licença
    MIT, mesma estrutura de repo (novo subdir `web-ui/` ou `crias-web/`).
- **Contra**:
  - **Esforço médio**: precisa construir a UI (HTML/JS/CSS). Pode usar
    framework leve (htmx + Alpine.js, ou vanilla JS) pra evitar bundle pesado.
  - **Não trivial**: auth, sessões, WebSocket pro console stream (reusa
    `StreamConsole` do agent). Mas o backend já existe.
- **Veredicto**: **melhor fit**. Atende a visão CasaOS sem herdar a
  dependência Docker. Reusa o ecossistema Crias-Server.

## 3. Arquitetura proposta (custom Go webapp)

```
┌──────────────────────────────────────────┐
│  Browser (qualquer dispositivo)          │
│  https://<host>.<tailnet>.ts.net:8474    │
└──────────┬───────────────────────────────┘
           │ HTTPS (Tailscale Funnel)
           ▼
┌──────────────────────────────────────────┐
│  crias-web (Go) — :8474                  │
│  - serve SPA (embed.FS, sem node)        │
│  - auth: token (mesmo do agent) ou       │
│    Tailscale Whois (identifica usuário)  │
│  - proxy HTTP→gRPC p/ crias-agent        │
└──────────┬───────────────────────────────┘
           │ gRPC localhost:8473
           ▼
┌──────────────────────────────────────────┐
│  crias-agent (Go) — :8473 (já existe)    │
│  - ServerControl RPCs (start/stop/...)   │
│  - StreamConsole (WebSocket no webapp)   │
│  - eventos (player join/leave, health)   │
└──────────┬───────────────────────────────┘
           │ subprocess/sudo
           ▼
   systemctl / mc-manager.sh / gorcon
```

### Estrutura de repo proposta
```
crias-web/                 (novo subdir, espelha discord-agent/)
├── cmd/crias-web/main.go  (entry point)
├── internal/
│   ├── server/            (HTTP handlers + auth + gRPC client)
│   ├── ui/                (embed.FS com index.html + assets)
│   └── config/            (carrega /etc/crias/web.yaml)
├── proto/                 (reusa discord-agent/proto/crias.proto)
├── Dockerfile
├── Makefile
└── README.md
```

### UI (visão CasaOS-style)
- **Dashboard**: cards por categoria com ícones (SVG inline, sem deps externas):
  - 🎮 Servidor (status, tier, porta, players count)
  - 👥 Players (lista online, com avatar Mojang se online-mode)
  - 💾 Backup (último backup, retenção, espaço usado)
  - 📦 Mods (lista instalada, QoL + modpack)
  - 📊 Monitoramento (link pro subcomando `monitor` — btop embedado? ou iframe)
  - ⚙️ Sistema (RAM/CPU/disco, tier detectado, Tailscale status)
- **Ações rápidas**: Start / Stop / Restart / Backup agora (botões)
- **Console**: WebSocket stream do `journalctl -u minecraft -f` (reusa
  `StreamConsole` RPC do agent)
- **Settings**: editar config.env (com validação), reconfigure-hardware

### Auth
- **Opção A (simples)**: token estático em `/etc/crias/web.yaml` (igual agent).
  Browser envia no header `Authorization: Bearer <token>`.
- **Opção B (Tailscale Whois)**: se acessado via Tailscale, usa
  `tailscale whois <client-ip>` pra identificar o usuário Tailnet (sem senha).
  Mais ergonômico (sem token pra digitar), mas exige Tailscale no client.
- **Recomendação**: Opção B como default (se Tailscale ativo), Opção A fallback.

## 4. Recomendação gateada por tier

| Tier | RAM total | Recomendação | Razão |
|---|---|---|---|
| LOW (≤3GB) | apertado | **NÃO instalar GUI** | Heap do jogo (LOW ≈ 1GB) + OS + crias-agent (128MB) já consome ~1.6GB. Adicionar webapp (20-30MB RSS) compete com o jogo. TUI + Discord bot já cobrem controle remoto. |
| MID (≤12GB) | folgado | **Opcional** (custom webapp) | Heap MID ≈ 4-6GB + OS + agent ≈ 5-7GB. Sobram 5+GB. Webapp 30MB RSS é desprezível. Recomendado se o usuário quer dashboard visual. |
| HIGH (>12GB) | abundante | **Recomendado** (custom webapp) | Heap HIGH ≈ 8-10GB + resto ≈ 11GB. Sobram 1+GB fácil. Webapp é bônus sem custo. |

### Detecção automática
O `install.sh` já detecta o tier (`shared/lib/hardware-profile.sh`). A
pergunta de instalar a GUI seria:
```
if [ "$HW_TIER" = "LOW" ]; then
    print_warning "GUI web não recomendada em tier LOW (≤3GB RAM)."
    print_step "TUI + Discord bot já cobrem controle remoto."
    INSTALL_WEB_UI=false
else
    tui_confirm "Instalar GUI web (crias-web)?" "N"  # default N mesmo em HIGH
fi
```

## 5. Considerações de segurança

- **Bind**: `127.0.0.1:8474` apenas (igual agent). Nunca `0.0.0.0`.
- **Exposição pública**: via Tailscale Funnel (HTTPS, mesmo modelo do agent).
  `sudo tailscale funnel 8474` além do `8473`.
- **Auth**: token (Opção A) ou Tailscale Whois (Opção B). Nunca sem auth.
- **TLS**: Tailscale Funnel fornece HTTPS nativo. Se Tailscale desativado,
  o webapp pode gerar cert self-signed OU redirecionar pro agent (que tem o
  mesmo problema — Tailscale é a solução).
- **CSRF/XSS**: SPA static sem server-side rendering reduz superfície. Token
  no header (não cookie) evita CSRF. CSP header `default-src 'self'`.
- **Rate limiting**: o agent já tem rate limit implícito (gRPC sobre Tailscale).
  O webapp herda.

## 6. Roadmap proposto (pós-F8)

Se o usuário decidir seguir com o custom webapp:

1. **Fase G1** (esqueleto): `crias-web/` com entry point Go, HTTP server em
   `:8474`, serve `index.html` estático (placeholder), auth por token (lê
   `/etc/crias/agent.yaml`). CI job `build-web` no `ci.yml`. Sem UI real ainda.
2. **Fase G2** (gRPC client): conectar no `crias-agent:8473`, expor
   `GET /api/status` → `GetStatus` RPC. Dashboard mostra status do servidor.
3. **Fase G3** (ações): `POST /api/start|stop|restart|backup` → RPCs. Botões
   funcionais.
4. **Fase G4** (console stream): WebSocket `/api/console` → `StreamConsole` RPC.
   Console do jogo ao vivo no browser.
5. **Fase G5** (UI CasaOS-style): redesign com cartões/ícones SVG por categoria.
   ht.m + Alpine.js (ou vanilla) pra evitar bundle. Responsivo mobile.
6. **Fase G6** (Tailscale Whois auth): Opção B, sem senha.
7. **Fase G7** (embed btop?): explorar iframe de `btop` em modo web (btop tem
   `--utf-force` mas não web nativo; alternativa: `ttyd` rodando `btop`
   embutido). Ou só link pro subcomando `monitor`.

Cada fase é um zip entregável (igual às fases F1-F8).

## 7. Veredicto e próximos passos

**Recomendação**: seguir o caminho do **custom Go webapp** (seção 2.6), em
fases pós-F8. Razões:
1. Reusa o ecossistema Crias-Server (crias-agent gRPC + Tailscale Funnel +
   mesmo toolchain Go + mesma licença).
2. Atende a visão CasaOS-style (cartões/ícones) sem herdar a dependência
   Docker do CasaOS real.
3. Gateada por tier (LOW não, MID opcional, HIGH sim) — coerente com o
   princípio de não competir RAM em hosts limitados.
4. Esforço médio mas incremental (7 fases G1-G7, cada uma entregável).

**Não recomendado**: Cockpit (genérico, pesado pra LOW), CasaOS fork (Docker
mismatch), ttyd/wetty (não são dashboard), sway (headless não usa).

**Próxima fase do plano atual (F7)**: melhorar superfície de testes + QEMU
(validar o autologin do F1 end-to-end, cobrir install_ssh_if_enabled,
deep-smoke com banner). A GUI fica como estudo documentado — implementação
só se o usuário decidir seguir (pós-F8).

## 8. Veja também

- [../README.md](../README.md) — visão geral (controle remoto Discord)
- [../discord-agent/README.md](../discord-agent/README.md) — agente Go (gRPC
  RPCs que o webapp reusaria)
- [security.md](security.md) — firewall, SSH, hardening (modelo de auth)
- [tui.md](tui.md) — TUI atual (hub central headless)
- [hardware-tuning.md](hardware-tuning.md) — tiers LOW/MID/HIGH (base do gating)
