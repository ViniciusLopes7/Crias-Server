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

## C03.4a.1 — Correção de formatação

Run 45700166928, commit 49ee953, job Hub 139507902463: o gate gofmt
identificou exclusivamente internal/metrics/hardware_test.go, expressão
Add(7*time.Second). Ajuste para Add(7 * time.Second), exatamente conforme
o diff do CI. Vet, race, build, PTY e scanner não chegaram a executar
neste job. Nenhuma alteração funcional, nem flexibilização do gate.
Correção preparada separadamente para preservar o QEMU em andamento;
integração por fast-forward somente após o run anterior terminar.
C03.4a ainda aguarda validação. Não ligar Engine à UI antes do gate.

## C03.4a.2 — Correção de assinatura do agendador

Run 45701665949 (2e3a27e): 14 jobs aprovados, inclusive QEMU;
Hub 139513070584 passou por gofmt, mas vet identificou chamada de loop
no worker de RAM sem o parâmetro base time.Duration. Corrigir para
fastCadence (1 s no perfil Balanceado), igual ao worker de CPU.
Revisão das três chamadas e.loop em engine.go/hardware.go: CPU e RAM
passam fastCadence, grupos adicionais passam sua cadência base.
Não alterar a assinatura nem desativar vet. Race/build/PTy/scanner
não executados nesse run, novo CI obrigatório. Não houve validação
local neste incremento. Integração visual permanece bloqueada.

## C03.4b.1 — Primeira integração visual (candidato)

Run 45703082662 (a1a7135): 15 jobs aprovados, incluindo Hub e QEMU.
Novo modo experimental explícito crias-tui-next --telemetry inicia
NewHostEngine com /proc, /sys e statfs de /. Sem argumento mantém
C02 estático para comparabilidade dos benchmarks. Help/version e
recusa de root/non-TTY precedem qualquer coleta. Nenhuma alteração
no instalador, default distribuído ou comandos administrativos.
Bubble Tea recebe notificações coalescidas via um Cmd por vez, com
wake de freshness em 2 s caso todos os grupos bloqueiem; Snapshot
fora da View, sem efeitos no render. Context/Stop no encerramento,
sem bloquear restauração por syscall de sensor. Header CPU/RAM host,
memória/swap/espaço na visão geral e inventário resumido em Hardware.
Sem inventar zeros; estado de grupo precede dados de inventário.
Detalhes dos sensores, serviços, perfis interativos, histórico visual,
alertas, descoberta adaptativa e benchmarks de coleta real pendentes.
Modo estático preserva 30 startups/60 transições anteriores. Novo PTY
smoke opt-in verifica RAM em MiB, navegação e restauração, não precisão
física ou carga. Teste de render com snapshots e falhas/ASCII/bounds.
Testes escritos, CI novo obrigatório. M2 aberto.

## C03.4b.2 — Detalhes, perfis e histórico (candidato)

CI 45704390058 (5c3f02a): 15 jobs aprovados, inclusive Hub e QEMU.
Hardware Enter abre páginas de seis linhas; ↑/↓ percorre o inventário
inteiro, Esc volta. Identidades, clocks hardware/driver, limites e
governor, sensores/RPM, domínios de potência, bateria/limites/fontes,
taxas por rede/disco. Estados de grupo impedem mostrar dados obsoletos
como atuais; ~ distingue estimativas. Total do host indisponível.
Sanitização ASCII adicional dos labels na apresentação. Sem escrita.
Configurações P alterna Balanceado/Econômico/Detalhado apenas na sessão,
sem política de energia. Visão geral H alterna 1/5/15/60 min de histórico
CPU/RAM, min/média/máx, contagem e lacunas, sem inventar valores. Atalhos
locais bloqueados em overlays, contexto e terminais compactos. Estado
estático C02 preservado. Testes de paginação, limites, estados, perfis
e histórico escritos; CI pendente. Ainda faltam testes PTY dos novos
atalhos, otimização de inventário, alertas, serviços, header térmico/
potência e benchmark real. M2 aberto. Nenhuma alteração de hardware.

