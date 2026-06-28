# Tuning por Hardware

O Crias-Server detecta hardware automaticamente e ajusta parâmetros de servidor e host.

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
- Heap JVM (`-Xms`, `-Xmx`) baseado em RAM disponível (Minecraft)
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

Para forçar tuning mesmo em container (não recomendado):

```bash
# Em config.env
SYSTEM_TUNING_SCOPE="host"
VIRT_TUNING_BEHAVIOR="force"
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
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware

# Forçar tier específico
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware HIGH
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware LOW

# Reiniciar para aplicar no runtime
sudo systemctl restart minecraft
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
