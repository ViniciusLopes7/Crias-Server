# Seletor de Modpacks (Minecraft)

Desde a v1.2.0, o instalador Crias-Server oferece um **seletor dinâmico de
modpacks** que busca dados em tempo real na [API do Modrinth](https://docs.modrinth.com).
Este documento descreve as 4 fontes disponíveis, a lógica de compatibilidade, e
a sugestão de versão mais próxima.

Para os mods QoL (instalados junto ao modpack), veja [mods.md](mods.md). Para
o TUI em geral, veja [../tui.md](../tui.md).

## Fontes de modpack

Ao instalar Minecraft, o instalador pergunta (via TUI) qual fonte de modpack
você quer:

| Opção | Descrição | Precisa de internet? |
|-------|-----------|----------------------|
| **Top 10 modpacks (Modrinth)** | Os 10 modpacks mais baixados no Modrinth (ordenado por `downloads`). Seleção via busca fuzzy. | Sim |
| **Buscar modpack por nome** | Busca livre por nome (ex.: "Fabulously Optimized"). Retorna até 10 resultados. | Sim |
| **Vanilla (só loader, sem modpack)** | Instala apenas o servidor vanilla com o loader selecionado (fabric/quilt/vanilla/forge/neoforge). Sem mods. | Sim (para o server.jar) |
| **Slug Modrinth manual** | Você digita o slug do modpack no Modrinth (ex.: `adrenaline`, `fabulously-optimized`). Útil para modpacks específicos. | Sim |

> **Sem internet**: a seleção dinâmica e o download do server.jar/modpack
> exigem internet. O instalador aborta com mensagem clara se não houver
> conectividade (não há fallback offline — o servidor precisa ser baixado de
> qualquer forma).

## Fluxo de seleção

```
1. Escolha a fonte (menu TUI)
       │
       ├─ Top 10 / Busca ──► 2. Lista de modpacks (gum filter, busca fuzzy)
       │                       mostra: "slug | title | ↓downloads"
       │                       │
       │                       └─► 3. Seleciona um modpack
       │                              │
       └─ Slug manual ────────────────┤
                                      ▼
                       4. Busca versões compatíveis com o loader+MC
                          (filtro server-side na API Modrinth)
                              │
                              ├─ há versões compatíveis ──► 5a. Seleciona versão (gum filter)
                              │                              mostra: "version | game_versions | type"
                              │
                              └─ nenhuma compatível ──────► 5b. Sugere MC mais próxima
                                                             pergunta: trocar MC?
                                                             ├─ sim ──► re-busca versões (5a)
                                                             └─ não ──► continua (modpack pode falhar)
```

## Compatibilidade (loader + versão MC)

O Modrinth valida compatibilidade **server-side**: ao pedir as versões de um
modpack, passamos `loaders` e `game_versions` como query params, e a API
retorna apenas as versões compatíveis.

Endpoint usado:

```
GET https://api.modrinth.com/v2/project/{slug}/version?loaders=["fabric"]&game_versions=["1.21.4"]
```

> **Importante**: o endpoint de game versions do Modrinth é
> `https://api.modrinth.com/v2/tag/game_version` (underscore), **não**
> `/tag/game-version` (hífen) — este último retorna 404.

Todas as chamadas incluem o header `User-Agent` identificado
(`crias-server-installer/1.2.0`), conforme exigido pela documentação oficial
(UA genérico como `curl/8.x` é bloqueado).

## Sugestão de versão MC mais próxima

Se o modpack selecionado **não tem nenhuma versão compatível** com a versão de
Minecraft escolhida, o instalador busca todas as versões do modpack e extrai
as game_versions suportadas, então sugere a **versão mais próxima** usando
heurística semântica:

1. **Match exato** — se a versão desejada está na lista, usa ela.
2. **Mesma minor** (ex.: `1.21.5` → `1.21.4`) — a mais recente da mesma
   `major.minor`.
3. **Mesma major** (ex.: `1.21.x` → `1.21.4`) — a mais recente da mesma major.
4. **Fallback** — a versão mais recente da lista.

Exemplo: se você selecionou o modpack X e a versão MC `1.21.5`, mas o modpack
só tem versões para `1.21.4` e `1.20.6`, o instalador sugere `1.21.4` (mesma
minor) e pergunta se deseja trocar a versão do MC.

## Instalação do modpack

A instalação é feita pelo [`mrpack-install`](https://github.com/nothub/mrpack-install)
(versão pinada em `MRPACK_INSTALL_VERSION` no `config.env`). O fluxo:

| Fonte | Comando |
|-------|---------|
| `adrenaline` (default) | `mrpack-install adrenaline [version] --server-dir ... --server-file server.jar` |
| `modrinth` (top-10/busca/slug) | `mrpack-install <slug> [version] --server-dir ... --server-file server.jar` |
| `vanilla` | `mrpack-install <loader> <mc_version> --server-dir ... --server-file server.jar` |

A versão do modpack (selecionada no passo 5a) é passada como argumento
posicional. Se vazia, `mrpack-install` usa a mais recente.

## Configuração não-interativa

Em `NON_INTERACTIVE=true` (CI/automação), o seletor TUI **não é usado**. Use
as variáveis em `config.env`:

```bash
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
ACCEPT_EULA="true"
MINECRAFT_LOADER="fabric"          # fabric|quilt|vanilla|forge|neoforge
MINECRAFT_VERSION="1.21.4"        # versão específica
MINECRAFT_MODPACK_SOURCE="modrinth"  # adrenaline|modrinth|vanilla
MINECRAFT_MODPACK_SLUG="adrenaline"
MINECRAFT_ADRENALINE_VERSION=""    # vazio = mais recente
```

## Mods QoL

Independentemente do modpack, se `MINECRAFT_INSTALL_QOL_MODS=true` (default) e
o loader for `fabric`/`quilt`, o instalador baixa os mods QoL listados em
`MINECRAFT_QOL_MODS` (CSV `file_name:slug`). Veja [mods.md](mods.md) para a
lista e guias.

> **Atenção**: se o diretório `mods/` já contiver `.jar`s, a instalação de QoL
> é pulada para evitar conflitos. Limpe `mods/` antes de reinstalar.

## Troubleshooting

### "Nenhum modpack encontrado na busca do Modrinth"

- Verifique conexão com internet: `curl -fsSL https://api.modrinth.com/v2/tag/loader`
- Se a API estiver fora do ar, use a opção "Slug Modrinth manual" com `adrenaline`
  (default) ou `vanilla`.

### "Nenhuma versão de X compatível com MC Y"

- O modpack não suporta essa combinação loader+MC. Aceite a sugestão de versão
  mais próxima, ou escolha outro modpack.
- Verifique a página do modpack em `https://modrinth.com/modpack/<slug>` para
  ver as versões suportadas.

### `mrpack-install` falha ao instalar

- Verifique a versão do `mrpack-install` (`MRPACK_INSTALL_VERSION` no
  `config.env`). Versões antigas podem não suportar loaders novos.
- Veja os logs: `journalctl -u minecraft` ou rode `mrpack-install` manualmente.

## Veja também

- [README.md](README.md) — stack Minecraft (componentes, comandos).
- [mods.md](mods.md) — guias dos mods QoL.
- [../tui.md](../tui.md) — como o TUI funciona.
- [../tutorial.md](../tutorial.md) — tutorial de instalação passo-a-passo.
