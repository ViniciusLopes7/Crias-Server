# tModLoader (Terraria com mods)

Desde a v1.2.1, o Crias-Server suporta **tModLoader** como substituto do
servidor vanilla do Terraria. O tModLoader é a plataforma oficial de mods do
Terraria (sucessor do tAPI), mantido pela equipe oficial.

> **Status**: Implementado em v1.2.1. Substitui o binário vanilla quando
> `TERRARIA_USE_TMODLOADER=true`. Usa a mesma porta (7777), o mesmo diretório
> (`/opt/terraria-server`), e a mesma service unit systemd (`terraria.service`).

Para visão geral do stack Terraria, veja [terraria/README.md](terraria/README.md).

## Como funciona

```
┌─────────────────────────────────────────────────────────────┐
│  install.sh (Terraria + tModLoader)                          │
│    1. Pergunta: "Usar tModLoader?" (default N)               │
│       ├─ N → instala vanilla (fluxo atual)                   │
│       └─ Y → segue fluxo tModLoader ↓                        │
│    2. Versão tModLoader (busca fuzzy no GitHub Releases)     │
│    3. Mods:                                                   │
│       ├─ Catálogo curado (Calamity, Thorium, etc.)           │
│       ├─ Sem mods                                             │
│       └─ Workshop IDs manuais (CSV)                          │
│    4. Download tModLoader.zip (GitHub release)               │
│    5. Extrai em /opt/terraria-server/server/                 │
│    6. SteamCMD baixa mods (se selecionados)                   │
│    7. Gera Mods/enabled.json + Mods/install.txt              │
│    8. start-terraria.sh detecta tModLoader e usa ScriptCaller│
└─────────────────────────────────────────────────────────────┘
```

## Requisitos

| Componente | Necessário? | Nota |
|------------|-------------|------|
| `steamcmd` | Para download automático de mods | AUR: `steamcmd`. Sem ele, mods não são baixados (mas enabled.json é gerado para auditoria). |
| `icu`, `krb5`, `zlib` | Sim (.NET 8 runtime) | Instalados automaticamente pelo `install.sh`. |
| `unzip` | Sim | Para extrair `tModLoader.zip`. Já na ISO. |
| Internet | Sim | Download do tModLoader + mods exige conexão. |

> **SteamCMD é 32-bit**: no Arch, precisa de `[multilib]` habilitado em
> `/etc/pacman.conf` + `lib32-glibc`, `lib32-gcc-libs`, etc. O `steamcmd` do
> AUR cuida disso automaticamente.

## Catálogo de mods curado

O Crias-Server inclui um catálogo de mods populares (definido em
`shared/lib/tmodloader.sh::tml_mod_catalog`):

| Mod | Workshop ID | Descrição |
|-----|-------------|-----------|
| **Calamity Mod** | `2824688072` | Conteúdo massivo (bosses, biomas, itens) |
| **Calamity Mod Music** | `2824688266` | Trilha sonora complementar |
| **Thorium Mod** | `2909886416` | Conteúdo equilibrado (bosses, classes) |
| **Magic Storage** | `2563309347` | Sistema de armazenamento mágico |
| **Recipe Browser** | `2619954303` | Navegador de receitas in-game |

Para adicionar mais mods ao catálogo, edite `tml_mod_catalog()` em
`shared/lib/tmodloader.sh` (formato CSV: `workshop_id|internal_name|display_name|desc`).

## Instalação interativa (TUI)

```bash
sudo ./install.sh
# 1. Stack: Terraria
# 2. Opções do Terraria:
#    - Usuário, diretório, porta, MOTD, URL download
# 3. "Usar tModLoader (Terraria com mods)?" → Y
# 4. Versão tModLoader (busca fuzzy no GitHub Releases)
# 5. "Como instalar mods?"
#    ├─ Catálogo curado (checklist multi-seleção)
#    ├─ Sem mods
#    └─ Workshop IDs manuais (CSV)
```

## Instalação não-interativa (CI/automação)

```bash
sudo -E NON_INTERACTIVE=true \
        SERVER_TYPE=terraria \
        TERRARIA_USE_TMODLOADER=true \
        TERRARIA_TMODLOADER_VERSION="v2026.06.3.6" \
        TERRARIA_TMODLOADER_MODS="2824688072,2909886416" \
        ./install.sh
```

