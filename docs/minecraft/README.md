# Stack Minecraft

Guia de operação do Minecraft no Crias-Server. Para instalar o sistema desde o início, siga o [tutorial](../tutorial.md); para importar um modpack particular, veja [modpacks](modpacks.md).

## Componentes instalados

| Arquivo | Função |
|---------|--------|
| `/opt/minecraft-server/start-server.sh` | Launcher runtime (valida o Java compatível: 17 p/ 1.20.1, 21 p/ 1.20.5–1.21.x e 25 p/ 26.x) |
| `/usr/local/libexec/crias/mc-manager.sh` | CLI de gerenciamento (start/stop/status/console/backup/health/...) — root:root, fora da árvore gravável pelo jogo (EXP-34) |
| `/opt/minecraft-server/backup-cron.sh` | Backup com RCON save-lock + zstd + flock |
| `/usr/local/libexec/crias/setup-cron.sh` | Configura timer systemd de backup (script administrativo) |
| `/opt/minecraft-server/minecraft.service` | Unit systemd (gerada via envsubst com hardening) |
| `/opt/minecraft-server/server.properties` | Config do servidor (gerado pelo installer) |
| `/opt/minecraft-server/runtime.env` | Tuning aplicado (heap, GC, G1 region size) |
| `/opt/minecraft-server/hardware-profile.env` | Perfil de hardware detectado + tier |
| `/opt/minecraft-server/server-icon.png` | Ícone do servidor (64x64 PNG) |
| `/opt/minecraft-server/comandos.sh` | Aliases de shell (autoload via `/etc/profile.d/`) |

## Operação diária

### Comandos principais

```bash
sudo systemctl start minecraft                              # iniciar
sudo systemctl stop minecraft                               # parar (graceful)
sudo systemctl restart minecraft                            # reiniciar
sudo systemctl status minecraft                             # status systemd
sudo /usr/local/libexec/crias/mc-manager.sh status             # status compacto (estado e RAM do servico)
sudo /usr/local/libexec/crias/mc-manager.sh logs recent        # ultimas 150 linhas, sem seguir
sudo /usr/local/libexec/crias/mc-manager.sh logs alerts        # linhas WARN/ERROR/Exception/OOM
sudo /usr/local/libexec/crias/mc-manager.sh logs boot          # logs do boot atual
sudo /usr/local/libexec/crias/mc-manager.sh console            # console SSH estavel; 1 conexao RCON por comando
sudo /usr/local/libexec/crias/mc-manager.sh console --tui      # console RCON em tela cheia (opcional)
sudo /usr/local/libexec/crias/mc-manager.sh backup             # backup imediato (online requer RCON)
sudo /usr/local/libexec/crias/mc-manager.sh health             # porta + RCON
sudo /usr/local/libexec/crias/mc-manager.sh hardware-report    # perfil aplicado
sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware        # recalibrar tier
sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware HIGH   # forçar tier
sudo /usr/local/libexec/crias/mc-manager.sh setup-cron      # configurar timer de backup
```

### Console RCON pelo SSH

O menu **Servidor → Console SSH (estável)** usa uma nova conexão local RCON para cada comando, em vez de manter uma conexão TCP aberta e uma TUI em tela cheia. Se um comando perder a conexão ou atingir o timeout, o gerenciador informa a falha **sem executar novamente o comando** (evita comandos duplicados), e permite a próxima tentativa. Após três falhas seguidas ele retorna ao Hub. Digite `sair` ou use Ctrl+D para fechar.

Para a interface alternativa, use **Servidor → Console em tela cheia (avançado)**. A saída inesperada da interface não deve encerrar o Hub. A opção padrão não mostra os logs em tempo real: use **Servidor → Logs → Acompanhar ao vivo** para isso.

Se a **sessão SSH inteira** cair (e não apenas a conexão RCON), isso é um problema diferente: examine `journalctl -u sshd -b --no-pager -n 80`, `journalctl -u tailscaled -b --no-pager -n 80` e `journalctl -k -b --no-pager | grep -Ei 'oom|killed|memory'` antes de atribuir a falha ao console. Se ocorrer por inatividade de rede, configure keepalive no **cliente SSH**, por exemplo `ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -t usuario@IP_TAILSCALE`. Isso não garante estabilidade quando o servidor estiver travando por RAM/CPU.

### Ajustar a RAM do Minecraft pelo Hub

