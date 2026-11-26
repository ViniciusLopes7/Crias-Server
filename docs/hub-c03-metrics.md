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

### C03.6 — evidência observacional e avaliação das metas

CI [45778799941](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45778799941), b6c3547: 15 jobs aprovados, release ignorada; Hub 139768913729 e QEMU 139768913588 aprovados, govulncheck sem vulnerabilidades encontradas. Dados em [evidence/hub-c03/pty-b6c3547.json](evidence/hub-c03/pty-b6c3547.json), extraídos das duas linhas JSON do log; contagens, medianas, p95 nearest-rank e máximos de startup/navegação/primeira RAM e RSS estático recalculados. Séries brutas de memória idle não foram retidas pelo harness, portanto seus resumos não são recalculáveis. Binário 6123791 B (5,84 MiB), SHA-256 a585ff793ad7da67c02e01fb539a00f7a4bb111c67e8d0d7b950637452f8f3e2; kernel 6.8.0-1070-azure, x86_64, 4 CPUs, 100 ticks/s. Mesmo binário nos quatro modos; 5 sessões/modo, 10 transições/modo, 15s aquecimento e 60s idle na última sessão.

| Modo | Startup mediana (ms) | Navegação p95 (ms) | RSS mediana (KiB) | PSS mediana (KiB) | CPU própria + filhos aguardados (% 1 núcleo) | PTY B/s |
|---|---:|---:|---:|---:|---:|---:|
| Estático | 23,167 | 17,317 | 6016 | 6568 | 0,000 | 0,00 |
| Econômico | 23,000 | 17,218 | 9344 | 9992 | 0,233 | 31,67 |
| Balanceado | 22,697 | 17,847 | 9984 | 10332 | 0,650 | 93,08 |
| Detalhado | 23,229 | 17,294 | 10112 | 10584 | 1,250 | 140,17 |

ADR: RSS <=15 MiB desejável/25 referência; startup <=150/300 ms; navegação p95 <=20/50 ms; binário <=10/15 MiB: observações atendem desejáveis. CPU <=0,2/0,5%: estático abaixo, econômico atende referência não desejável, balanceado e detalhado excedem referência. CPU principal 0/0,217/0,600/1,133%, filhos aguardados 0/0,017/0,050/0,117%. PSS/RSS são aproximações por interfaces diferentes (stat e smaps_rollup); valores PSS maiores que RSS stat não representam contradição física, mas pedem comparação com RSS do mesmo smaps_rollup. RSS delta 0/1664/1124/380 KiB (estático/econômico/balanceado/detalhado): não demonstra leak nem estabilidade longa. Startup de perfis ativos ocorre antes de selecioná-los; não é boot em perfil diferenciado. Marcadores PTY não significam frame completo. Um idle/modo em runner compartilhado, CPU filhos aguardados não é toda árvore. Zero ticks não prova custo zero. Sem jogos, SSH ou físico. Não elevar limites nem homologar M2: investigar custo de render/refresh/coleta, validar otimização em mesma metodologia e preservar cadências/freshness. Gate de comparação física e C10 continuam abertos.

### C03.7a — coalescência de notificações da interface

Repetição no job Hub 140099110618 (run 45874818218, 40974ad): CPU combinada estático/econômico/balanceado/detalhado 0/0,267/0,700/1,350%; RSS medianas 6272/9152/10112/10232 KiB. Job Hub aprovado; QEMU ainda em execução na consulta. Reproduz o excesso CPU dos dois perfis em runner compartilhado; não identifica causalidade.

Auditoria: Engine.Changed tem buffer 1, mas a UI reagia imediatamente a cada despertar com clone de snapshot completo, histórico e render. Candidato agrupa notificações por janela fixa de 50ms após o primeiro sinal (10% da cadência de coleta mais rápida de 500ms), drena no máximo um sinal pendente e lê snapshot depois; eventos posteriores permanecem no canal. Janela não se estende com novos sinais, mantém wake de freshness 2s quando não há eventos e cancelamento por contexto/Done. Teclas e resize não passam pelo agrupamento. Coletores, histórico, alertas, fontes, perfis, permissão, consultas systemd e intervalos de coleta inalterados. Custo potencial: até 50ms adicionais de propagação visual intencional (mais scheduling), inclusive alertas passivos; sem mudança de instante/precisão da amostra. Helper isolado com testes de agrupamento, sinal posterior, freshness e shutdown; equivalente executado localmente com Go 1.23.2, race, 10 repetições; integração Go 1.27.4/PTy/QEMU/benchmark pendente. Ganho CPU é hipótese, medir antes de homologar. Sem redução de meta ou gate.

