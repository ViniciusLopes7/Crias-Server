# Hardware Tuning (Shared)

O Crias-Server detecta hardware automaticamente para ajustar parametros de servidor e host.

## Sinais detectados

- RAM total e RAM disponivel
- Cores e threads de CPU
- Tipo de disco (HDD, SSD, NVME)

## Tiers

| Tier | Criterio aproximado | Foco |
|------|----------------------|------|
| LOW  | RAM baixa ou CPU limitada | Estabilidade em host fraco |
| MID  | Hardware intermediario | Equilibrio entre desempenho e consumo |
| HIGH | Hardware robusto | Melhor throughput e capacidade |

## O que e ajustado automaticamente

- Parametros do jogo (ex.: players, distancias, heap)
- Limites de servico systemd (MemoryMax)
- Politicas de host (zram, swappiness, scheduler e governor)

## Override manual

No config.env:

```bash
FORCE_HARDWARE_TIER="LOW"
```

Valores aceitos: LOW, MID, HIGH ou vazio.

Se override manual estiver ativo, ele substitui o tier detectado automaticamente.

## Recalibracao em runtime

Minecraft:

```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
```

Terraria:

```bash
sudo /opt/terraria-server/tt-manager.sh reconfigure-hardware
```
