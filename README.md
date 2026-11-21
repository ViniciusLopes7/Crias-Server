# Crias-Server

<p align="center">
  <img src="assets/images/branding/EscudoCrias.png" alt="Escudo do Crias-Server" width="150">
</p>

<p align="center">
  <strong>Instalação e gerenciamento de servidores Minecraft e Terraria no Arch Linux.</strong>
</p>

<p align="center">
  <a href="https://github.com/ViniciusLopes7/Crias-Server/releases"><img src="https://img.shields.io/github/v/release/ViniciusLopes7/Crias-Server?style=flat-square" alt="Última release"></a>
  <a href="https://github.com/ViniciusLopes7/Crias-Server/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ViniciusLopes7/Crias-Server/ci.yml?style=flat-square" alt="Estado do CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/ViniciusLopes7/Crias-Server?style=flat-square" alt="Licença"></a>
</p>

O **Crias-Server** reúne um instalador interativo, scripts de operação e serviços `systemd` para hospedar **Minecraft** ou **Terraria** em um computador com Arch Linux. Ele configura o servidor, aplica ajustes iniciais de hardware e oferece ferramentas de administração e backup. Recursos como Tailscale e controle por Discord são opcionais.

## Instalação rápida

**Requisitos:** Arch Linux instalado, acesso `sudo` e conexão com a internet. O projeto não distribui mais uma ISO personalizada; use a [imagem oficial do Arch Linux](https://archlinux.org/download/) para instalar o sistema primeiro.

No terminal do Arch Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash
```

O bootstrap baixa a **última release publicada**, verifica o checksum SHA-256 do pacote e abre o instalador. Siga os menus para escolher o jogo, a versão, os mods e as opções do sistema.

> **Atenção:** a `main` pode conter correções mais recentes que a última release. Consulte [Releases](https://github.com/ViniciusLopes7/Crias-Server/releases) antes de atualizar um servidor existente. Faça backup dos mundos e configurações antes de reinstalar ou trocar modpacks.

Se você preferir inspecionar o instalador antes da execução, consulte o [código do bootstrap](crias-bootstrap.sh) e siga o [guia completo de instalação](docs/tutorial.md).

## Depois da instalação

Use o hub no terminal para acessar as operações habituais:

```bash
sudo crias-tui             # menu de gerenciamento
sudo crias-tui --doctor    # diagnóstico de somente leitura
```

O diagnóstico `--doctor` e a instalação antecipada do hub já estão integrados à versão atual. Ele pode ser utilizado mesmo após uma instalação parcial para conferir serviços, RAM e acesso remoto.

Os serviços também podem ser operados diretamente pelo `systemd`:

```bash
sudo systemctl status minecraft   # ou terraria
sudo journalctl -u minecraft -n 80 --no-pager
```

Para comandos de backup, console, reconfiguração e restauração, consulte o [manual de operação](docs/tutorial.md) e os guias específicos de cada jogo.

## O que você pode configurar

| Área | Recursos disponíveis |
|---|---|
| **Minecraft** | Vanilla, Fabric, Quilt, Forge e NeoForge; seleção de versões e modpacks pelo Modrinth |
| **Modpacks próprios** | Importação de arquivos `.mrpack` locais, de pendrive ou por URL HTTPS direta |
| **Terraria** | Servidor vanilla e opção de tModLoader com mods |
| **Administração** | Serviços `systemd`, terminal de gerenciamento, logs e ajustes iniciais de RAM/CPU |
| **Backup e recuperação** | Backups manuais e agendados por opção; backup com Minecraft ligado exige RCON para consistência; backup remoto desativado por padrão |
| **Acesso remoto** | OpenSSH recomendado e testado antes do jogo; Tailscale opcional para SSH e amigos; agente Discord opcional |

O instalador usa `config.env` para definir os padrões. A maior parte das escolhas também pode ser feita nos menus interativos. Para instalações automatizadas, consulte a [configuração não interativa](docs/tutorial.md).

## Documentação

Escolha um guia conforme a tarefa:

| Preciso de... | Consulte |
|---|---|
| Instalar, atualizar ou recuperar uma instalação | [Tutorial de operação](docs/tutorial.md) |
| Usar um `.mrpack` de pendrive ou link | [Modpacks Minecraft](docs/minecraft/modpacks.md) |
| Gerenciar Minecraft ou Terraria | [Minecraft](docs/minecraft/README.md) · [Terraria](docs/terraria/README.md) |
| Entender o hub e seus erros | [Interface TUI](docs/tui.md) |
| Ajustar RAM e investigar encerramento por OOM | [Tuning por hardware](docs/hardware-tuning.md) |
| Configurar VPN, segurança ou restaurar mundos | [Tailscale](docs/Tailscale.md) · [Segurança](docs/security.md) · [Restauração](docs/restore.md) |
| Conectar o bot e o agente Discord | [Agente Go](discord-agent/README.md) · [Bot Python](discord-bot/README.md) |
| Entender os testes e seus limites | [Validação QEMU](docs/testing-qemu.md) |

O [índice da documentação](docs/README.md) reúne todos os guias. Mudanças entre versões estão no [Changelog](CHANGELOG.md), e os recursos planejados no [Roadmap](ROADMAP.md).

## Qualidade e limites

A integração contínua executa testes Bash, Go e Python, valida caminhos de inicialização com Java 21/25 e utiliza uma VM QEMU com Arch Linux e `systemd` reais. A VM também exercita cenários de falha e serviços instalados, mas **não comprova que um modpack grande inicia um mundo jogável ou que clientes conseguem se conectar**. Os testes Minecraft atualmente param na EULA sem aceitá-la.

Para trabalhar no repositório:

```bash
git clone https://github.com/ViniciusLopes7/Crias-Server.git
cd Crias-Server
bash tests/run-all.sh
```

Veja o [guia de validação](docs/testing-qemu.md) antes de considerar uma instalação pronta para jogadores: o teste final com o modpack completo e clientes conectados deve ocorrer em hardware real.

## Contribuição e licença

Bugs e sugestões podem ser registrados em [Issues](https://github.com/ViniciusLopes7/Crias-Server/issues). Para detalhes internos, consulte os [diretórios do projeto](docs/README.md) e o histórico das alterações. O projeto é distribuído sob licença [MIT](LICENSE).
