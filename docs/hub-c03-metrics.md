# C03 — Monitoramento real: contrato e primeiros coletores

Base: candidato C02 32263c6, job Hub aprovado; CI integral ainda não
confirmado ao preparar esta branch. Não abrir PR/rodar CI adicional
antes de confirmar C02. Sem merge, instalação, alteração administrativa
ou mudança do ponto de entrada.

## C03.1 — Fundação de telemetria

internal/metrics contém amostras tipadas (valor, unidade, origem, escopo,
timestamp, disponibilidade). Estados distinguem disponível, aguardando,
indisponível, permissão, inválido, obsoleto e estimado. Valor zero não
equivale a observação válida. Dados não disponíveis não serão exibidos
como zero. Perfis de monitoramento são independentes de política
energética: econômico 3x, balanceado 1x, detalhado 0,5x. Intervalos de
referência positivos definidos no roadmap; scheduler ainda não existe.

Leitura via fs.FS injetável, nomes fixos relativos à raiz proc; limite de
1 MiB por arquivo. Sem subprocessos, sudo, escrita, consulta de rede ou
daemon. Na integração usar os.DirFS("/proc") sem abrir arquivos arbitrários
fornecidos pelo usuário. Limite de bytes não garante timeout de I/O:
cancelamento/coleta assíncrona deverá ser implementado no scheduler.

- CPU agregada: /proc/stat, delta de ticks, idle+iowait, guest excluído
  para não contar duas vezes; primeira amostra/intervalo sem ticks =
  aguardando. Regressão/inconsistência de contadores = inválido e nova
  referência; falha de leitura invalida baseline, sem atravessar lacuna.
  Escopo CPU host agregado, não CPU de processo/cgroup.
- Memória: /proc/meminfo, kB do kernel convertido em bytes, uso =
  MemTotal - MemAvailable, sem estimativa a partir de MemFree. Swap
  total e usado separados; zero swap válido quando informado. Ausência
  de MemAvailable mantém uso indisponível. Validar unidades, limites,
  duplicatas e overflow; nunca fabricar percentual.
- Escopo host, não heap JVM ou orçamento cgroup. Revisar precisão e
  semântica dos contadores com fixtures e execução Arch real.
- Testes de parser e deltas, estados de ausência/permissão/invalidade,
  reset, overflow, zero swap e limite de leitura. Código escrito;
  testes ainda não executados.

## Próximas etapas

C03.2: scheduler cancelável, cadências independentes, sem sobreposição
por coletor, cache de última leitura com freshness, buffers de até 60
minutos e janelas 1/5/15/60 com lacunas. C03.3: CPU clock, térmica/RPM,
energia com escopo, bateria, armazenamento e rede, testes fixture.
C03.4: integrar dashboard e header com fontes reais, perfis, estados e
histórico, alertas fundamentados. C03.5: PTY/QEMU Arch, desempenho,
contraprovas e gate M2. Ações de escrita continuam fora de escopo.
Gates físicos e SSH, carga de jogos e equivalência administrativa
preservados. Não declarar M2 até evidências.
