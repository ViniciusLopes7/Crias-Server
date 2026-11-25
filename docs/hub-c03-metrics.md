# C03 — Monitoramento real: contrato e primeiros coletores

Base: C02 32263c6 aprovado integralmente no run 45683390200;
encerramento documentado em f17f24b. Sem merge, instalação, alteração administrativa
ou mudança do ponto de entrada.

## C03.1 — Fundação de telemetria

internal/metrics contém amostras tipadas (valor, unidade, origem, escopo,
timestamp, disponibilidade). Estados distinguem disponível, aguardando,
indisponível, permissão, inválido, obsoleto e estimado. Valor zero não
equivale a observação válida. Dados não disponíveis não serão exibidos
como zero. Perfis de monitoramento são independentes de política
energética: econômico 3x, balanceado 1x (inclusive zero value), detalhado 0,5x. Intervalos de
referência positivos definidos no roadmap; scheduler inicial em C03.2.

Leitura via fs.FS injetável, nomes fixos relativos à raiz proc; limite de
1 MiB por arquivo. Sem subprocessos, sudo, escrita, consulta de rede ou
daemon. Na integração usar os.DirFS("/proc") sem abrir arquivos arbitrários
fornecidos pelo usuário. Limite de bytes não garante timeout de I/O:
cancelamento/coleta assíncrona deverá ser implementado no scheduler.

- CPU agregada: /proc/stat, delta de ticks, idle+iowait, guest excluído
  para não contar duas vezes; primeira amostra/intervalo sem ticks =
  aguardando. Regressão de qualquer contador/inconsistência = inválido e nova
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

## C03.2 — Scheduler e histórico inicial

Engine de sessão com dois workers (CPU e RAM/swap), context cancelável,
timer após cada coleta, sem invocação sobreposta, sem fila de amostras
ou daemon. Mudança de perfil entra no ciclo seguinte; notificação
coalescida em canal de capacidade 1, snapshot por valor sob RWMutex.
A UI ainda não cria o Engine: nenhuma coleta em execução no Hub.
Stop não bloqueia; Done sinaliza término de ambos os workers.
Leitura fs.FS não suporta cancelamento de syscall bloqueada: não criar
goroutine por tentativa de timeout. Teste injeta CPU bloqueada, confirma
independência da RAM e saída após liberar a leitura. Revisar deadlines
e fontes potencialmente lentas antes de incorporar novos coletores.

Freshness: observação disponível/estimada com idade superior a duas
cadências fica obsoleta; timestamp original preservado, sem substituir
por zero. Falhas têm estados próprios. Histórico inicial apenas CPU %
e RAM %, dois rings fixos de 7200 pontos (500 ms por amostra em 60 min).
Descarta ponto fora da retenção e timestamp não crescente; consultas
1/5/15/60 min não retornam amostras expiradas. Min/média/máx somente
dados válidos (média por amostra, não ponderada por tempo), quantidade
de ausências, cobertura First/Last e Gap explícito para falhas, intervalo
entre pontos maior que duas cadências ou cauda obsoleta. Sem interpolação,
sem inventar amostras antes de iniciar; Count=0 não é medição zero.
Não guardar histórico de todos os sensores ainda; revisar memória por
série e agregação em C03.3. Sem persistência.

Testes escritos: retenção, wrap, lacunas, expiração, snapshot obsoleto,
isolamento CPU/RAM, perfis e cancelamento. CI ainda pendente; não
declarar testes executados. Sem mudança do workflow ou do binário
em execução. M2 aberto.
