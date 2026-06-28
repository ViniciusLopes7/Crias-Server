# Conexão via Tailscale

Guia de conexão ao servidor via Tailscale (VPN mesh) e Tailscale Funnel (HTTPS público para o `crias-agent`).

## Por que Tailscale?

- ✅ Não precisa abrir portas no roteador
- ✅ Conexão criptografada WireGuard
- ✅ IP fixo (100.x.x.x) — não muda
- ✅ Funciona de qualquer lugar (NAT traversal)
- ✅ Fácil de compartilhar com amigos

## 1. Configurar Tailscale no servidor

O instalador oferece instalar Tailscale automaticamente (`INSTALL_TAILSCALE=true`, default). Se pulou:

```bash
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
# → abre link no navegador, faça login (Google/Microsoft/GitHub)
# → autorize o dispositivo

# Verificar IP do Tailscale (anote — é o endereço do servidor)
sudo tailscale ip -4
# Exemplo: 100.64.123.45
```

## 2. Conectar jogadores ao servidor

Cada jogador precisa instalar Tailscale no PC e entrar na **mesma rede Tailscale** (mesma conta ou conta convidada).

### Linux

```bash
# Arch
sudo pacman -S tailscale
# Ubuntu/Debian
curl -fsSL https://tailscale.com/install.sh | sh
# Fedora
sudo dnf install tailscale

# Ativar
sudo systemctl enable --now tailscaled
sudo tailscale up
```

### Windows / macOS

Baixe em <https://tailscale.com/download> e faça login com a mesma conta.

### Conectar ao Minecraft

No launcher do Minecraft, adicione servidor com o IP do Tailscale:

```
100.64.123.45
```

(ou `100.64.123.45:25565` se precisar especificar porta)

### Conectar ao Terraria

No Terraria, digite o IP do Tailscale na tela de multiplayer.

## 3. Compartilhar acesso com amigos

Para convidar amigos que não estão na sua conta Tailscale:

```bash
# Opção A: convidar via Tailscale admin console
# → acesse https://login.tailscale.com/admin/machines
# → clique em "Share" no dispositivo servidor
# → digite o email do amigo

# Opção B: usar Tailscale Funnel (público — veja abaixo)
```

## 4. Tailscale Funnel (para o `crias-agent`)

Se você instalou o `crias-agent` (`INSTALL_AGENT=true`), precisa expô-lo publicamente para o bot Discord (no Railway) conseguir conectar. O **Tailscale Funnel** faz proxy HTTPS sem precisar de VPN no bot.

```bash
# Ativar Funnel na porta do agente (8473)
sudo tailscale funnel 8473
```

Isso expõe `https://<seu-host>.<seu-tailnet>.ts.net` publicamente. O bot Discord conecta neste endpoint HTTPS.

> **Atenção:** o Funnel é público. Qualquer pessoa com a URL pode tentar conectar — mas o agente exige token de autenticação (`x-api-token`) em cada RPC. Sem o token, requisições são rejeitadas com `codes.Unauthenticated`.

### Configurar no Railway

No painel do Railway, defina:
- `CRIAS_AGENT_HOST=https://<seu-host>.<seu-tailnet>.ts.net`
- `CRIAS_AGENT_TOKEN=<copie de /etc/crias/agent.yaml>`

Para ver o token (após `install.sh`):
```bash
sudo grep auth_token /etc/crias/agent.yaml
```

## 5. Verificar status

```bash
# Status geral
sudo tailscale status

# IP do servidor
sudo tailscale ip -4

# Listar dispositivos na rede
sudo tailscale status | grep -v "^#"

# Logs do daemon
sudo journalctl -u tailscaled -f
```

## 6. Troubleshooting

### "Can't connect to server"

```bash
# 1. Servidor está rodando?
sudo systemctl status minecraft

# 2. Tailscale conectado dos dois lados?
sudo tailscale status

# 3. IP correto no launcher?
sudo tailscale ip -4

# 4. Porta liberada?
sudo ss -tlnp | grep 25565
```

### Tailscale não conecta

```bash
sudo systemctl status tailscaled
sudo systemctl restart tailscaled
sudo tailscale up --force-reauth
```

### Funnel não funciona

```bash
# Verificar status do Funnel
sudo tailscale funnel status

# Funnel requer conta Tailscale ativa e node aprovado no admin console
# Veja: https://login.tailscale.com/admin/settings/features
```

## 7. Alternativas ao Tailscale

Se não quiser usar Tailscale:

- **IP local**: só funciona na mesma rede (LAN). Simples mas limitado.
- **IP público + port forwarding**: abre porta no roteador. Funciona mas é menos seguro.
- **Cloudflare Tunnel**: alternativa ao Tailscale Funnel para expor o `crias-agent`. Requer config adicional.

| Método | Quando usar | Segurança | Dificuldade |
|--------|-------------|-----------|-------------|
| **Tailscale** | Sempre que possível | ⭐⭐⭐⭐⭐ | Fácil |
| IP local | Mesma rede apenas | ⭐⭐⭐ | Muito fácil |
| IP público | Último recurso | ⭐⭐ | Média |
| Cloudflare Tunnel | Alternativa ao Funnel | ⭐⭐⭐⭐ | Média |

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação
- [../README.md](../README.md) — README principal (controle remoto via Discord)
- [../discord-agent/README.md](../discord-agent/README.md) — Agente Go (gRPC)
- [../discord-bot/README.md](../discord-bot/README.md) — Bot Discord
