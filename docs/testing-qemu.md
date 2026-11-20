# Validação em QEMU: cobertura, evidências e limites

O job `test-arch-vm` inicia uma máquina virtual Arch Linux oficial descartável em QEMU. Diferentemente dos testes de sintaxe e dos containers, o sistema convidado utiliza **systemd como PID 1**, usuários reais, cgroups e serviços instalados. O objetivo é revelar falhas operacionais antes de publicar uma release.

## Como a validação é executada

1. `tests/qemu/run-vm.sh` baixa uma imagem Arch (`qcow2`) e seu checksum SHA-256, valida o arquivo e inicia QEMU com cloud-init.
2. O runner envia uma cópia do commit testado para a VM, sem utilizar a branch mutável `main` durante a execução.
3. `tests/qemu/guest-test.sh` executa contratos, configura serviços reais e verifica os resultados com `systemctl`, `journalctl` e as saídas dos processos.
4. O job guarda logs do console serial e do convidado como artefatos da execução, inclusive se ocorrer falha.

## O que efetivamente é testado

| Área | Evidência verificada | Limitação |
|---|---|---|
| Boot Arch + systemd | SSH, cloud-init e PID 1 | Não prova compatibilidade com todos os drivers físicos |
| Bootstrap | Extração versionada e rollback via testes do projeto | Não equivale a atualizar um servidor com mundo real e modpack pesado |
| Hub `crias-tui` | Instalação antecipada, usuário/permissões e `--doctor` | Interface `gum` com TTY deve ser revisada visualmente |
| Serviço Minecraft | Unit criada, permissões, processo não-root, limite do cgroup e início do Java | Usa uma classe Java inofensiva para testar a unit |
| Falha OOM | Serviço descartável com limite de memória propositalmente insuficiente e resultado `oom-kill` | Não mede a RAM necessária a um modpack específico |
| Terraria | Instalador real, serviço iniciado e porta em escuta | Não valida longa sessão de jogo nem todos os mods tModLoader |
| Minecraft Vanilla, Fabric, Quilt, Forge e NeoForge | Download/instalação reais; os cinco executáveis chegam ao aviso da EULA | **A EULA permanece `false`; não há mundo nem jogadores na VM** |
| Modpack `.mrpack` | Arquivo de teste local importado, overrides copiados e loader/versão conciliados | Não equivale a um pacote de centenas de mods |
| Mods opcionais | Download de arquivos e prevenção de duplicidade | Compatibilidade completa exige servidor modificado ativo |
| Backups e recovery | Contratos e casos de restauração/rollback executados na VM | RCON e integridade semântica do mundo não são testados ao vivo |

## O que não pode ser garantido pelo CI

Uma pipeline verde não demonstra que **todo bug possível foi encontrado**. Permanecem necessários testes de aceitação para:

- **Modpack real:** importar o `.mrpack` usado pela equipe, aceitar a EULA apenas em ambiente autorizado, iniciar mundo novo e carregar todos os mods.
- **Jogo multiplayer:** conectar clientes compatíveis, testar entrada, permissões, geração de chunks, CPU e memória durante carga prolongada.
- **Backup consistente:** testar RCON real (`save-off`, `save-all`, `save-on`) e restauração de mundo enquanto o servidor está ativo.
- **Discord e rede:** validar o trajeto autenticado bot → Funnel/Tailscale → agente → systemd/RCON, sem expor tokens nos logs.
- **Falhas de ambiente:** hardware com 2–8 GB, disco cheio, perda de rede, reboot inesperado, múltiplas versões Java e atualização de instalação existente.

## Como inspecionar uma execução que falhou

Abra **Actions → CI → Arch VM (QEMU and systemd)** no PR. Consulte a etapa do teste, depois baixe o artefato `qemu-arch-logs` do workflow para examinar:

- `guest.log`: saída combinada dos testes executados dentro do Arch.
- `serial.log`: console serial do QEMU; útil quando o SSH ou o boot falha.
- `failure-journal.log`: últimas mensagens do journal quando a VM esteve acessível.
- `failure-system.log`: unidades com falha, memória e espaço em disco.

A coleta de evidências é uma operação de diagnóstico; os artefatos não devem incluir tokens reais. Não publique arquivos de `runtime.env`, `agent.yaml` nem credenciais de cloud-init/SSH de ambientes de produção.

## Como executar localmente

Em uma máquina Linux com dependências QEMU, firmware OVMF, `cloud-localds`, SSH e rede de download disponíveis:

```bash
bash tests/qemu/run-vm.sh
```

O teste é demorado e baixa imagens e instaladores reais. Ele é adequado a CI ou máquina descartável, não deve ser executado como procedimento de reparo no servidor em produção. O script de bootstrap da VM não aceita a EULA dos jogos.

## Critérios para liberar uma release

1. Jobs do CI concluídos sem erro; execuções canceladas ou pendentes não contam como aprovação.
2. Log do QEMU inclui os marcadores de sucesso dos cenários executados, sem erros ignorados por `|| true` nos caminhos críticos.
3. Uma falha injetada provoca **falha do teste**, quando esse é o comportamento esperado; a falha OOM controlada deve ser detectada como `oom-kill` e não tratada como sucesso de servidor.
4. Mudanças em instalador, permissões, arquivos systemd, backup ou launcher devem possuir pelo menos um teste negativo e uma contraprova positiva.
5. Teste manual do modpack escolhido antes de considerar o servidor pronto para jogadores.

## Referências

- [CI/CD](../.github/workflows/ci.yml)
- [Guest QEMU](../tests/qemu/guest-test.sh)
- [Runner QEMU](../tests/qemu/run-vm.sh)
- [Instalação e recuperação](tutorial.md)
- [Tuning de memória](hardware-tuning.md)

## Casos adversariais para temporários

`tests/temp-cleanup-test.sh` e o job QEMU exercitam registro privado, permissões 0600/0700, recusa de caminhos não cadastrados, recusa de traversal, troca por link simbólico e isolamento de `TMPDIR` quando o instalador atua como root. O teste de rollback valida a restauração de artefatos existentes. A proteção não garante imunidade a todas as corridas do sistema de arquivos, especialmente se a conta administrativa já estiver comprometida.