Se `TERRARIA_TMODLOADER_VERSION` for vazio, o instalador pega a release estável
mais recente do GitHub automaticamente.

## Estrutura de diretórios (pós-install)

```
/opt/terraria-server/                  # save dir (-tmlsavedirectory)
├── server/                              # tModLoader.zip extraído
│   ├── LaunchUtils/{ScriptCaller.sh, InstallDotNet.sh, ...}
│   ├── tModLoader.dll  + .NET 8 runtime
│   └── start-tModLoaderServer.sh
├── Mods/                                # mods (.tmod + enabled.json)
│   ├── enabled.json                     # ["CalamityMod","ThoriumMod",...]
│   ├── install.txt                      # workshop IDs (auditoria)
│   └── *.tmod                           # baixados pelo SteamCMD
├── Worlds/                              # mundos (*.wld)
├── worlds/                              # worlds do vanilla (legacy)
├── config/                              # serverconfig.txt
├── steamapps/workshop/content/1281930/  # mods baixados pelo SteamCMD
├── start-terraria.sh                    # detecta tModLoader vs vanilla
├── tt-manager.sh                        # CLI de gerenciamento
├── backup-cron.sh                       # inclui Mods/ + Worlds/ quando tml
└── terraria.service                     # mesma unit (gum filter)
```

## Operação

```bash
# Iniciar / parar / reiniciar (mesma commands do vanilla):
sudo systemctl start terraria
sudo systemctl stop terraria
sudo systemctl restart terraria

# Status + hardware:
sudo /opt/terraria-server/tt-manager.sh status

# Backup (inclui Mods/ e Worlds/ automaticamente se tModLoader):
sudo /opt/terraria-server/tt-manager.sh backup

# Logs:
sudo journalctl -u terraria -f
```

## Adicionar mods manualmente (sem SteamCMD)

Se `steamcmd` não está instalado, você pode baixar `.tmod` files manualmente do
[Mod Browser do tModLoader](https://mirror.sgkag.dev/tModLoader/) ou do in-game
browser, e colocá-los em `/opt/terraria-server/Mods/`. Depois edite `enabled.json`:

```bash
sudo nano /opt/terraria-server/Mods/enabled.json
# Adicione o internal_name do mod ao array JSON, ex.:
# ["CalamityMod", "MeuModCustom"]

sudo chown -R terraria:terraria /opt/terraria-server/Mods
sudo systemctl restart terraria
```

## Backup

O backup do Terraria agora inclui **automaticamente** `Mods/` e `Worlds/`
(quando tModLoader está instalado), além de `worlds/` e `config/` do vanilla.
A detecção é automática: se `server/LaunchUtils/ScriptCaller.sh` existe, o
backup inclui os dirs do tModLoader.

## Compatibilidade

- **Terraria 1.4.4.9**: tModLoader atual suporta Terraria 1.4.4.x (mesma versão
  do vanilla server `terraria-server-1456.zip`).
- **Wire-incompatível**: servidores tModLoader só podem jogar com outros clientes
  tModLoader da mesma versão. Clientes vanilla não conseguem conectar.
- **Sem RCON**: tModLoader (como vanilla Terraria) não tem RCON nativo. O
  `crias-agent` (controle Discord) não suporta Terraria por enquanto.

## Gotchas

- **.NET JIT na primeira execução**: o tModLoader compila código na primeira
  execução, causando um pico de CPU de 10-30s. O `terraria.service` tem
  `TimeoutStartSec=120` para acomodar isso.
- **stdin sob systemd**: `tModLoaderServer` lê stdin para comandos de console e
  pode busy-loopar em EOF sem TTY. O `start-terraria.sh` usa `exec` direto;
  se houver problemas, considere wrap em tmux ou `StandardInput=tty`.
- **ARM não suportado**: tModLoader não tem build ARM; x86_64 only.
- **Licenciamento**: tModLoader é MIT (redistribuição OK). **Mods têm licenças
  variadas** (Calamity all-rights-reserved, Thorium custom non-commercial, etc.) —
  o instalador baixa sob demanda via SteamCMD, não redistribui `.tmod` files.

## Veja também

- [terraria/README.md](terraria/README.md) — stack Terraria (vanilla + tModLoader)
- [tutorial.md](tutorial.md) — tutorial de instalação passo-a-passo
- [tui.md](tui.md) — como o TUI (gum) funciona
- [../ROADMAP.md](../ROADMAP.md) — status e próximos passos
