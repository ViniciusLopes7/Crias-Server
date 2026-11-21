# Tuning por Hardware

O Crias-Server detecta os recursos do host e propõe parâmetros conservadores para cada servidor. O ajuste automático é uma estimativa inicial: modpacks pesados e múltiplos serviços devem ser validados no hardware real.

## Sinais detectados

- RAM total, MemAvailable e swap pelo mesmo snapshot de `/proc/meminfo` (fallback `free`)
- Threads visíveis e CPUs utilizáveis (`nproc` limitado pela menor cota `cpu.max` da hierarquia cgroup v2; limites fracionários arredondados para baixo, mínimo 1)
- Tipo de disco (HDD, SSD, NVME)
- Filesystem (ZFS/Btrfs/LVM detectados — tuning de bloco pode ser pulado)
- Teto de RAM de cgroups (`memory.max`) e folga estimada incluindo ancestrais; considera metade de `inactive_file` como cache potencialmente reclamável, mantendo margem de segurança
- Virtualização (`systemd-detect-virt`) — tuning global de host é pulado em container/VPS

## Tiers

| Tier | Critério aproximado | Foco |
|------|---------------------|------|
| LOW  | ≤3 GB RAM ou ≤2 cores | Estabilidade em host fraco |
| MID  | ≤12 GB RAM ou ≤6 cores | Equilíbrio entre desempenho e consumo |
| HIGH | >12 GB RAM e >6 cores | Melhor throughput e capacidade |

**Thresholds configuráveis** em `config.env`:

```bash
HW_LOW_TIER_MAX_RAM_MB=3072
HW_LOW_TIER_MAX_CPU_CORES=2
HW_MID_TIER_MAX_RAM_MB=12288
HW_MID_TIER_MAX_CPU_CORES=6
```

## O que é ajustado automaticamente

### Por stack (Minecraft/Terraria)

- `max-players`, `view-distance`, `simulation-distance` (Minecraft)
- `maxplayers`, `npcstream`, `autocreate` (Terraria)
- Heap JVM (`-Xms`, `-Xmx`) dimensionado pela RAM total efetiva do host, sem depender da disponibilidade transitória na instalação e sem teto artificial de 12 GiB; parte do orçamento fica para memória nativa da JVM
- `MemoryHigh` do systemd (pressão progressiva perto do teto) e `MemoryMax` (última defesa), com folga proporcional para memória nativa
- G1 GC region size baseado no heap
- Retenção de backup (LOW=5, MID=7, HIGH=10 dias)
- Nível de compressão zstd (HDD=-3, SSD/NVME=-1)
- `sync-chunk-writes=true` no Minecraft, inclusive em SSD/NVMe: prioriza integridade do mundo. O antigo auto-tuning desativava sincronizacao em discos rapidos e aumentava a janela de perda de dados apos crash/OOM. Um opt-out explicito `MINECRAFT_SYNC_CHUNK_WRITES=false` continua disponivel se o operador medir o custo de I/O, aceitar o risco e manter backups consistentes.

### No host (opcional, desativado por padrão)

O tuning **do servidor Minecraft** continua automático. Mudanças **globais no Linux** não são aplicadas automaticamente: para habilitá-las, configure **ambas** `APPLY_SYSTEM_TUNING=true` e `SYSTEM_TUNING_SCOPE=host`. O instalador respeita arquivos ZRAM/sysctl não gerenciados e não os sobrescreve. O restante das opções globais é opt-in separado.

- `zram-generator` com tamanho baseado em RAM (metade em hosts ≤4 GB, fixo 2 GB em >8 GB)
- `vm.swappiness` (60 se ≤4 GB, 40 se ≤8 GB, 20 se >8 GB)
- `vm.vfs_cache_pressure=50`
- I/O scheduler: `bfq` para HDD, `mq-deadline` para SSD (somente com `CRIAS_TUNE_BLOCK_DEVICE=true`)
- `read_ahead_kb`: 4096 HDD, 2048 SSD, 1024 NVME (somente com `CRIAS_TUNE_BLOCK_DEVICE=true`)
- `cpupower` governor: `performance` em MID/HIGH (se não em bateria), `ondemand` caso contrário (somente com `CRIAS_TUNE_CPU_GOVERNOR=true`)
- `nofile` limit 65536 para o usuário do servidor