Contra-auditoria: hint Enter antes do inventário no mínimo 60x20;
wrap de campos longos antes da paginação com margem para ASCII, labels
limitados com reticências explícitas; clamp de página apenas em detalhe
ativo (evitar formatar inventário durante navegação de outras abas).
Testes adicionais de quebra de linha e isolamento dos atalhos.

## C03.4b.2a — Correção de import não utilizado

Run 45756255555 (814c57a): 14 jobs aprovados, incluindo Arch/QEMU.
Hub 139695457235 passou por gofmt, mas vet bloqueou import de metrics
não utilizado em cmd/crias-tui-next/monitor.go. Removido exclusivamente
esse import (tipos de monitoramento são inferidos a partir do modelo).
Race/build/PTY/scanner não executados nesse run. Revisão textual das
importações dos novos arquivos; compilação local do módulo completo
indisponível (ambiente Go 1.23.2, sem dependências do módulo Go 1.27.4).
Novo CI obrigatório. Sem alterar comportamento, testes ou gates.

### C03.4b.3 — indicadores de hardware no header

O CI 45757244103 de 903d6ef concluiu com 15 jobs aprovados (Hub, race/PTY, QEMU inclusive), release ignorado. O cabeçalho em tamanho integral recebe duas linhas de telemetria: maior temperatura CPU observada dentre sensores conhecidos da família selecionada (Tdie, pacote coretemp ou Tctl explicitamente distinguido), percentual de uma única bateria não declarada ausente e potência instantânea ou média de um único domínio package powercap. Não soma domínios, não agrega baterias e não apresenta potência do pacote como consumo total do host. Estado de grupo indisponível/obsoleto bloqueia a apresentação dos valores. Compacto e overlays mantêm apresentação anterior para preservar navegação. Sem escrita ou nova coleta; testes de escopo, dados obsoletos, múltiplos dispositivos e layout adicionados. Novo CI e validação física pendentes.

### C03.4b.4 — estado dos serviços

CI 45765403152 de 8feec09: 15 jobs aprovados, release ignorado. O modo opt-in --telemetry ganha um worker independente de serviços, com cadência base de 15 s adaptada ao perfil; consulta sequencial de minecraft.service, terraria.service, sshd.service e tailscaled.service. Usa exclusivamente /usr/bin/systemctl show no manager do sistema, sem shell, sudo, pager, entrada livre ou verbos de escrita. Timeout de 1 s por consulta, WaitDelay de 200 ms, saída limitada a 4096 bytes e descarte de stderr. Erro genérico de execução é indisponível (não inferir ausência ou permissão a partir de mensagens); somente LoadState not-found recebido com sucesso indica ausência. LoadState, ActiveState e SubState distintos; serviço ativo não prova disponibilidade do jogo/rede. Snapshot copiado, freshness por grupo, fixtures de parser/limite/cancelamento/render. Nenhum daemon novo, dependência ou alteração Bash. Inventário inicial fixo, sem descoberta de serviços extras; validação real systemd não-root em Arch e CI do novo candidato pendentes.

### C03.4b.5 — alertas térmicos por sensor

CI 45766606887 de 401e4ef: 15 jobs aprovados, release ignorado. O worker hwmon existente lê tempN_max/crit e respectivas histereses quando expostas por drivers Celsius reconhecidos; avalia cada canal no próprio escopo (inclusive Tctl sem converter para Tdie). Histerese nativa absoluta conforme ABI; quando ausente/inválida, margem de retorno de 3 °C é política visual anti-oscilação, não limite de segurança. Entrada imediata no limite, crítico tem prioridade, retorno pelo limiar de recuperação. Limites não positivos ou inválidos não geram alerta; max inconsistente acima de crit é descartado, preservando crit. Cache por ID/driver/label e bandas, substituído por amostra, sem fila ou notificações repetidas; reinicia após falha, ausência, mudança de bandas ou lacuna >12 s. Identidade hwmon não é garantia de identidade física persistente após hotplug. Título mostra contagem por canal avaliado, não por dispositivo nem saúde global; detalhes no Hardware. Não avalia thermal zones sem limites, não aciona fans, shutdown, throttling nem hardware. Testes de fixtures e render escritos; CI novo e homologação física pendentes.

