# Politica de Cleanup do Stack Oposto

Quando CLEANUP_OTHER_STACK=true, o instalador pode remover o stack nao escolhido.

## O que pode ser removido

- Unidade systemd do stack oposto
- Usuario do sistema vinculado ao stack oposto
- Diretorio de instalacao em /opt
- Entradas de cron relacionadas ao backup do stack oposto

## Seguranca

A remocao e destrutiva e so executa com confirmacao explicita do operador.

## Observacao operacional

Os arquivos `comandos.sh` gerados pelo instalador agora incluem cabecalho identificando a origem do arquivo. Isso ajuda a diferenciar aliases do projeto de aliases pessoais do operador.

## Recomendacao

Antes de confirmar cleanup:

1. Garanta backup externo dos mundos.
2. Revise o diretorio que sera removido.
3. Confirme que o stack selecionado e o correto.