Exemplo de opt-in explícito em `config.env`:

```bash
APPLY_SYSTEM_TUNING="true"
SYSTEM_TUNING_SCOPE="host"
CRIAS_TUNE_CPU_GOVERNOR="false"   # mantenha politica de energia atual
CRIAS_TUNE_BLOCK_DEVICE="false"    # mantenha scheduler/read-ahead atuais
```

**Atenção:** o tuning global pode afetar outros aplicativos e containers. Ajustes de ZRAM e swappiness não substituem RAM física. O instalador não deve sobrescrever `/etc/systemd/zram-generator.conf` ou `/etc/sysctl.d/99-server-tuning.conf` se forem de terceiros. Valores de memória do cgroup incluem cache: em workloads com cache elevado, o cálculo é intencionalmente conservador e pode solicitar revisão manual.

## Filesystems avançados

- **ZFS**: detectado automaticamente; tuning de scheduler é pulado (ZFS gerencia I/O).
- **Btrfs**: em subvolumes/dispositivos abstratos, tuning de bloco pode ser pulado com aviso.
- **LVM**: quando o dispositivo físico subjacente é detectado, tuning é aplicado nesse alvo.

## Virtualização (containers/VPS)

Se `systemd-detect-virt` detectar container (docker/lxc/containerd/kubepods), o tuning de host é **pulado automaticamente** para evitar conflito com o hypervisor.

**Override efetivo (CR-24)**: apenas `VIRT_TUNING_BEHAVIOR="force"` ignora o
auto-skip (implementado em `apply_stack_system_tuning`). `SYSTEM_TUNING_SCOPE`
é lido por `apply_common_system_tuning` (escopo do que o tuning toca) e **não**
desativa o skip por virtualização — não confunda as duas chaves:

| Chave | Onde age | Efeito |
|---|---|---|
| `VIRT_TUNING_BEHAVIOR=force` | `apply_stack_system_tuning` | Roda o tuning mesmo em container/VPS (não recomendado) |
| `SYSTEM_TUNING_SCOPE=host` | `apply_common_system_tuning` | Escopo das operações de tuning quando ele roda |

```bash
# Em config.env
VIRT_TUNING_BEHAVIOR="force"   # ignora o auto-skip de virtualização
```

## Override manual de tier

Em `config.env`:

```bash
FORCE_HARDWARE_TIER="HIGH"   # LOW, MID, HIGH ou vazio para auto
```

Se override manual estiver ativo, ele substitui o tier detectado automaticamente.

## Recalibração em runtime

Após mudança de hardware (mais RAM, troca de disco, etc.) sem reinstalar:

```bash
# Detectar novo hardware e reaplicar tuning
sudo systemctl stop minecraft
sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware
sudo /usr/local/libexec/crias/tt-manager.sh reconfigure-hardware

# Forçar tier específico
sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware HIGH
sudo /usr/local/libexec/crias/tt-manager.sh reconfigure-hardware LOW

# Iniciar apos conferir heap e MemoryMax sincronizados
systemctl show minecraft -p MemoryHigh -p MemoryMax -p MemorySwapMax
sudo systemctl start minecraft
# ou
sudo systemctl restart terraria
```

## Ver perfil aplicado

```bash
mchw   # Minecraft (alias)
tthw   # Terraria (alias)
```

Mostra `HW_TOTAL_RAM_MB`, `HW_CPU_CORES`, `HW_DISK_TYPE`, `HW_TIER` e todos os parâmetros `MC_*`/`TT_*` aplicados.

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação (seção 3: tuning)
- [../README.md](../README.md) — README principal (tabela de tiers)