Referências: https://docs.kernel.org/hwmon/sysfs-interface.html e https://docs.kernel.org/hwmon/k10temp.html.

### C03.4b.6 — inventário de capacidades de leitura

CI 45769766505 de a295d2b: 15 jobs aprovados, release ignorado. Inventário derivado de snapshots, sem novas sondagens, processos, cadências ou I/O. Doze categorias distinguem canais observados, estimados, aguardando, sem permissão, inválidos, obsoletos e indisponíveis; grupos obsoletos ou inacessíveis não apresentam contagens antigas. Zero RPM é leitura válida; bateria declaradamente ausente não conta. Grupo disponível sem canais é nenhum canal identificado, não prova ausência física. Potência por domínio escolhe leitura instantânea válida ou média; não representa consumo do host. Rede/disco indicam apenas taxa RX/leitura nesta matriz inicial, detalhes mantêm ambas direções. Limites de carga são somente leitura; nenhum atributo comprova permissão ou segurança de escrita. Todos os controles continuam bloqueados. Matriz no início dos detalhes paginados, aviso na visão Hardware; testes de estado misto, ausência, estimativas, obsolescência e alcance da paginação escritos. CI novo, PTY ampliado, teste systemd real e benchmark pendentes.

### C03.5a — validação systemd em Arch

O job Hub de dba2f56 (run 45770645206, job 139742181545) foi aprovado; QEMU ainda em execução no momento da preparação. Branch temporária para não cancelar o run anterior. CI compila o pacote metrics como executável de testes Linux amd64 com a mesma versão Go fixada, transfere por SSH e compara SHA-256. O guest já possui fixture OpenSSH e Minecraft (JVM inofensiva), reaproveitada sem mudanças de serviço adicionais: roda o coletor Go real como ci não-root antes e depois do stop existente. Valida loaded/active/running e loaded/inactive/dead no Minecraft, sshd ativo em ambas; todas as quatro unidades registradas em log. Sem sudo no coletor, sem instalar Go na VM, sem novo job/artifact. Execução local do teste é skip explícito sem variável; CI passa o binário obrigatoriamente. A validação ainda não foi executada no candidato; QEMU não comprova SSH interativo físico ou disponibilidade de jogo.

### C03.5b — PTY com telemetria

Amplia o harness existente, sem dependência nova: P alterna perfil, ajuda suspende P, H altera janela e a navegação confirma o texto em nova renderização, Enter abre capacidades, seta navega para página 2 e resize compacto/full confirma a página preservada; Esc e aba Sistema, Q e restauração de termios/alternate screen. O marcador de dígito isolado apenas sincroniza a leitura; a confirmação é o título completo após resize. Teste preparado, execução CI pendente. Não substitui teste SSH real nem benchmark com coleta ativa.

### C03.5c — reparo do harness QEMU

Run 45771496141: Hub 139744944467 aprovado, inclusive PTY ampliado; 13 jobs aprovados, ShellCheck e QEMU falharam. Logs mostram SC1089 na linha 704, warning de Go "no tests to run" e manager recusando recalibração com Minecraft ativo. Causa: a edição anterior interpolou a sequência dólar/apóstrofo do regex como sufixo de substituição JavaScript, duplicando trechos e engolindo comandos legados. Reconstrução a partir do guest-test.sh de dba2f56, com três inserções verificadas por reversão exata ao original. Helper único exige marcador de PASS do teste Go real em cada fase; código zero sem teste executado ou skip não basta. Nenhum ajuste de serviço/manager ou redução de gate; stop e verificação legados restaurados. Novo CI obrigatório, incluindo QEMU; benchmark ainda condicionado.

### C03.5d — estado terminal real do serviço

