# Documentacao Crias-Server

## Estrutura

- minecraft/: guias especificos da stack Minecraft
- terraria/: guias especificos da stack Terraria
- shared/: guias compartilhados (hardware, cleanup e operacao geral)

## Guias principais

- minecraft/README.md
- terraria/README.md
- shared/HardwareTuning.md
- shared/Cleanup.md
- shared/Compatibilidade.md

## Observacao sobre CI

O pipeline em .github/workflows/build-iso.yml executa testes smoke e dry-run de instalacao completa para Minecraft e Terraria em ambiente Arch Linux.