## Falha de memória: heap Java versus limite do systemd

O cálculo do Minecraft agora reserva RAM para o sistema operacional e para o consumo **fora do heap Java** (metaspace, stacks de threads, buffers, compilador JIT). Em um Arch Linux minimalista dedicado, a reserva do host é **pequena e absoluta**: 256 MiB até 1,5 GiB, 384 MiB até 2 GiB e, acima disso, entre 512 e 768 MiB. Toda a memória restante fica disponível ao cgroup do serviço, mas `-Xmx` permanece menor que `MemoryMax` para acomodar a memória nativa do Java. A reserva não garante execução de qualquer modpack: monitore `MemoryPeak`, OOM e serviços SSH/Tailscale.

O erro `Memory cgroup out of memory: Killed process (java)` não comprova, isoladamente, vazamento de memória: pode significar que o serviço atingiu o limite do systemd. Consulte `sudo crias-tui --doctor`, `systemctl show minecraft -p MemoryMax -p MemoryPeak -p NRestarts` e `journalctl -k -b` antes de aumentar os limites. O ajuste do instalador não reescreve automaticamente os limites de serviços já instalados; a mudança exige reconfiguração deliberada, validação do arquivo `.service` e reinicialização controlada.

Em hosts de aproximadamente 1 GB de RAM, o modo conservador não garante que um modpack moderno seja viável. Recomenda-se RAM suficiente e teste real.

## Limite de reinícios após OOM

O template do `minecraft.service` usa **`Restart=no`**: se o Java cair por OOM ou outra falha, o systemd não tentará iniciar novamente sozinho. Isso impede que um boot de modpack pesado cause mortes repetidas por OOM. O operador deve diagnosticar a causa antes de executar `sudo systemctl start minecraft.service` novamente. `StartLimitIntervalSec=300s` e `StartLimitBurst=3` continuam limitando partidas manuais muito próximas, sem criar bloqueio permanente por contagem de starts bem-sucedidos. `OOMPolicy=stop` encerra a unidade em OOM do cgroup.

A mudança só entra em vigor quando a unidade do systemd é instalada/atualizada. Para interromper um ciclo ativo use `sudo systemctl stop minecraft.service`. Para impedir a partida automática enquanto investiga, `sudo systemctl disable --now minecraft.service` (reative depois). Após corrigir o problema, inicie manualmente com `sudo systemctl start minecraft.service`. Se o limite de partidas manuais for atingido, `sudo systemctl reset-failed minecraft.service` limpa o contador antes de uma nova tentativa deliberada.

Os eventos do kernel não identificam sozinhos qual perfil ou mod causou o problema. Confira journal, memória do cgroup e limite efetivo antes de aumentar heap ou `MemoryMax`.

A unidade usa `OOMScoreAdjust=200` em vez de `-800`: diante de OOM **global do host**, o Java pode ser encerrado antes de serviços de recuperação remota, como SSH. Essa prioridade não evita OOM dentro do `MemoryMax` nem garante que outros serviços nunca sejam afetados. O sistema deve permanecer acessível para investigar a causa. Se desabilitar a partida automática durante diagnóstico, reative apenas depois da correção.


## Contratos de memória revisados

