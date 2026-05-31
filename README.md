# Crias-Server

<p align="center">
    <img src="assets/images/branding/EscudoCrias.png" alt="Escudo Crias" width="220" />
</p>

Instalador modular para servidor de jogos em Arch Linux, com escolha inicial entre Minecraft e Terraria, tuning automatico por hardware e desativacao nao destrutiva do stack nao selecionado.

## Principais recursos

- Escolha inicial de stack: Minecraft ou Terraria.
- Estrutura modular por pasta: cada stack isolado.
- Camada compartilhada com deteccao de hardware (CPU/RAM/disco).
- Tuning automatico por tier (LOW/MID/HIGH) com override manual opcional.
- Comando de recalibracao de hardware apos instalacao.
- Limpeza nao destrutiva do stack oposto com confirmacao explicita.
- Modo nao interativo e DRY_RUN para testes de instalacao em CI.

## Estrutura do projeto

```text
.
|-- install.sh
|-- config.env
|-- assets/
|   `-- images/
|       `-- branding/
|           |-- EscudoCrias.png
|           |-- TronoCrias.png
|           `-- server-icon.png
|-- shared/
|   `-- lib/
|       |-- common.sh
|       |-- hardware-profile.sh
|       |-- system-tuning.sh
|       |-- minecraft-tuning.sh
|       `-- terraria-tuning.sh
|-- minecraft/
|   |-- install.sh
|   |-- start-server.sh
|   |-- mc-manager.sh
|   |-- backup-cron.sh
|   |-- setup-cron.sh
|   `-- minecraft.service
|-- terraria/
|   |-- install.sh
|   |-- start-terraria.sh
|   |-- tt-manager.sh
|   |-- backup-cron.sh
|   |-- setup-cron.sh
|   `-- terraria.service
`-- docs/
    |-- README.md
    |-- minecraft/
    |-- terraria/
    `-- shared/
```

## Quick Start

1. Ajuste configuracoes iniciais em config.env (opcional).
2. Execute o instalador:

```bash
chmod +x install.sh
sudo ./install.sh
```

3. No passo 1 do instalador, escolha:
   - Minecraft
   - Terraria

4. Aguarde instalacao de dependencias, stack escolhido e tuning automatico.

Observacao: se voce usar diretorio customizado no install, os scripts de runtime seguem esse caminho automaticamente.

## Execucao automatizada (CI / sem prompts)

Para rodar em modo nao interativo:

```bash
sudo -E NON_INTERACTIVE=true ACCEPT_EULA=true SERVER_TYPE=minecraft ./install.sh
```

Para validar pipeline sem alterar o host (dry-run):

```bash
sudo -E NON_INTERACTIVE=true DRY_RUN=true SERVER_TYPE=terraria ./install.sh
```

Flags importantes no config.env:

- NON_INTERACTIVE=true: desativa perguntas interativas.
- DRY_RUN=true: evita operacoes destrutivas (pacman/useradd/systemd/cleanup).
- Para Minecraft em modo nao interativo, aceite a EULA com ACCEPT_EULA=true.
- O arquivo usa formato shell `CHAVE=valor`; use aspas quando o valor tiver espacos ou caracteres especiais.

Downloads verificados (opcional):

- MRPACK_SHA256: SHA256 esperado para o binario `mrpack-install` (opcional).
- TERRARIA_SHA256: SHA256 esperado para o zip do servidor Terraria (opcional).
- Forneca variaveis `*_SHA256` correspondentes para habilitar verificacao de checksum durante o instalador. Quando ausente, o instalador baixa e emite um aviso.
 - Per-mod SHA variables: `MOD_<NAME>_SHA256` (e.g. `MOD_CHUNKY_SHA256`) can be provided to verify individual QoL mod downloads.

Guia operacional e de seguranca:

- [docs/shared/SecurityAndOps.md](docs/shared/SecurityAndOps.md) cobre firewall, rotacao de logs, health checks e limite de MAC.
 
Banner:

- Coloque um arquivo `banner.txt` ASCII em `assets/branding/banner.txt` ou `/etc/crias/banner.txt` para mostrar um banner personalizado no instalador. Uma amostra `assets/branding/banner.txt` foi adicionada ao repositório.

Dica para CI: use CONFIG_FILE apontando para um arquivo temporario, sem precisar alterar o config.env versionado.

## Atencao: desativacao do stack oposto

Durante a instalacao, se existir stack oposto no host, o instalador apenas desativa os servicos associados e remove o autoload de aliases correspondente.

Nao ha remoção de dados em `/opt` nem exclusao de usuario sem acao explicita fora do fluxo padrao.

## Tuning por hardware

O sistema detecta automaticamente RAM, CPU e tipo de disco, e aplica um tier.

Esse tuning afeta tanto os parametros de jogo quanto limites de servico systemd (MemoryMax) na instalacao.

| Tier | Perfil alvo | Exemplo de comportamento |
|------|-------------|--------------------------|
| LOW  | Maquinas limitadas | Menos players, distancias menores, heap reduzido |
| MID  | Maquinas intermediarias | Balanceado para estabilidade e desempenho |
| HIGH | Maquinas fortes | Mais players, distancias maiores, parametros mais agressivos |

### Override manual de tier

No config.env:

```bash
FORCE_HARDWARE_TIER="HIGH"
```

Valores aceitos: LOW, MID, HIGH ou vazio para auto.

## Recalibracao apos instalacao

Minecraft:

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware HIGH
```

