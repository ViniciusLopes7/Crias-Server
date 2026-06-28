# Mods do Minecraft — Guias

Os mods abaixo são instalados automaticamente quando `MINECRAFT_INSTALL_QOL_MODS=true` (default) e `MINECRAFT_LOADER=fabric` (ou `quilt`). A lista é configurável via `MINECRAFT_QOL_MODS` em `config.env` (formato CSV `file_name:slug,file_name:slug,...`).

| Mod | Slug Modrinth | Função |
|-----|---------------|--------|
| **Chunky** | `chunky` | Pré-geração de chunks (elimina lag de exploração) |
| **Essential Commands** | `essential-commands` | Comandos de QoL: home, tpa, spawn, rtp, back, nickname |
| **Universal Graves** | `universal-graves` | Tumba que guarda itens ao morrer |
| **TabTPS** | `tabtps` | Mostra TPS/MSPT na tab list |
| **Styled Chat** | `styled-chat` | Customização do chat (placeholder API) |
| **Polymer** | `polymer` | Framework para mods server-side |
| **Placeholder API** | `placeholder-api` | Placeholders para outros mods |

---

## Chunky — Pré-geração de chunks

Gera chunks **antes** dos jogadores chegarem, eliminando o "lag de geração" quando exploram áreas novas. Recomendado rodar antes de abrir o servidor.

### Comandos

Via console (`mcconsole`) ou in-game (se OP):

| Comando | O que faz |
|---------|-----------|
| `chunky center 0 0` | Define centro da geração |
| `chunky radius 2000` | Define raio em blocos |
| `chunky start` | Inicia geração |
| `chunky pause` | Pausa |
| `chunky continue` | Continua |
| `chunky cancel` | Cancela |
| `chunky status` | Ver progresso |
| `chunky world world` | Selecionar mundo |
| `chunky selection square` | Forma quadrada |
| `chunky selection circle` | Forma circular |

### Exemplo de uso

```
chunky radius 2000
chunky center 0 0
chunky start
chunky status
```

### Dicas

- Execute **antes** de abrir para jogadores (consome I/O pesado).
- Pode pausar e continuar depois sem perder progresso.
- Em HDD, faça em horários de pouco uso.
- Raio de 2000 blocos gera ~25 MB de dados em world/ (depende do mundo).

---

## Essential Commands — Comandos de QoL

Adiciona comandos essenciais para gameplay sem grandes complexidades. Configuração padrão aplicada pelo `install.sh` em `/opt/minecraft-server/config/essentialcommands/config.toml`.

### Comandos de jogador

| Comando | O que faz | Exemplo |
|---------|-----------|---------|
| `/home` | Teletransporta para sua home | `/home base` |
| `/sethome` | Define uma home no local atual | `/sethome casa` |
| `/delhome` | Deleta uma home | `/delhome casa` |
| `/spawn` | Retorna para o spawn do mundo | `/spawn` |
| `/tpa` | Envia pedido de teleporte até alguém | `/tpa Marcos` |
| `/tpahere` | Pede para o jogador vir até você | `/tpahere Marcos` |
| `/tpaccept` | Aceita pedido de teleporte recebido | `/tpaccept` |
| `/tpadeny` | Recusa pedido de teleporte | `/tpadeny` |
| `/back` | Retorna ao local prévio (ex: pós-morte) | `/back` |
| `/rtp` | Teletransporte aleatório pelo mapa | `/rtp` |

### Comandos administrativos (OP)

| Comando | O que faz | Exemplo |
|---------|-----------|---------|
| `/nickname set <player> <título>` | Define apelido | `/nickname set Vinicius O_Lenda` |
| `/nickname clear <player>` | Remove apelido | `/nickname clear Vinicius` |

### Configuração padrão

Aplicada pelo `install.sh`:

- Máximo de **3 homes** por jogador.
- Teleporte **gratuito** (custo de XP removido em `config.toml`).
- Teleporte e spawn respeitam dimensões (pode dar `/home` para o Nether).
- RTP com raio de 10000 blocos, mínimo 1000.

---

## Universal Graves — Tumba ao morrer

Cria uma tumba no local da morte que guarda os itens do jogador. Configuração padrão em `/opt/minecraft-server/config/universal_graves/config.json`:

- **Proteção**: 300 segundos (5 min) — só o dono pode pegar itens.
- **Quebra**: 1800 segundos (30 min) — depois qualquer um pode quebrar.
- Itens são dropados se a tumba expirar sem ser coletada.
- Holograma + título + GUI para visualização.

Sem comandos de jogador — funcionamento automático.

---

## TabTPS — Monitor de TPS/MSPT

Mostra TPS (ticks per second) e MSPT (milliseconds per tick) na tab list. Ajuda a diagnosticar lag.

- TPS ideal: **20.0** (limite do Minecraft).
- MSPT ideal: **< 50ms** (para manter 20 TPS).

Sem comandos — funcionalidade automática após instalação.

---

## Styled Chat + Placeholder API — Customização de chat

Permite customizar o formato do chat com placeholders. Integra com **Essential Commands** para mostrar título/nickname no chat.

### Exemplo: aplicar título a um jogador

O "Rei do servidor" pode batizar novos membros com "vulgos" (títulos). Use `/nickname set` do Essential Commands — o StyledChat mostra o título no chat automaticamente.

**Lista de títulos sugeridos** (sorteie um para cada amigo):

1. 👑 O Lenda do Reino
2. 🏰 O Visionário das Obras
3. ⚔️ O General da Treta
4. 🌲 O Explorador Nato
5. 🧪 O Mestre da Poção
6. 💎 O Rico do Vale
7. ⛏️ O Mestre do Garimpo
8. 🛡️ O Guardião da Sede

### Como aplicar

**Opção A — Via console SSH:**
```bash
mcconsole
# dentro do console:
nickname set <NomeDoAmigo> "O Lenda do Reino"
# Ctrl+A, D para sair
```

**Opção B — In-game (se OP):**
```
/nickname set <NomeDoAmigo> "O Lenda do Reino"
```

### Dicas

- Títulos com espaços: use aspas (`"O Lenda do Reino"`) ou underlines (`O_Lenda_do_Reino`).
- Para limpar: `/nickname clear <NomeDoAmigo>`.
- O título aparece no chat via integração StyledChat + PlaceholderAPI.

---

## Adicionar mods extras (não padrão)

Os mods QoL são instalados em `/opt/minecraft-server/mods/`. Para adicionar mods extras:

```bash
# 1. Baixar o .jar do Modrinth ou CurseForge
# 2. Copiar para o diretório de mods
sudo cp meu-mod.jar /opt/minecraft-server/mods/

# 3. Ajustar permissão
sudo chown minecraft:minecraft /opt/minecraft-server/mods/meu-mod.jar

# 4. Reiniciar servidor
sudo systemctl restart minecraft
```

> **Atenção:** o installer pula a instalação de QoL mods se `/opt/minecraft-server/mods/` já contiver `.jar`s. Isso previne conflitos. Se quiser reinstalar QoL, limpe o diretório primeiro.

### Verificar SHA256 de mods extras (recomendado)

```bash
# Defina o SHA256 do mod em config.env:
echo 'MOD_MEU_MOD_SHA256="abc123..."' >> config.env

# Ou exporte antes de rodar o installer:
export MOD_MEU_MOD_SHA256="abc123..."
```

O `download_and_verify` valida o checksum antes de aceitar o download.
