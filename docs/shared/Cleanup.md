# Politica de Cleanup do Stack Oposto

Quando CLEANUP_OTHER_STACK=true, o instalador executa uma desativacao segura do stack oposto.

## Comportamento do cleanup (padrao)

- Desativa a unidade systemd do stack oposto (stop + disable).
- Remove o autoload de aliases gerado pelo instalador (arquivo em /etc/profile.d/crias-server.sh).
- Remove entradas de crontab criadas pelo instalador para backups (quando aplicavel).

OBS: O fluxo padrao NAO remove dados em `/opt` nem exclui automaticamente usuarios do sistema. Essas operacoes sao destrutivas e so devem ocorrer via um fluxo separado, explicitamente opt-in e documentado.

## Seguranca e confirmacao

O instalador solicita confirmacao explicita antes de desativar o stack oposto quando detectar dados ou servicos existentes. Operacoes destrutivas adicionais (remoção de /opt / usuario) nao fazem parte do fluxo padrao e exigem um subcomando manual com confirmacao adicional.

## Observacao operacional

Os arquivos `comandos.sh` gerados pelo instalador incluem cabecalho identificando a origem do arquivo, para diferenciar aliases gerados pelo projeto de aliases pessoais do operador.

## Recarregando o shell após cleanup

Após o cleanup do stack oposto, os aliases do instalador podem ter sido removidos de `/etc/profile.d/crias-server.sh`. 

Para recarregar o ambiente de shell na sessão atual:

```bash
source /etc/profile.d/crias-server.sh
```

Ou abra um novo terminal, que carregará automaticamente as configurações atualizadas.

## Recomendacao

Antes de confirmar qualquer limpeza automatica:

1. Faça backup externo dos mundos e arquivos importantes.
2. Revise manualmente o que sera desativado e, se necessario, o que sera removido por um fluxo opt-in separado.
3. Confirme que o stack selecionado para manter e o correto.
