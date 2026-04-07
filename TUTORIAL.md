# Adrenaline + QoL - Índice de Tutoriais

Este é o índice para facilitar sua navegação pelos guias do servidor.
Toda a documentação técnica foi modularizada para manter tudo limpo e conciso.

## Guias e Documentação:

### Instalação
- [Instalação Manual Passo a Passo](docs/InstalacaoManual.md) -> Guia completo e explicativo para o passo a passo da instalação do servidor.
- [Rede e Conexão via Tailscale (VPN)](docs/Tailscale.md) -> Guia detalhado de como se conectar no servidor host.

### Qualidade de Vida (Mods QoL)
- [Guia do Chunky](docs/Chunky.md) -> Como pré-gerar mundos para evitar lag.
- [Comandos Essenciais](docs/EssentialCommands.md) -> Explicação dos comandos base (/home, /tpa, /spawn).
- [Formatação de Nomes e Chat](docs/StyledChat.md) -> Guia de como dar nicks coloridos para os jogadores.

### Comandos do Sistema Host
Após a instalação, o seu perfil `minecraft` ou `root` terá acesso a uma série de atalhos rápidos diretamente do console:
* `mcstart`     - Iniciar servidor
* `mcstop`      - Parar servidor corretamente
* `mcrestart`   - Reiniciar servidor
* `mcstatus`    - Exibe status do serviço, RAM, disco e informações
* `mclogs`      - Exibe logs em tempo real
* `mcconsole`   - Entra no console do jogo (Screen da sessão)
* `mcbackup`    - Realiza backup forçado
* `mcchunky`    - Menu interativo do Chunky (Gerar Mundo)
* `mctailscale` - Status da VPN Tailscale
* `mcdir`       - Atalho para a pasta do servidor
* `mcprops`     - Abre o editor no arquivo `server.properties`
* `mcmod`       - Adição/remoção/listagem de mods. Ex: `mcmod add lithium`, `mcmod remove lithium`
