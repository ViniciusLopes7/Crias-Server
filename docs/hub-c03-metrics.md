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

## C03.2a — Correção do gate de formatação

Run 45685769606, aaf4f08: 14 jobs aprovados (QEMU inclusive), job Hub
139457866749 falhou após go mod verify e antes de vet/race. Reprodução
local com Go 1.23.2: seis blobs de internal/metrics reconstruídos e
comparados por SHA Git com o repositório, todos idênticos. gofmt -d
identificou exclusivamente bytes(swap-free) em proc.go, corrigido para
bytes(swap - free). Depois da correção, pacote isolado sem dependências
externas: GO111MODULE=off go test -race -count=10 -timeout=60s -v,
8 testes por repetição, 80 execuções aprovadas. Não equivale ao CI
Go 1.27.4 nem ao módulo completo. Diagnóstico de gofmt no job Hub
passa a mostrar arquivos/diff antes de falhar, sem relaxar o gate.
Novo CI obrigatório antes de C03.3. Nenhuma mudança funcional.

## C03.3a — Frequência, temperatura e RPM (candidato)

CI 45688525883, 8852bd9, 15 jobs aprovados; Hub 139467462725
confirmou pacote metrics com race, PTY e govulncheck sem alertas.
Fundação C03.1/2 validada no CI. Engine ainda não usado pelo executável.

Fontes de referência:
- https://docs.kernel.org/admin-guide/pm/cpufreq.html
- https://docs.kernel.org/hwmon/sysfs-interface.html
- https://docs.kernel.org/hwmon/dell-smm-hwmon.html
- https://docs.kernel.org/gpu/amdgpu/thermal.html

Leitores sysfs via fs.FS, raiz futura os.DirFS("/sys"), somente caminhos
de inventário com prefixos e índices numéricos. Leitura limitada a 4096
bytes por atributo, 512 entradas por diretório e 512 sensores por leitura.
Diretórios sysfs podem ser links do kernel; não exigir IsDir.
Ausência/permissão/valor inválido explícitos. Inventário limitado não
é inventário completo se exceder limite. Labels ASCII imprimíveis,
fallback ao identificador; não passar escapes ao terminal.

CPUFreq por policy, em MHz. Observação cpuinfo_cur_freq, valor do driver
scaling_cur_freq marcado Estimated (não substitui hardware), limites
configurados min/max e governor separados. Rejeitar limites invertidos.
Limites numéricos de sanidade não são parâmetros de tuning.
Hwmon: temperaturas apenas para drivers com unidade conhecida
(coretemp, k10temp, acpitz, amdgpu, nvme, dell_smm), sem inferir temperatura
CPU a partir de Tctl ou GPU e sem somar sensores. Outros drivers não
interpretados até verificar unidade (alguns temp inputs são tensão).
RPM zero é válido; fault indicado invalida observação. Sem controle,
PWM ou escrita. Identificadores hwmonX são da sessão, não persistentes.
Temperatura genérica thermal_zone, mais drivers, histerese e seleção do
sensor relevante no header ainda pendentes. Sem alertas térmicos arbitrários.

Fixtures cobrem fontes de clock, ausência, limites invertidos,
conversões, RPM zero, falhas, driver desconhecido, labels inseguros,
permissões e limites de leitura/inventário. Testes novos aguardam CI.
Sem ligar coletores ao scheduler nesta alteração. Inventário/cadências,
energia, bateria, armazenamento, rede, integração UI e M2 pendentes.

## C03.3b — Potência, energia, bateria e alimentação (candidato)

C03.3a: CI 45690001853, 6d9e711, integralmente aprovado (15 jobs).
Referências Linux:
- https://docs.kernel.org/power/power_supply_class.html
- https://docs.kernel.org/power/powercap/powercap.html
- https://docs.kernel.org/next/power/powercap/powercap.html

power_supply: inventário por tipo, presença, status, capacidade em %,
energia Wh e carga Ah mantidas separadas, tensão V, corrente A e potência W.
Saúde estimada a partir de full/design da mesma unidade; não limitar
artificialmente a 100%. Se energia indisponível, tentar razão de carga,
sem misturar unidades e sem esconder erro de permissão/valor inválido.
Potência nativa com sinal preservado, status separado. Na ausência de
power_now e com V/I válidos, estimar magnitude V*abs(I), não direção
nem consumo total. Bateria explicitamente ausente não publica os demais
dados. Fontes externas por dispositivo e online 0/1, sem inferir conexão
quando não há leitura. Limites de carga somente leitura, invertidos
invalidam o par. Nenhum controle de carga implementado.