Abra **Servidor → Memória Java (Xms/Xmx)**. Há opções para verificar o heap atual, usar o orçamento automático do hardware, fixar `Xms = Xmx` no teto seguro calculado ou escolher um Xmx manual em MiB, mantendo Xms fixo ou adaptativo. O menu também permite retornar ao modo automático. Via CLI:

```bash
sudo /usr/local/libexec/crias/mc-manager.sh memory status
sudo /usr/local/libexec/crias/mc-manager.sh memory fixed
sudo /usr/local/libexec/crias/mc-manager.sh memory set 3072 fixed
sudo /usr/local/libexec/crias/mc-manager.sh memory set 3072 dynamic
sudo /usr/local/libexec/crias/mc-manager.sh memory auto
```

**O serviço Minecraft precisa estar parado para aplicar alterações**; o Hub não o para nem reinicia automaticamente. Primeiro pause o Chunky, aguarde o salvamento, realize backup e pare o servidor. Depois ajuste o heap e inicie-o manualmente. Os valores são lidos de `runtime.env`, validados contra o orçamento da RAM física e de cgroups, e escritos atomicamente sem modificar as demais opções de modpack, backup ou versão do Minecraft. O sistema sempre preserva reserva para o SO, SSH, Tailscale, overhead nativo da JVM e limites existentes de systemd. Em `reconfigure-hardware`, o limite manual é preservado se ainda estiver dentro do orçamento calculado, ou a operação é recusada.

`Xms=Xmx` evita expansão do heap do G1, mas pode manter mais memória comprometida; **não representa garantia de menos lag**. Se o gargalo for a geração de chunks, disco ou threads, mudar o heap pode não resolver. O modo automático permanece o padrão. Como `Xmx` é apenas heap Java, não iguale a RAM total da máquina.

### Pré-geração com Chunky

O Chunky (mod ou plugin compatível com o loader instalado) gera terreno dentro do próprio processo Minecraft. Confirme no console que o comando `chunky` existe e faça backup antes de iniciar. Para começar em uma região controlada no Overworld, digite separadamente:

```text
chunky world minecraft:overworld
chunky shape square
chunky center 0 0
chunky radius 1500
chunky selection
chunky start
```

Para progresso automático, execute `chunky quiet 10` uma vez no console (mensagens de progresso a cada aproximadamente 10 segundos), depois use **Servidor → Logs → Acompanhar ao vivo**. Na nova interface, **Servidor → Progresso Chunky (ao vivo)** também consulta `chunky progress` automaticamente por RCON a cada 5, 10, 30 ou 60 segundos (Ctrl+C encerra apenas a visualização). O monitor não inicia nem interrompe a tarefa e sai se o servidor parar ou o RCON falhar três vezes.

O nome da dimensão pode variar; confira os mundos aceitos pelo Chunky se `minecraft:overworld` não funcionar. O **raio é em blocos** (não chunks), então 1500 cobre 3000 × 3000 blocos em formato quadrado. Comece com raios menores em modpacks pesados e monitore CPU, RAM e espaço em disco. Para acompanhar use `chunky progress`, para pausar use `chunky pause`, e para retomar use `chunky continue`. É possível fechar o console e o SSH sem interromper a tarefa **desde que o serviço Minecraft continue rodando**; em reinicializações, consulte o progresso e retome explicitamente se necessário. Não inicie Nether/End simultaneamente em uma máquina limitada. Não use `chunky trim` sem backup: ele apaga chunks.

