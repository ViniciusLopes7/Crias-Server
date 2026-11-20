# Seleção e instalação de modpacks Minecraft

O instalador Crias-Server aceita modpacks publicados no Modrinth e arquivos pessoais no formato `.mrpack`. Este guia cobre o uso interativo e automático, os critérios de compatibilidade e os problemas mais comuns.

> **Antes de começar:** a máquina precisa de internet para baixar o loader, o servidor e os arquivos referenciados pelo modpack. Mesmo usando um `.mrpack` de pendrive, a instalação normalmente **não é totalmente offline**.

## Fontes disponíveis

| Opção no instalador | Quando usar | Entrada necessária |
|---|---|---|
| Top 10 Modrinth | Explorar projetos populares | Seleção na lista |
| Buscar modpack por nome | Encontrar um projeto publicado | Termo de pesquisa |
| Slug Modrinth manual | Usar projeto publicado conhecido | Slug do projeto |
| Arquivo `.mrpack` | Importar pacote próprio ou de pendrive | Caminho absoluto acessível no Linux |
| Link HTTPS `.mrpack` | Baixar pacote próprio hospedado | URL direta de download HTTPS |
| Vanilla (apenas loader) | Instalar servidor sem modpack | Loader e versão do jogo |

### Modpack próprio por pendrive ou arquivo local

1. Conecte o pendrive ao servidor e monte a partição, se necessário.
2. Confira o caminho com `lsblk -o NAME,LABEL,FSTYPE,MOUNTPOINTS`.
3. Escolha **Arquivo .mrpack (local ou pendrive montado)** e informe o caminho absoluto, por exemplo `/run/media/usuario/PENDRIVE/MeuPack.mrpack`.
4. Confirme que o arquivo está legível; o instalador valida a estrutura e reconcilia a versão/loader efetivos após importar.

### Modpack próprio por link

Use **Link direto HTTPS de .mrpack** e informe uma URL pública que devolva o arquivo, não uma página de visualização ou login. Links privados ou temporários podem expirar antes do download terminar. O instalador valida o arquivo recebido antes de executar `mrpack-install`.

Evite adicionar mods QoL ou extras ao importar um modpack fechado, salvo quando você verificar a compatibilidade das dependências.

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
GET https://api.modrinth.com/v2/project/{slug}/version?loaders=["fabric"]&game_versions=["26.3"]
```

> **Importante**: o endpoint de game versions do Modrinth é
> `https://api.modrinth.com/v2/tag/game_version` (underscore), **não**
> `/tag/game-version` (hífen) — este último retorna 404.

Todas as chamadas incluem o header `User-Agent` identificado
(`crias-server-installer/1.3.0`), conforme exigido pela documentação oficial
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

## Instalação e configurações não interativas

Os pacotes são instalados com [`mrpack-install`](https://github.com/nothub/mrpack-install), cuja versão é fixada em `MRPACK_INSTALL_VERSION` no `config.env`. No fluxo sem modpack o comando de servidor usa `mrpack-install server <loader> --minecraft-version <versão>`.

Exemplo para um arquivo armazenado no próprio servidor:

```bash
SERVER_TYPE="minecraft"
NON_INTERACTIVE="true"
ACCEPT_EULA="true"
MINECRAFT_INSTALL_MODPACK="true"
MINECRAFT_MODPACK_SOURCE="arquivo"
MINECRAFT_MODPACK_FILE="/home/usuario/modpacks/MeuPack.mrpack"
MINECRAFT_INSTALL_QOL_MODS="false"
MINECRAFT_EXTRA_MODS=""
```

Para baixar o pacote, substitua as duas linhas de fonte/caminho por:

```bash
MINECRAFT_MODPACK_SOURCE="link"
MINECRAFT_MODPACK_URL="https://exemplo.org/MeuPack.mrpack"
```

Para um projeto publicado no Modrinth, use `MINECRAFT_MODPACK_SOURCE=modrinth`, `MINECRAFT_MODPACK_SLUG=slug` e, opcionalmente, `MINECRAFT_ADRENALINE_VERSION=versão` (nome legado que também controla modpacks genéricos).

O instalador examina `packstate.json` depois da instalação e utiliza a versão e o loader efetivos para ajustar o Java e o runtime. Ele não deve supor que a versão previamente escolhida no menu seja a mesma que a do pacote.

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
- Se a API estiver fora do ar, o slug manual depende da mesma API. Você pode selecionar um arquivo `.mrpack` local, lembrando que as dependências do pacote ainda precisam ser baixadas.

### "Nenhuma versão de X compatível com MC Y"

- O modpack não suporta essa combinação loader+MC. Aceite a sugestão de versão
  mais próxima, ou escolha outro modpack.
- Verifique a página do modpack em `https://modrinth.com/modpack/<slug>` para
  ver as versões suportadas.

### O link baixa uma página HTML em vez de um `.mrpack`

Use o URL **direto** de um asset público. Confira se ele continua acessível e não exige cookies ou autenticação.

### `mrpack-install` falha ao instalar

- Verifique a versão do `mrpack-install` (`MRPACK_INSTALL_VERSION` no
  `config.env`). Versões antigas podem não suportar loaders novos.
- Veja os logs: `journalctl -u minecraft` ou rode `mrpack-install` manualmente.

## Veja também

- [README.md](README.md) — stack Minecraft (componentes, comandos).
- [mods.md](mods.md) — guias dos mods QoL.
- [../tui.md](../tui.md) — como o TUI funciona.
- [../tutorial.md](../tutorial.md) — tutorial de instalação passo-a-passo.