powercap: entradas planas de /sys/class/powercap, domínios identificados
individualmente; contador energy_uj e range convertidos em J, power_uw
em W quando disponível. Potência média = delta de energia / tempo real
decorrido (não potência instantânea). Primeira leitura aguardando;
regressão de contador, mudança de nome/range ou tempo não positivo
invalidam o intervalo. Wrap e reset são ambíguos: descartar esse
intervalo e retomar baseline, não presumir um wrap. Lacuna >12 s
obsoleta (duas vezes a maior cadência de referência de energia, 6 s).
Não acumular energia indefinidamente ou somar zonas pai/filho.
Leitura de contador não é energia de toda a sessão nem do servidor.
Potência total do host permanece indisponível sem fonte apropriada.
Inventários não planos e outras fontes (hwmon power, thermal_zone)
ainda exigem expansão validada. Mesmos limites de sysfs e sanitização.

Três testes de fixtures para conversões, sinais, saúde, ausência,
limites, falhas, delta, regressão e lacunas. Código ainda não ligado
ao scheduler/UI; CI novo necessário. Nenhuma escrita em hardware.

## C03.3c — Rede, armazenamento e thermal_zone (candidato)

CI 45691302343 (6f52f33): 15 jobs aprovados, metrics/race e scanner sem alertas.
Fontes: https://docs.kernel.org/networking/statistics.html ,
https://docs.kernel.org/admin-guide/iostats.html ,
https://docs.kernel.org/6.17/block/stat.html ,
https://docs.kernel.org/driver-api/thermal/sysfs-api.html .
Rede por interface /proc/net/dev (namespace atual), disco /proc/diskstats
por major:minor/nome, setores de 512 bytes. Contadores uint64, taxas B/s
por delta/tempo real, primeira leitura aguardando, regressão inválida,
lacuna >12 s obsoleta, falha limpa baseline. Não somar túneis, partições,
RAID ou camadas; nome/ID reutilizado não comprova continuidade. Instâncias
separadas do coletor por fonte; limite 512 entradas e 1 MiB por proc.
Espaço statfs de filesystem conhecido, blocos usados e disponíveis ao
usuário, percentual usado/(usado+disponível); sem varredura de mounts.
Inicialmente / na integração; statfs pode bloquear em kernel.
Thermal zones em °C, sem agregar hwmon nem presumir sensor CPU.
Quatro testes escritos, CI pendente. Nenhum coletor conectado ao engine,
nenhuma escrita administrativa ou nova dependência. Faltam inventário
completo/estável, cadências, UI, alertas fundamentados e homologação M2.

## C03.4a — Integração ao Engine (candidato)

CI 45694629526 (2634a3b) integralmente aprovado: 15 jobs, QEMU incluso.
NewHostEngine preserva NewEngine CPU/RAM para fixtures e habilita oito
grupos adicionais: clocks 1 s; hwmon, thermal, powercap, rede e disco
2 s; bateria 10 s; espaço 30 s quando callback fornecido. Perfis aplicam
multiplicadores já aprovados, uma leitura por worker, timer após leitura,
cancelamento de sessão, canal coalescido. Máximo dez workers de coleta
e um de encerramento. Sem subprocessos ou nova dependência.
Snapshot copia slices antes de devolver ao consumidor; grupos têm
State, At e Interval, com freshness em duas cadências. Estado de grupo
obsoleto impede interpretar valores antigos como atuais; estados de
amostras continuam separados. Histórico ainda restrito a CPU/RAM.
Inventário ainda é redescoberto pelos leitores em cada coleta; separar
cache/inventário e adaptação por visibilidade antes da homologação.
Espaço usa callback injetável de filesystem conhecido, nunca entrada
do usuário. Stop não interrompe syscall bloqueada; preservar isolamento.
Testes escritos de oito grupos, cadências, cópia de snapshots, freshness,
permissões e bloqueio de espaço. Validação CI pendente. A UI ainda não
instancia NewHostEngine, portanto não há coleta real ao abrir o Hub.
Serviços, alertas, seleção de sensores, UI e M2 continuam pendentes.
