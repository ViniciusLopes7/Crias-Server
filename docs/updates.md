# Atualizações pelo Hub do Crias-Server

O sistema de atualização distingue o **gerenciador Crias-Server**, o **Arch Linux** e os **jogos/modpacks**. O Hub (`crias-tui`) oferece um menu `Atualizações` com confirmações explícitas. Nenhuma tarefa de atualização é agendada automaticamente.

## 1. Atualizar o Crias-Server sem reinstalar o mundo

No Hub: `Atualizações → Verificar release Crias-Server`, depois `Atualizar Hub e ferramentas Crias-Server`. Também existem comandos equivalentes:

```bash
crias-update check
sudo crias-update apply
```

Este fluxo:

1. Consulta a **release oficial publicada** de [ViniciusLopes7/Crias-Server](https://github.com/ViniciusLopes7/Crias-Server/releases). **Não** executa código de commits da `main` que ainda não passaram pelo processo de release.
2. Baixa `crias-server-slim.zip` e `sha256sums.txt` por HTTPS, compara o SHA-256 e verifica scripts obrigatórios e sua sintaxe antes da publicação.
3. Reutiliza a publicação versionada do bootstrap: nova versão em `/opt/crias-server.releases/release.*` e troca atômica do link `/opt/crias-server`. Mantém a versão anterior para recuperação.
4. **Preserva o `config.env` local**, sem carregá-lo como shell ou imprimi-lo. O arquivo é instalado com permissão `0600`.
5. Atualiza `/usr/local/bin/crias-tui`, `/usr/local/bin/crias-update`, os managers e bibliotecas em `/usr/local/libexec/crias`; cada arquivo administrativo é instalado com propriedade `root:root` e permissão controlada.
6. Se a atualização administrativa falhar, restaura os scripts anteriores e o link da versão anterior.

**Não altera:** `/opt/minecraft-server`, `/opt/terraria-server`, mundos, mods, modpacks, loaders, `server.properties`, `runtime.env`, units systemd, quantidade de RAM, Java, Tailscale, SSH ou regras de firewall. O Minecraft/Terraria **não é interrompido nem reiniciado** por este comando.

O procedimento exige que `/opt/crias-server` seja um **symlink versionado gerenciado pelo bootstrap**. Se você instalou a partir de uma pasta Git comum, o atualizador recusa a troca e informa como procurar uma instalação compatível; ele não transforma arbitrariamente uma árvore desconhecida em instalação gerenciada.

Em versões anteriores à introdução do atualizador, o Hub ainda não oferece esse menu. Será preciso instalar a primeira versão que já inclui `crias-update` e, a partir dela, usar as atualizações isoladas.

### Segurança e limites

A checagem SHA-256 é contra o manifesto da *mesma release do GitHub*, portanto confirma integridade do pacote mas **não prova autenticidade de forma independente** caso um invasor controle a release e seu checksum. Confira a origem oficial, as notas da release e o CI antes de atualizar. Falha de rede/checksum aborta antes de tocar na versão instalada. Execute o procedimento somente com privilégios de administrador.

O rollback protege os scripts administrativos dentro de uma mesma atualização; não é um snapshot do sistema operacional, e um desligamento abrupto/SIGKILL durante o deploy pode exigir reparo administrativo manual. Não substitui backups de dados do mundo.

## 2. Atualizar pacotes Arch Linux

No Hub: `Atualizações → Verificar pacotes Arch`, depois `Atualizar pacotes Arch (manutenção)`, quando apropriado.

```bash
crias-update arch-check
sudo crias-update arch-apply
```

A consulta usa `checkupdates` do `pacman-contrib` quando disponível, sem alterar o banco de pacotes do sistema. Sem ele, mostra a lista local de `pacman -Qu` e avisa que ela pode estar desatualizada.

A aplicação usa `pacman -Syu`, **não uma atualização parcial**. Requer TTY, servidor Minecraft/Terraria **parado** e digitar literalmente `ATUALIZAR ARCH` para confirmar. **Não** para o jogo, não reinicia o host e não reinicia serviços por conta própria. Planeje a manutenção e verifique se kernel/Java/systemd exigem reboot antes de iniciar o jogo.

Para instalar `checkupdates`, se desejar:

```bash
sudo pacman -S --needed pacman-contrib
```

## 3. Minecraft, Terraria, mods e modpacks

**As atualizações do jogo ficam separadas deste mecanismo.** Um simples `pacman -Syu` não atualiza automaticamente um modpack; e baixar a última versão do Forge, NeoForge ou Simple Voice Chat sem verificar compatibilidade pode quebrar mundos ou impedir a inicialização.

Antes de trocar o pacote/loader, faça um backup verificável, registre as versões instaladas, revise dependências e faça a mudança em uma manutenção separada. Esta primeira versão do Hub não oferece atualização automática de mods nem migração automática de mundo.

## Validação

O CI do PR executa testes de download simulado sem rede, checksum correto/incorreto, preservação de `config.env`, idempotência, falha após deploy parcial e restauração do link/arquivos administrativos. A bateria roda também na VM Arch/QEMU. Isso testa os contratos do atualizador, mas não substitui um teste no notebook real com uma release já publicada.

Se a atualização falhar, execute `sudo crias-tui --doctor` e confira `readlink -f /opt/crias-server`. Não execute uma reinstalação completa de Minecraft como forma de atualizar o Hub.