Referência: [Wiki oficial do Chunky](https://github.com/pop4959/Chunky/wiki/Commands).

### Como ler os logs do Minecraft

| Comando | Resultado |
|---|---|
| `sudo /usr/local/libexec/crias/mc-manager.sh logs` | Acompanha novas linhas, com horário (`Ctrl+C` para sair) |
| `sudo /usr/local/libexec/crias/mc-manager.sh logs recent` | Últimas 150 mensagens completas |
| `sudo /usr/local/libexec/crias/mc-manager.sh logs boot` | Últimas 200 mensagens do boot atual |
| `sudo /usr/local/libexec/crias/mc-manager.sh logs alerts` | Filtra texto `WARN`, `ERROR`, `Exception` e OOM nas últimas 400 mensagens |

**Importante:** o filtro `alerts` é um atalho, não uma auditoria completa. Algumas falhas aparecem como `INFO`, e mensagens `WARN` do Forge podem ser rotineiras. Antes de alterar o servidor, confira as linhas anteriores e posteriores com `logs recent`. O comando não reinicia serviços nem altera configurações.

### Aliases de shell

O instalador publica aliases estáticos em `/etc/profile.d/crias-server.sh` (não executa scripts controlados pelo usuário do jogo como root). Para carregá-los na sessão atual:

```bash
source /etc/profile.d/crias-server.sh
```

| Alias | Equivalente |
|-------|-------------|
| `mcstart` | `sudo systemctl start minecraft` |
| `mcstop` | `sudo systemctl stop minecraft` |
| `mcrestart` | `sudo systemctl restart minecraft` |
| `mcstatus` | `sudo /usr/local/libexec/crias/mc-manager.sh status` |
| `mclogs` | `sudo journalctl -u minecraft -f` |
| `mcconsole` | `sudo /usr/local/libexec/crias/mc-manager.sh console` |
| `mcbackup` | `sudo /usr/local/libexec/crias/mc-manager.sh backup` |
| `mcsetupcron` | `sudo /usr/local/libexec/crias/mc-manager.sh setup-cron` |
| `mcdir` | `cd /opt/minecraft-server` |
| `mcprops` | `sudo nano /opt/minecraft-server/server.properties` |
| `mchw` | `sudo /usr/local/libexec/crias/mc-manager.sh hardware-report` |
| `mcreconfig` | `sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware` |

## Importar um modpack próprio

O instalador aceita um arquivo **`.mrpack`** pessoal, sem exigir que o pacote esteja publicado no Modrinth ou CurseForge. No menu **Fonte do modpack**, escolha:

- **Arquivo .mrpack:** informe o caminho absoluto do arquivo. Para pendrive, conecte e monte o dispositivo antes; o instalador mostra os pontos de montagem disponíveis. Exemplo: `/media/usuario/MEU_USB/Meu pacote.mrpack`.
- **Link direto HTTPS:** informe um endereço que entregue o arquivo diretamente, sem página intermediária ou login. Links temporários devem permanecer válidos até o download terminar.

O arquivo precisa seguir o formato `.mrpack` de Minecraft; um ZIP comum, instalador de outro launcher ou arquivo de exportação CurseForge não é convertido automaticamente. A máquina ainda precisa de internet para baixar o servidor, o loader e os arquivos apontados pelo pacote. Alguns downloads podem exigir acesso próprio ou não permitir distribuição automática. Arquivos marcados como exclusivos do cliente no índice do pacote não são instalados no servidor.

No modo não interativo, use `MINECRAFT_MODPACK_SOURCE=arquivo` com `MINECRAFT_MODPACK_FILE` (caminho absoluto), ou `MINECRAFT_MODPACK_SOURCE=link` com `MINECRAFT_MODPACK_URL` (HTTPS). Mantenha `MINECRAFT_INSTALL_MODPACK=true`. O instalador reconcilia a versão e o loader com os dados do pacote instalado. Opte por não adicionar mods QoL/extras para manter a seleção do pacote.

## Utilitários opcionais de servidor

O instalador oferece **Spark** (diagnóstico), **Chunky** (pré-geração) e **Skin Restorer** (skins) como opções individuais, desativadas por padrão. Ele procura uma versão para o loader e a versão efetivos do modpack e avisa quando algum download não estiver disponível. Os mods são baixados do Modrinth; o Skin Restorer é o mod de Suiranoil, não o plugin de nome parecido.

Spark e Chunky já estão no CriasRealms 0.1.28. O instalador tenta identificar cópias existentes por ID ou nome conhecido, mas uma instalação com arquivos alterados pode precisar de revisão manual. Extras podem precisar de configuração e afetar a compatibilidade; faça backup antes de alterar um mundo existente. Mods e plugins têm formatos e loaders diferentes: um servidor Forge comum não instala plugins Bukkit.

## Server Icon

O installer copia automaticamente `assets/images/branding/server-icon.png` para `/opt/minecraft-server/server-icon.png`. Requisitos do Minecraft:

- Formato: PNG
- Dimensões: **64x64 pixels**
- Tamanho máximo: ~100 KB

Para customizar, substitua `assets/images/branding/server-icon.png` **antes** da instalação, ou após instalar:

```bash
sudo cp seu_icon.png /opt/minecraft-server/server-icon.png
sudo chown minecraft:minecraft /opt/minecraft-server/server-icon.png
```

## Hub central: arquivos e Simple Voice Chat

O menu **Atualizações** do Hub verifica/releases o Crias-Server e troca apenas scripts administrativos, mantendo modpack e mundo intactos. Para atualizar o Arch ou entender as limitações das atualizações de modpacks, consulte o [guia de atualizações](../updates.md).


O `crias-tui` é a interface principal para administrar o servidor via terminal ou SSH sobre Tailscale. **A instalação real verifica e instala o `gum` no Arch do host**, inclusive se você executar diretamente `install.sh`, sem passar pelo bootstrap. O comando `crias-tui` também tenta reparar uma instalação ausente/quebrada de `gum` em sessões interativas. Assim os menus usam **↑/↓ e Enter** normalmente; sem TTY ou durante indisponibilidade de rede, a opção de menu numerado permanece como fallback. `--doctor` e `--help` nunca instalam pacotes. O redesenho visual completo e a paridade com todas as funções avançadas estão registrados no [roadmap do Hub](https://github.com/ViniciusLopes7/Crias-Server/issues/22).

### Gerenciar arquivos pelo Hub

Abra **`crias-tui > Arquivos > Pasta principal do servidor`** para entrar diretamente em `/opt/minecraft-server/` (ou no diretório configurado pelo instalador). O mesmo menu também oferece atalhos para **Mods, Configurações, Mundo atual, Backups e Logs locais**, que abrem a pasta correspondente diretamente. O mundo atual é identificado pelo `level-name` em `server.properties`, inclusive nomes com espaços. Se alguma pasta ainda não existir, o Hub informa isso e permite abrir a pasta principal para navegar manualmente.

O **Midnight Commander** oferece duas colunas, navegação por setas, F3 para visualizar, F4 para editar e F10 para sair. Se estiver ausente, use `Arquivos > Instalar gerenciador de arquivos`, que instala `mc` pelo repositório oficial do Arch somente por escolha do administrador.

**Segurança:** o gerenciador é iniciado como o usuário do Minecraft, **não como root**. Assim ele pode editar arquivos do próprio mundo e configurações graváveis pelo jogo, mas não scripts administrativos root:root. Não é necessário instalar ambiente gráfico no Arch. Para Terraria a mesma opção usa o usuário do Terraria.

### Simple Voice Chat (Forge 1.20.1 e outros loaders)

No Hub, escolha `Voice Chat`. As opções permitem **ver o estado do mod**, **alterar a porta UDP**, **editar a configuração** no Nano e consultar as orientações de rede. O arquivo do mod fica em:

```text
/opt/minecraft-server/config/voicechat/voicechat-server.properties
```

O arquivo costuma ser criado quando o servidor inicia com o mod instalado. A configuração recomendada para jogadores que entram diretamente pelo **mesmo IP Tailscale** é:

```properties
port=24454
bind_address=
voice_host=
max_voice_distance=48
whisper_distance=24
```

A configuração padrão acima usa uma porta **UDP separada** do jogo (`server-port=25565` normalmente é TCP). Se estiver usando nftables com política de entrada DROP, libere a porta de voz **somente pela interface Tailscale**:

```nft
iifname "tailscale0" udp dport 24454 accept
```

Não abra a porta de voz na WAN/roteador se todos os jogadores estiverem na tailnet. O Hub **não altera o firewall automaticamente** — isso evita cortar seu SSH por uma regra incorreta. Alterar a porta/configuração não reinicia Minecraft; as alterações precisam ser aplicadas em um reinício planejado. Para diagnóstico real, execute `/voicechat test <jogador>` dentro do jogo: ver uma porta UDP em escuta no host não comprova o acesso de outro jogador.

O Simple Voice Chat precisa estar instalado em versões compatíveis tanto no **servidor** quanto no **cliente**. Referências oficiais: [Configuração](https://modrepo.de/minecraft/voicechat/wiki/server_config) e [Instalação no servidor](https://modrepo.de/minecraft/voicechat/wiki/server_setup).

## Backup com RCON save-lock

Para garantir backups consistentes com servidor online, o `backup-cron.sh` usa RCON para pausar saves durante o `tar`:

1. `save-off` + `save-all` (pausa saves, força flush)
2. Aguarda 3s para flush completar
3. `tar -I zstd` dos diretórios `world/`, `world_nether/`, `world_the_end/`
4. `save-on` (reativa saves)

### Console interativo com mcrcon

O Crias-Server usa o [mcrcon moderno](https://github.com/mcrcon/mcrcon) (versão fixa `v1.3.0`): console em **tela cheia**, histórico de comandos pelas setas, sugestões com Tab, rolagem PgUp/PgDn e `F1` para ajuda. O instalador do Minecraft **disponibiliza** o utilitário, mas só baixa e instala o cliente quando você executa `setup-console`. Assim, nenhuma dependência de rede extra atrasa a instalação do jogo. O pacote é baixado por HTTPS e o SHA-256 é conferido antes de ser instalado.

**Ativar em uma instalação existente (sem reinstalar o mundo):**

```bash
# Exige os novos scripts administrativos implantados a partir desta versão.
sudo /usr/local/libexec/crias/mc-manager.sh setup-console

# Faça o reinício somente quando puder interromper o jogo:
sudo systemctl restart minecraft

# Abra um console de comandos interativo no terminal ou via SSH:
sudo /usr/local/libexec/crias/mc-manager.sh console
# ou crias-tui > Servidor > Console
```

O comando `setup-console` instala o cliente se preciso, gera uma senha forte **apenas quando não existe outra**, e preserva configurações do `server.properties` como `online-mode`, `level-name`, `motd`, `whitelist` e a senha antiga. O arquivo passa a ter permissões `0600` e pertencer ao usuário do servidor. **Não** reinicia o Minecraft por conta própria. No Hub há também `Servidor > Configurar console RCON`.

Para atualizar **somente as ferramentas administrativas** a partir de um ZIP novo já extraído (sem reinstalar o servidor nem alterar o mundo), execute na pasta do projeto:

```bash
sudo install -D -o root -g root -m 0755 minecraft/mc-manager.sh /usr/local/libexec/crias/mc-manager.sh
sudo install -D -o root -g root -m 0755 minecraft/install-mcrcon.sh /usr/local/libexec/crias/install-mcrcon.sh
sudo install -D -o root -g root -m 0644 shared/lib/manager-common.sh /usr/local/libexec/crias/lib/manager-common.sh
sudo install -D -o root -g root -m 0755 crias-tui.sh /usr/local/bin/crias-tui
```

**O console interativo é diferente dos logs:** RCON permite executar comandos e visualizar as respostas. Para mensagens contínuas de mods, erros e inicialização, use separadamente `mc-manager.sh logs`. Se RCON estiver ausente ou não houver TTY, `console` explica o problema em vez de abrir um fluxo de logs inesperado.

**Proteção:** RCON tem privilégios de administrador e **não é criptografado**. O cliente se conecta a `127.0.0.1` **a partir do próprio host**, inclusive quando você entra por SSH via Tailscale. A configuração do Java pode escutar em mais interfaces; **bloqueie a porta TCP 25575 no firewall, inclusive para outros dispositivos da tailnet**, e nunca encaminhe essa porta no roteador. Não publique a senha nos logs, prints ou comandos com `-p`. Consulte [Segurança](../security.md).

### Configuração RCON para administração

O comando `setup-console` grava ou mantém estas propriedades:

```properties
enable-rcon=true
rcon.port=25575
rcon.password=<senha-aleatoria-gerada-ou-preservada>
```

Se já houver uma configuração RCON ativa e senha própria, ela é preservada. Se você usa o agente Discord com RCON, mantenha uma senha compatível com as restrições de configuração YAML do agente.

### Sem RCON

Sem `mcrcon` ou RCON configurado, o backup falha por padrão. A opção explícita `BACKUP_REQUIRE_CONSISTENT=false` em `runtime.env` habilita o modo best-effort; o arquivo produzido pode conter um mundo inconsistente.

## Mods

Veja [mods.md](mods.md) para guias detalhados de:

- **Chunky** — pré-geração de chunks
- **Essential Commands** — home, tpa, spawn, rtp, back, nickname
- **Universal Graves** — tumba ao morrer
- **TabTPS** — monitor de TPS/MSPT
- **Styled Chat + Placeholder API** — customização de chat + títulos

Para o **seletor de modpacks dinâmico** (top-10 Modrinth, busca por nome,
compatibilidade loader+MC, sugestão de versão mais próxima), veja
[modpacks.md](modpacks.md).

### Loaders suportados

| Loader | Descrição |
|--------|-----------|
| `fabric` | Padrão (default). Compatível com modpacks `.mrpack` do Modrinth. |
| `quilt` | Compatível com a maioria dos mods Fabric. |
| `vanilla` | Servidor vanilla sem mods (apenas server.jar oficial). |
| `forge` | Para mods Forge (instalador do Forge é executado pelo `mrpack-install`). |
| `neoforge` | Fork moderno do Forge. |

> **`paper` foi removido em v1.2.0** — o fluxo de modpacks usa `.mrpack`
> (formato Modrinth para Fabric/Quilt), e paper não tem fluxo equivalente.
> Se você precisa de paper, instale manualmente após o setup.

Para listar a lista de mods QoL instalados (CSV configurável em `config.env`):

```bash
grep MINECRAFT_QOL_MODS config.env
```

## Arquivos de runtime relevantes

| Arquivo | O que contém |
|---------|--------------|
| `/opt/minecraft-server/runtime.env` | `MIN_RAM`, `MAX_RAM`, `GC_MAX_PAUSE`, `G1_REGION_SIZE`, `BACKUP_RETENTION_DAYS`, `BACKUP_ZSTD_LEVEL` |
| `/opt/minecraft-server/hardware-profile.env` | `HW_TOTAL_RAM_MB`, `HW_CPU_CORES`, `HW_DISK_TYPE`, `HW_TIER`, todos os `MC_*` |
| `/opt/minecraft-server/server.properties` | Config padrão do Minecraft (porta, MOTD, view-distance, max-players, etc.) |

## Troubleshooting

### Servidor não inicia

```bash
sudo journalctl -u minecraft -n 50 --no-pager
sudo /usr/local/libexec/crias/mc-manager.sh health
```

Causas comuns:
- Java 21+ não instalado: `sudo pacman -S jdk21-openjdk`
- Porta 25565 em uso: `sudo ss -tlnp | grep 25565`
- `eula.txt` faltando: `echo "eula=true" > /opt/minecraft-server/eula.txt`

### Falta de memória ou encerramento por OOM

Heap está em `/opt/minecraft-server/runtime.env` (`MIN_RAM`, `MAX_RAM`). Reduza via `reconfigure-hardware`:

```bash
sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware LOW
sudo systemctl restart minecraft
```

### Backup falha

```bash
# Verificar se RCON está respondendo
sudo /usr/local/libexec/crias/mc-manager.sh health

# Verificar último backup
ls -lh /opt/minecraft-server/backups/

# Ver logs do timer systemd
sudo journalctl -u minecraft-backup.service -n 50
```

### Console interativo não abre

Execute `sudo /usr/local/libexec/crias/mc-manager.sh setup-console`, confira `enable-rcon=true` e reinicie o Minecraft quando puder. O console exige um terminal TTY (local ou SSH); ele não funciona ao redirecionar stdin para arquivo ou pipe. Use `logs recent` separadamente para inspecionar falhas do servidor.

## Veja também

- [mods.md](mods.md) — Guias dos mods QoL
- [../tutorial.md](../tutorial.md) — Tutorial de operação passo-a-passo
- [../Tailscale.md](../Tailscale.md) — Conexão via Tailscale
- [../restore.md](../restore.md) — Restore de backups
- [../security.md](../security.md) — Firewall, logs, hardening

## Recuperação de instalação parcial

Se `sudo crias-tui` não existir, confira `ls -l /usr/local/bin/crias-tui` e `readlink -f /opt/crias-server`. Em versões atualizadas, o hub é instalado **antes** de configurar os jogos e oferece `sudo crias-tui --doctor` para avaliar memória e serviços sem alterar o host. Não reinstale ou remova um mundo existente antes de verificar a integridade do backup.


## Backup e acesso remoto sem obrigatoriedade

Nao ha backup automatico sem o administrador ativar o timer via `mc-manager.sh setup-cron`. Backup remoto permanece desligado sem `BACKUP_REMOTE_PATH`; Minecraft inicia normalmente sem `mcrcon`/RCON. Se um backup com mundo **ativo** for solicitado e RCON estiver indisponivel, `BACKUP_REQUIRE_CONSISTENT=true` faz **somente o backup** falhar, preservando o jogo e evitando um arquivo potencialmente inconsistente. Para backup com Minecraft parado, uma copia de dados pode ser feita conforme o procedimento de restauracao, sem RCON.

O instalador recomenda OpenSSH em modo interativo e verifica a porta 22 **antes** de instalar o Tailscale e baixar o jogo. Para usuarios existentes, nenhuma regra sudo global e sobrescrita. Em instalacao nao interativa, defina `INSTALL_SSH=true` e `SSH_USER` com uma conta administrativa preexistente ou com chave autorizada (novas contas sem senha interativa sao criadas com senha bloqueada).