### C03.7a — resultado e decisão

CI 45875750590 aprovado integralmente (15 jobs, release ignorada), Hub 140102268988 e QEMU 140102268681; scanner sem vulnerabilidades reportadas. Relatórios originais das duas execuções preservados em [40974ad](evidence/hub-c03/pty-40974ad.json) e [18bd5b4](evidence/hub-c03/pty-18bd5b4.json), mesma metodologia, kernel e 4 CPUs; cada run usou seu próprio binário e runner. CPU própria + filhos aguardados (%) antes/ depois: econômico 0,267/0,167 (-37,5%), balanceado 0,700/0,450 (-35,7%), detalhado 1,350/1,017 (-24,7%). Estático zero ticks. RSS pós alteração 6016/9216/9600/10212 KiB (estático/econômico/balanceado/detalhado), navegação p95 17,344/17,292/17,277/17,257ms. Primeira RAM mediana ~72ms (antes ~23ms na primeira evidência), aumento esperado pela janela de 50ms. Mantemos coalescência: referência CPU 0,5% atingida pelo balanceado nesta amostra, econômico também atende desejável 0,2%; detalhado ainda excede. Sem alterar metas; não é comparação pareada no mesmo runner nem comprovação de causalidade ou estabilidade longa. Próximo passo: reduzir trabalho de histórico em sessões longas com teste de equivalência e microbenchmark. Não homologar M2.

### C03.7b — busca da janela no histórico

O ring retém até 7200 pontos por série e rejeita timestamps não crescentes. A implementação anterior percorria toda a retenção em cada consulta, mesmo para a janela de 1 min. Busca binária no índice lógico encontra o primeiro timestamp estritamente maior que o cutoff; varredura cronológica termina no primeiro timestamp futuro. Preserva janela (cutoff, now], ordem e aritmética da média, gaps, estados inválidos e retenção; sem cache nem alocação adicional na consulta. Complexidade de O(n) para O(log n + k), onde k é o número de pontos dentro da janela. Benefício esperado em sessão longa/janela curta; não atribuir a esta mudança melhoria no idle de 60s sem medição. Testes com referência linear original, ring vazio/parcial/cheio/rotacionado, intervalos mistos, ausentes, fronteiras e janela inválida. Microbenchmark pareado de janela 1 min e 1 h, três repetições de 200ms no job Hub existente, sem artefato novo. Testes e benchmark ainda não executados no candidato; CI integral e comparação de CPU pendentes. Metas, cadências e gates preservados.

### C03.7b — resultado da busca no histórico

CI 45881792302 (17a30cd), 15 jobs aprovados; Hub 140122659476, QEMU 140122659071 e scanner sem vulnerabilidades reportadas. Evidência [pty-17a30cd.json](evidence/hub-c03/pty-17a30cd.json) preserva relatórios e três amostras por variante do microbenchmark. No mesmo runner, janela 1min: mediana linear 27613 ns/op, seek 1715 ns/op (16,10x, -93,79%); 1h: 111696 vs 101713 ns/op (-8,94%). Todos 0 B/op e 0 allocs/op. Teste de equivalência aprovado. Mantemos a mudança. CPU própria + filhos aguardados (% de um núcleo), estático/econômico/balanceado/detalhado: 0/0,183/0,467/0,867; RSS medianas 6016/9216/9640/10284 KiB; p95 navegação 17,164/17,937/17,219/17,239ms. Segunda observação balanceado dentro de 0,5% após coalescência; detalhado ainda excede. Idle de 60s não isola o ganho da busca binária em histórico cheio. Sem homologação física ou M2.

### C03.7c — caminho rápido de largura ASCII