Run 45772262230: 14 jobs aprovados, ShellCheck restaurado; QEMU 139747451220 executou e aprovou TestRealSystemdReadOnly na fase ativa (Minecraft/sshd loaded/active/running, Terraria/Tailscale not-found/inactive/dead). Após stop existente, o coletor observou loaded/failed/failed; teste esperava inactive/dead. O estado failed é permitido pelo manager legado para serviço parado, mas não equivale a inactive ou shutdown saudável. O harness passa a verificar independentemente ActiveState/SubState via systemctl do sistema, aceita somente pares terminais inactive/dead ou failed/failed e exige MainPID=0; registra Result/ExecMainCode/ExecMainStatus e exige correspondência exata do coletor sem root. Não normaliza falha, não usa reset-failed nem altera a unit/launcher/manager. A causa específica da falha da JVM sintética não foi demonstrada pelo log anterior; diagnósticos adicionais ficam no próximo CI. Gate nominal de execução mantido. Benchmark condicionado à aprovação integral.

### C03.6a — protocolo comparativo de telemetria

Candidato preparado enquanto o QEMU do CI 45773850927 ainda executava; integração condicionada à aprovação integral. Harness C01 preservado; opção --compare-telemetry compara estático, balanceado, econômico e detalhado, selecionando perfil pelos atalhos reais. Cinco sessões por modo, ordem rotativa, duas navegações por sessão; primeira sessão de cada modo tem 15 s de aquecimento e 60 s de observação idle (cadência systemd econômica de 45 s). Coleta RSS/PSS do processo principal a cada segundo, CPU própria e filhos aguardados em /proc/stat do processo, volume PTY com buffer limitado, latência de marcadores e primeira RAM observada. Startup dos perfis não-padrão é do modo balanceado inicial, não tempo de boot do perfil selecionado; PSS indisponível fica nulo, filhos vivos nos limites não contabilizados. Um idle por modo, sem carga de jogo, hardware físico ou SSH; sem inferência de vazamento de memória ou gate absoluto. CI existente executa comparação somente no PR C03 ou workflow_dispatch, sem artefato adicional. JSON no log com SHA-256, kernel, arquitetura, CPUs e ticks; sem substituir baseline C01 ou M2 físico. Testes do novo harness ainda não executados no runner.

### C03.6b — contra-auditoria do benchmark antes da integração

Identificada fragilidade no marcador de navegação do modo estático: a frase Recursos ainda não conectados é compartilhada entre abas e pode não ser emitida pelo renderer incremental. Substituída por conteúdo específico da aba (Minecraft e Terraria; retorno Painel inicial e estado do host ou Memória do host). O harness mede chegada do marcador e não conclusão do frame. Drenagem limitada de bytes pendentes antes da janela, CPU combinada própria + filhos aguardados (não CPU integral da árvore), taxa de bytes PTY e contagem de amostras de memória adicionadas. Sem mudanças no runtime ou custo adicional de jobs. Novo harness continua não executado; gate anterior permanece obrigatório.

### C03.6c — correção do marcador PTY e gate systemd

Run 45773850927 cancelado pelo GitHub. Run 45777484186: 14 jobs aprovados, QEMU 139764679592 aprovado integralmente; TestRealSystemdReadOnly PASS nas duas fases. Após stop da JVM sintética: MainPID=0, Result=exit-code, ExecMainCode=1, ExecMainStatus=130 (compatível com SIGINT), estado failed/failed preservado. Hub 139764679800 aprovou lifecycle, race e PTY ampliado; benchmark falhou por esperar palavra Detalhado, enquanto o renderer incremental emitiu Detalhad (o final já estava presente) e a cadência 500ms | Sensores: 1s. Marcador corrigido para a cadência efetivamente observada. Idle prolongado movido para a última repetição, de forma que sessões curtas de todos os modos antecedam o custo de medição; relatório recupera idle da última sessão. Sem diminuir amostras, alterar produção ou desativar gates. Scanner não executado nesse run por falha anterior; novo CI obrigatório. Ainda não há JSON completo do benchmark ativo.
