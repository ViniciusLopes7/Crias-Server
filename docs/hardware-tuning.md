# Tuning por Hardware

O Crias-Server detecta os recursos do host e propõe parâmetros conservadores para cada servidor. O ajuste automático é uma estimativa inicial: modpacks pesados e múltiplos serviços devem ser validados no hardware real.

## Sinais detectados

- RAM total e RAM disponível
- Cores e threads de CPU
- Tipo de disco (HDD, SSD, NVME)
- Filesystem (ZFS/Btrfs/LVM detectados — tuning de bloco pode ser pulado)
- Virtualização (`systemd-detect-virt`) — tuning de host é pulado em container/VPS

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
- Heap JVM (`-Xms`, `-Xmx`) estimado a partir da RAM física, com folga para o SO e a memória nativa do processo Java (Minecraft)
- `MemoryMax` do systemd (acima do heap para acomodar JVM overhead)
- G1 GC region size baseado no heap
- Retenção de backup (LOW=5, MID=7, HIGH=10 dias)
- Nível de compressão zstd (HDD=-3, SSD/NVME=-1)

### No host (se `APPLY_SYSTEM_TUNING=true` e `SYSTEM_TUNING_SCOPE=host`)

- `zram-generator` com tamanho baseado em RAM (metade em hosts ≤4 GB, fixo 2 GB em >8 GB)
- `vm.swappiness` (60 se ≤4 GB, 40 se ≤8 GB, 20 se >8 GB)
- `vm.vfs_cache_pressure=50`
- I/O scheduler: `bfq` para HDD, `mq-deadline` para SSD, default para NVME
- `read_ahead_kb`: 4096 HDD, 2048 SSD, 1024 NVME
- `cpupower` governor: `performance` em MID/HIGH (se não em bateria), `ondemand` caso contrário
- `nofile` limit 65536 para o usuário do servidor

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
systemctl show minecraft -p MemoryMax -p MemorySwapMax
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

O cálculo do Minecraft agora reserva RAM para o sistema operacional e para o consumo **fora do heap Java** (metaspace, stacks de threads, buffers, compilador JIT). O limite `MemoryMax` permanece maior que `MAX_RAM`, mas não deve ocupar praticamente toda a RAM física. Em máquinas pequenas, o heap calculado será menor que nas versões anteriores; isso prioriza estabilidade, não FPS ou TPS máximos. Modpacks pesados podem exigir mais RAM física.

O erro `Memory cgroup out of memory: Killed process (java)` não comprova, isoladamente, vazamento de memória: pode significar que o serviço atingiu o limite do systemd. Consulte `sudo crias-tui --doctor`, `systemctl show minecraft -p MemoryMax -p MemoryPeak -p NRestarts` e `journalctl -k -b` antes de aumentar os limites. O ajuste do instalador não reescreve automaticamente os limites de serviços já instalados; a mudança exige reconfiguração deliberada, validação do arquivo `.service` e reinicialização controlada.

Em hosts de aproximadamente 1 GB de RAM, o modo conservador não garante que um modpack moderno seja viável. Recomenda-se RAM suficiente e teste real.

## Limite de reinícios após OOM

O template do `minecraft.service` usa `Restart=on-failure`, mas limita falhas repetidas a três tentativas em cinco minutos (`StartLimitIntervalSec=300s`, `StartLimitBurst=3`). `OOMPolicy=stop` encerra a unidade quando o cgroup sofre falta de memória. Isso evita ciclos ilimitados de reinício.

A mudança só entra em vigor quando a unidade do systemd é instalada/atualizada. Para interromper um ciclo ativo use `sudo systemctl stop minecraft.service`. Para impedir a partida automática enquanto investiga, `sudo systemctl disable --now minecraft.service` (reative depois). Após corrigir o problema, `sudo systemctl reset-failed minecraft.service` limpa o bloqueio de tentativas.

Os eventos do kernel não identificam sozinhos qual perfil ou mod causou o problema. Confira journal, memória do cgroup e limite efetivo antes de aumentar heap ou `MemoryMax`.


## Contratos de memória revisados

- A cota do host considera limites `memory.max` do cgroup atual **e de seus ancestrais**, não apenas o arquivo da raiz. A RAM disponível é limitada à cota efetiva identificada.
- O cálculo reserva memória para o SO e para o consumo nativo da JVM; se não houver orçamento suficiente, **falha antes de gerar configurações inválidas**. Não aumenta artificialmente o heap mínimo para exceder a cota.
- `-Xms` automático foi reduzido para cerca de 30% de `-Xmx` (com piso de 256 MB), e a pré-alocação `AlwaysPreTouch` foi removida do launcher padrão para reduzir pressão na inicialização.
- O launcher verifica a memória do cgroup antes de executar Java e recusa `user_jvm_args.txt` Forge/NeoForge com parâmetros duplicados de heap/MaxRAM que poderiam sobrescrever o tuning.
- `reconfigure-hardware` **exige Minecraft parado**. Atualiza `MemoryMax` por drop-in persistente em `/etc/systemd/system/minecraft.service.d/20-crias-memory.conf`, valida com `systemd-analyze`, confere tanto `MemoryMax` quanto `EffectiveMemoryMax` (que inclui cotas da slice pai) e restaura o drop-in anterior se a validação falhar. O comando não reinicia o serviço automaticamente.
- `MemorySwapMax=0` continua impedindo que o **processo Minecraft** use swap; isso não impede que o host utilize ZRAM para outros processos. A opção prioriza limitar pausas graves de JVM, mas não substitui memória física suficiente.

**Modpacks grandes:** o tuning é um orçamento inicial e não garante que todos os mods caibam no heap. Analise `MemoryPeak`, `MemoryMax`, logs do Java e uso do host antes de escolher o heap; não aumente `-Xmx` sozinho sem ajustar o cgroup.