Auditoria de Render: fit aplicava cálculo geral de largura terminal mesmo a textos ASCII imprimíveis, inclusive no modo ASCII/NO_COLOR do benchmark, e truncamento percorria prefixos. Candidato retorna prefixo por bytes apenas quando todos os bytes são 32..126 (uma coluna por byte); Unicode, caracteres de controle, sequências ANSI e UTF-8 inválido continuam exatamente no caminho anterior. Sem mudança de estilos, dimensões, fontes, precisão, coleta, cadências ou segurança. Teste compara fit com referência anterior para toda faixa ASCII imprimível, texto longo, Unicode, combinantes, ANSI, controles e UTF-8 inválido em dez larguras; microbenchmark pareado para ASCII que cabe, truncado e Unicode, três repetições de 200ms no job existente. Ganho esperado de render, não comprovado até CI; não atribuir mudança de CPU sem medir e não usar resultado ASCII para inferir ganho idêntico em terminal Unicode/colorido. M2 permanece aberto.

### C03.7c — resultado e decisão

CI 45885005990 (c6243d3), 15 jobs aprovados; Hub 140133409832, QEMU 140133409635, scanner sem vulnerabilidades reportadas. Evidência [pty-c6243d3.json](evidence/hub-c03/pty-c6243d3.json) contém relatórios e 3 amostras por variante dos dois microbenchmarks. fit ASCII sem truncamento: mediana 598,6→17,23 ns/op (34,7x); ASCII truncado: 35924→131,7 ns/op (272,8x), 2272→0 B/op e 64→0 allocs/op; Unicode: 485,2→485,4 ns/op, 0 alocações. Equivalência e demais testes aprovados; manter caminho rápido. CPU combinada estático/econômico/balanceado/detalhado 0/0,183/0,467/0,883%; RSS 6016/8960/9904/10096 KiB; navegação p95 17,285/17,221/17,535/17,242 ms. Não há melhora global de CPU demonstrada em relação ao run anterior; microbenchmark confirma ganho localizado, não economia equivalente no processo inteiro. Terceira observação balanceado dentro de 0,5% após coalescência; detalhado ainda acima. Não alterar metas nem frequência de coleta apenas para atender um runner. M2 e validações físicas permanecem abertos.

### C03.8a — contra-auditoria do inventário de potência

Encontrada perda de diagnóstico na classificação por domínio: quando a potência instantânea não era válida, a média era selecionada mesmo se indisponível, ocultando permissão negada, dado inválido ou obsoleto. Nova seleção mantém um item de evidência por domínio: medição válida (instantânea preferida em empate), estimativa válida, inválido, permissão negada, obsoleto, aguardando, indisponível. Unidade incorreta e valor não finito são inválidos. Essa prioridade é uma política conservadora da matriz resumida, não uma fusão de medições; o detalhe continua expondo as duas fontes separadamente. Não modifica coletores, frequência, fontes, estados publicados ou permissões. Testes cobrem pares de estados, unidade/valor incorreto, fallback válido e grupo obsoleto. Candidato não executado localmente; novo CI obrigatório. Restante da contra-auditoria, perfil detalhado acima da referência de CPU e gates M2/físico/SSH continuam abertos.

### C03.8a — validação

CI 45887359522 (0f0bebd), 15 jobs aprovados, release ignorada; Hub 140141282688, QEMU 140141283174, scanner sem vulnerabilidades reportadas. Evidência [pty-0f0bebd.json](evidence/hub-c03/pty-0f0bebd.json) preserva os dois relatórios originais. CPU combinada estático/econômico/balanceado/detalhado 0/0,183/0,483/0,850%; RSS mediana 6144/8960/9536/10032 KiB; navegação p95 17,249/17,225/17,260/17,119 ms. Quarta observação balanceado abaixo de 0,5% após coalescência, ainda sem homologação física. Detalhado excede referência. Preservar cadências e metas; não inferir ganho de CPU pela correção diagnóstica.

### C03.8b — contra-auditoria de continuidade temporal da CPU

CPU agregada calculava delta de ticks sem validar o intervalo entre amostras; depois de suspensão/atraso longo poderia publicar uma média de intervalo antigo como observação atual. Candidato registra timestamp da baseline, rejeita intervalo <=0 como inválido e >12s como obsoleto (mesma fronteira já aplicada a rede, disco e potência média). Regressão de contador continua inválida e falha de leitura limpa baseline. A amostra de ruptura não é válida no histórico; baseline atual permite recuperar no próximo ciclo, sem inventar zero. Limite de 12s é política de continuidade, não alteração de cadência; timestamp monotônico da coleta e comportamento de snapshot preservados. Fixtures de delta passam a avançar o tempo; novo teste cobre fronteira exata, lacuna >12s, tempo repetido/regressivo e recuperação. Nenhuma mudança de controles ou permissões. CI obrigatório, ainda não executado neste candidato.