- A cota do host considera limites `memory.max` do cgroup atual **e de seus ancestrais**, não apenas o arquivo da raiz. A RAM disponível é limitada à cota efetiva identificada.
- O cálculo reserva memória para o SO e para o consumo nativo da JVM; se não houver orçamento suficiente, **falha antes de gerar configurações inválidas**. Não aumenta artificialmente o heap mínimo para exceder a cota.
- `-Xms` automático foi reduzido para cerca de 30% de `-Xmx` (com piso de 256 MB), e a pré-alocação `AlwaysPreTouch` foi removida do launcher padrão para reduzir pressão na inicialização.
- O launcher verifica a memória do cgroup antes de executar Java e recusa `user_jvm_args.txt` Forge/NeoForge e variáveis `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS` com parâmetros conflitantes de heap/MaxRAM ou memória direta que poderiam sobrescrever o tuning.
- `reconfigure-hardware` **exige Minecraft parado**. Atualiza `MemoryHigh`, `MemoryMax`, `MemorySwapMax`, `Restart=no` e `OOMPolicy=stop` por drop-in persistente em `/etc/systemd/system/minecraft.service.d/20-crias-memory.conf`, valida com `systemd-analyze`, confere tanto `MemoryMax` quanto `EffectiveMemoryMax` (que inclui cotas da slice pai) e restaura o drop-in anterior se a validação falhar. O comando não reinicia o serviço automaticamente.
- `MemorySwapMax=512M` permite até 512 MiB de swap emergencial **se** o host tiver swap/ZRAM disponível; não ativa swap automaticamente nem deve mascarar falta de RAM.

**Memória sob pressão:** `MemAvailable` e a folga do cgroup permanecem no diagnóstico, mas **não diminuem o heap permanentemente** durante a instalação. A memória total/cota efetiva é o orçamento fixo; o host continua sujeito a OOM global se outros processos crescerem depois. Se a cota total não comportar um heap mínimo com reservas, o instalador falha claramente.

**Gravações de chunks:** `sync-chunk-writes=true` é mantido para HDD, SSD, NVMe ou disco incerto. Detectar um SSD não elimina quedas de energia, OOM ou risco de corrupção de região. O administrador pode optar por `MINECRAFT_SYNC_CHUNK_WRITES=false` em `config.env`, sabendo que a opção pode reduzir durabilidade após crash; a recalibração respeita esse opt-out. Referência oficial: [Minecraft Java Nether Update](https://www.minecraft.net/en-us/article/nether-update-java).

**Modpacks grandes:** a política de RAM é genérica e não analisa os mods do pacote. O tuning é um orçamento inicial e não garante que todos os mods caibam no heap. Analise `MemoryPeak`, `MemoryMax`, logs do Java e uso do host antes de escolher o heap; não aumente `-Xmx` sozinho sem ajustar o cgroup.

## Prioridade no OOM global do Linux

O template anterior marcava o Minecraft com `OOMScoreAdjust=-800`, dando proteção alta ao Java perante o OOM **global** e potencialmente tornando outros processos mais expostos. A unidade passa a usar `OOMScoreAdjust=200`, preservando prioridade operacional para o host e seu acesso remoto; o `MemoryMax` continua regulando o OOM **do próprio cgroup**. Isso não impede interrupção do Minecraft: backup/recuperação e RAM física suficiente continuam necessários.


### Politica de RAM a partir desta revisao

O orçamento do serviço corresponde à **RAM efetiva do host menos uma reserva mínima absoluta do SO** (256 MiB até 1,5 GiB; 384 MiB até 2 GiB; acima disso, `clamp(RAM/12, 512 MiB, 768 MiB)`). É independente do tier LOW/MID/HIGH. O heap recebe esse orçamento **menos cerca de 25% para a memória nativa** da JVM, respeitando pisos de segurança. `MemoryHigh` atua em 95% do orçamento e `MemoryMax` é a última defesa. A disponibilidade instantânea não determina limites permanentes. O sistema mantém uma pequena folga real para o kernel, SSH e Tailscale, sem reservar 15-25% da RAM crescente da máquina.

**Atualizacao de uma instalacao existente:** baixar uma nova release nao substitui as unidades `systemd` e os scripts ja instalados. Primeiro atualize o programa; em seguida pare o Minecraft e, com o novo `mc-manager.sh` disponivel, execute `sudo /usr/local/libexec/crias/mc-manager.sh reconfigure-hardware`. Confira `systemctl cat minecraft.service` e `systemctl show minecraft.service -p MemoryHigh -p MemoryMax -p MemorySwapMax -p Restart`. A recalibracao nao inicia o jogo automaticamente.
