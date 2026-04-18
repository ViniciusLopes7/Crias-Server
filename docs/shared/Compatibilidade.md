# Compatibilidade e Transicao

O periodo de transicao terminou: os arquivos legados da raiz foram removidos para padronizar a estrutura modular.

## Estado atual

- Nao existem mais wrappers legados na raiz.
- Cada stack vive no proprio diretorio modular.

## Diretriz

Use preferencialmente os caminhos modulares:

- minecraft/start-server.sh
- minecraft/mc-manager.sh
- minecraft/backup-cron.sh
- minecraft/setup-cron.sh
- terraria/start-terraria.sh
- terraria/tt-manager.sh
- terraria/backup-cron.sh
- terraria/setup-cron.sh

## Observacao

Essa organizacao reduz ambiguidade operacional e simplifica manutencao/CI.