### C03.8b — validação

CI 45895181070 (d423107), 15 jobs aprovados; Hub 140167190307, QEMU 140167190264, scanner sem vulnerabilidades reportadas. Evidência [pty-d423107.json](evidence/hub-c03/pty-d423107.json) preserva os relatórios originais. CPU combinada estático/econômico/balanceado/detalhado 0/0,217/0,533/0,983%; RSS medianas 6016/8960/9728/9984 KiB; navegação p95 17,325/17,928/17,395/17,254ms. Kernel 6.8.0-1073-azure (runs anteriores recentes 6.8.0-1070-azure). Após quatro observações balanceado abaixo de 0,5%, esta excede a referência; não concluir regressão causal pela correção de timestamp nem cumprimento estável da meta. Detalhado permanece acima. Precisamos de maior rastreabilidade e validação controlada, não reduzir arbitrariamente a frequência de coleta. M2 aberto.

### C03.8c — rastreabilidade do benchmark (schema 2)

A oscilação observada em outro kernel impede declarar cumprimento estável da referência de CPU. O harness passa a preservar série amostral compacta (tempo monotônico relativo em ns, deltas cumulativos de ticks próprios/filhos aguardados, RSS stat, RSS/PSS smaps_rollup quando legíveis), sem PID/caminhos/logs de processo. CPU usa duração entre leituras stat, separada da duração da janela PTY; rejeita timestamps/contadores não monotônicos. RSS do mesmo rollup permite comparar PSS sem confundir interfaces. Dados opcionais ausentes são nulos e contados; schema 1 histórico permanece intacto. Mesmas cinco sessões/modo, 15s warmup e 60s idle por modo; sem novos jobs ou artefatos. Teste sintético verifica parsing, ausência, duplicata, resumos, duração, ticks e rejeição. Custo do log aumenta, duração de coleta não; não representa CPU de toda árvore, não cria prova física nem estabilidade longa. Alteração apenas em teste/CI/docs, ainda não executada no candidato. Próxima análise deve recalcular resultados diretamente das séries; meta de CPU e M2 permanecem abertos.

### C03.8c — validação e contra-auditoria das séries

CI 45896695284 (e8c314f), 15 jobs aprovados, release ignorada; Hub 140172246100, QEMU 140172246051. Teste sintético de evidência passou e scanner sem vulnerabilidades reportadas. Relatórios e recálculo independente em [pty-e8c314f.json](evidence/hub-c03/pty-e8c314f.json). 238 pontos de memória/contadores em quatro janelas de ~60s: 61 estático, 60 econômico, 59 balanceado, 58 detalhado. Conferidos timestamps relativos, monotonicidade dos ticks, duração CPU, CPU combinada, contagens, mediana/p95/máximo RSS stat, RSS rollup e PSS, ausências e delta RSS; todos os resumos conferem. Nenhuma amostra PSS maior que RSS do mesmo rollup. Dados em KiB; PSS principal não é PSS da árvore. CPU combinada estático/econômico/balanceado/detalhado 0/0,167/0,533/0,883%; RSS medianas 6016/9088/9728/10166 KiB; RSS rollup medianas 6492/9592/10180/10460 KiB; PSS medianas 6488/9588/10176/10456 KiB; navegação p95 17,347/17,298/17,243/17,173 ms. Kernel 6.8.0-1070-azure; segunda observação consecutiva balanceado ligeiramente acima de 0,5%, portanto variação não explicada apenas pela troca de kernel. Não atribuir causalidade a mudanças documentais/teste ou interpretar deltas RSS de curto prazo como vazamento.

## Gate de saída C03 / M2 — revisão de prontidão

Candidato funcional experimental e somente leitura: e8c314f com CI integral aprovado; a revisão documental posterior não é a mesma execução. Escopo técnico implementado; não confundir com homologação M2 ou produção.