Terraria:

```bash
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware LOW
```

## Comandos principais

Minecraft:

- sudo systemctl start minecraft
- sudo /opt/minecraft-server/mc-manager.sh status
- sudo /opt/minecraft-server/mc-manager.sh backup

Terraria:

- sudo systemctl start terraria
- sudo /opt/terraria-server/tt-manager.sh status
- sudo /opt/terraria-server/tt-manager.sh backup

## Aliases de comandos

Durante a instalacao, cada stack gera um arquivo de aliases e o instalador configura o autoload automaticamente via `/etc/profile.d/crias-server.sh`:

- /opt/minecraft-server/comandos.sh
- /opt/terraria-server/comandos.sh

As entradas sao idempotentes (nao duplicam linhas em reinstalacoes).

Para usar imediatamente na sessao atual:

```bash
source /etc/profile.d/crias-server.sh
```

Exemplos rapidos:

- mcstart, mcstatus, mclogs, mcbackup, mcreconfig
- ttstart, ttstatus, ttlogs, ttbackup, ttreconfig

## Gerenciamento de Serviços

Cada stack (Minecraft e Terraria) cria um arquivo systemd em `/etc/systemd/system/`:

- `minecraft.service`
- `terraria.service`

### Comportamento de Conflitos

Os dois servicos sao marcados com a diretiva `Conflicts=` no systemd, o que significa:

- Apenas **um** stack pode rodar simultaneamente no mesmo host
- Se tentar iniciar um stack enquanto o outro está ativo, o systemd desativará o conflitante automaticamente

Isso é intencional e evita uso duplicado de recursos (RAM, CPU, disco). Para executar ambos:

1. Parar o stack atual: `sudo systemctl stop minecraft` ou `sudo systemctl stop terraria`
2. Iniciar o novo stack: `sudo systemctl start terraria` ou `sudo systemctl start minecraft`

Modificar este comportamento requer edição manual dos arquivos .service e é **não recomendado** para ambientes padrão.

## Documentacao

Consulte a documentação canônica em [docs/README.md](docs/README.md) para guias detalhados (instalação, operação, tuning e runbooks).

## CI no GitHub Actions

O workflow em .github/workflows/build-iso.yml agora roda:

- lint de shell scripts
- testes rapidos de scripts (sintaxe + parser de log QEMU com fixtures)
- testes de contrato do instalador (falha esperada para config invalida e precedencia de variaveis)
- smoke tests em container Arch Linux
- dry-run de instalacao completa (Minecraft e Terraria) em container Arch Linux
- build da ISO apenas se os testes passarem

O repositório também inclui `tests/minecraft-tuning-test.sh` para validar alocação de memória e outros contratos shell em `tests/`.

## Testes locais rapidos

Para validar regressao de scripts sem buildar ISO:

```bash
bash tests/quick-script-tests.sh
```

Para validar contratos do instalador no ambiente Arch:

```bash
sudo bash tests/install-contracts.sh
sudo bash tests/arch-dry-install.sh
```