- [x] Coletores nativos limitados, estados e unidades explícitos, sem telemetria fictícia; CPU/RAM, swap, clock, hwmon/RPM, térmica, energia, bateria, rede, disco e espaço.
- [x] Workers independentes, intervalos por perfil, snapshot/freshness e histórico limitado, cancelamento cooperativo, teste com I/O bloqueado; context não interrompe syscall presa no kernel.
- [x] Interface opt-in, header, navegação, perfis, histórico e capacidades; alertas térmicos passivos somente com limites nativos válidos; nenhum controle administrativo habilitado.
- [x] Testes Go, race, PTY, compatibilidade legado, QEMU e coletor systemd real não-root; scanner sem ocorrências reportadas. QEMU não constitui homologação de todos os sensores físicos nem do cliente SSH.
- [x] Ganhos isolados verificados para histórico e largura ASCII; coalescência mantida por resultados observacionais. Evidências por SHA preservadas e contra-auditoria de potência, continuidade CPU e benchmark bruto validada.
- [x] RAM, latência local por marcador, startup e binário dentro das metas desejáveis nas observações; nenhum daemon permanente novo. Não substituir o teste de frame completo, impacto em jogo ou memória agregada.
- [ ] CPU: validar repetidamente em host controlado; referência <=0,5% de um núcleo permanece para comparação, balanceado oscila próximo dela, detalhado supera. Sem redefinir limites ou cadências; perfil detalhado não é padrão. Se persistir, investigar por profiling isolado, somente em ambiente descartável, antes de nova otimização. Não aprovar desempenho global por microbenchmark.
- [ ] Gate anterior à passagem para M3/C04: baseline física Bash/Gum e Go no host autorizado, versão instalada e hash, SSH real e contraprovas negativas do harness de baseline. Reutilizar [protocolo C00](hub-c00-gum-protocol.md), sem acesso/credenciais inventados ou alterações administrativas.
- [ ] C10/C11: estabilidade prolongada, custo agregado/filhos efêmeros, impacto em jogo/Chunky, rollback e homologação física dos controles antes de habilitá-los. Rebuild frio com toolchain fixada no gate de distribuição.
- [ ] Decisão explícita de saída M2 após verificar gates aplicáveis; integração #45→#46→#47→#48 somente com autorização, sem release ou alteração do ponto de entrada.

### Próxima validação controlada

No host Linux autorizado, sem root, usar checkout confiável e binário experimental separado, não substituir o Hub instalado. Fixar SHA/versões e registrar condições do host, temperatura e carga. Rodar baseline C00 conforme protocolo existente e o harness Go com 30 startups e idle de 600 s por modo (comando abaixo, fora de CI). Repetir em condições equivalentes, alternar ordem e manter controle sem Hub; registrar CPU própria/filhos, RSS/PSS, bytes PTY e latência, não inferir tráfego SSH a partir de PTY. Não iniciar/reiniciar serviço nem mudar mundo/configuração para medir. Testar SSH com sessão autorizada, resize, Q/Esc, Ctrl+C e desconexão, verificando restauração de TTY. Para CPU total da árvore e carga real usar protocolo C10; este harness não mede filhos ainda vivos no fim, navegação prolongada ou jogo. Preservar JSON sanitizado por SHA e não compartilhar segredos/endereços privados.

```bash
python3 tests/hub-c01-pty-test.py /caminho/para/crias-tui-next --compare-telemetry --samples 30 --idle-seconds 600 --warmup-seconds 15
```

Sem acesso autorizado a host físico ou sessão SSH nesta execução; itens externos explicitamente bloqueados. Próxima ação: contraprovas negativas do harness e coleta controlada, sem abrir novas funcionalidades C04 ou alterar metas. M2 permanece aberto.

### C03.9a — contraprovas negativas do harness C00

Candidato acrescenta nove contraprovas no job Test Shell existente: ausência de Gum simulada por mock (sem remover pacote/PATH), executável de versão com erro ou versão vazia, PTY fechado antes do frame, fallback numérico, tentativa de sudo bloqueada pelo bootstrap do harness, frame inesperado, silêncio até timeout e saída acima de MAX_FRAME. Casos CLI usam diretório temporário, executável Gum sintético apenas para validar falhas e Hub fixture controlado; exigem saída não-zero, diagnóstico específico e nenhum JSON parcial. Timeout externo 15s por caso; timeout interno 1s. Sem instalação, serviço, escrita no host de produção, root ou credenciais. Testes não constituem medição Gum real; baseline nominal já validada em Arch/QEMU. Nenhum código produtivo alterado. CI anterior 45909843742 ainda em execução na consulta inicial; candidato separado até gate integral. Validação dos negativos e M2 ainda pendentes; contraprovas não substituem benchmark físico/SSH.
