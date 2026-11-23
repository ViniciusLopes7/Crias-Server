# Arquitetura atual do Crias-Server

**Referência de código:** `main` no commit `9496a5f` (2026-11-23). Este texto documenta o estado observado, não uma arquitetura futura.

## Fluxos e fronteiras

| Fluxo | Entrada | Componentes responsáveis | Limite de responsabilidade |
|---|---|---|---|
| Bootstrap e instalação | `crias-bootstrap.sh`, `install.sh` | `shared/lib/stack-installer.sh`, `minecraft/install.sh`, `terraria/install.sh` | instalar e configurar serviços; reconfiguração com efeitos explícitos |
| Administração local | `crias-tui.sh` | `mc-manager.sh`, `tt-manager.sh`, `shared/lib/manager-common.sh` | menus chamam ações CLI; não devem implementar regras de jogo duplicadas |
| Hardware e JVM | `shared/lib/hardware-profile.sh`, `shared/lib/minecraft-tuning.sh` | `runtime.env`, drop-in systemd, `start-server.sh` | calcular limites coerentes e impedir início inseguro |
| Backup | `minecraft/backup-cron.sh`, `terraria/backup-cron.sh` | `shared/lib/backup-engine.sh`, timer systemd | consistência de salvamento, retenção e restauração |
| Atualização de ferramentas | `crias-update.sh`, `crias-bootstrap.sh --update-tools` | releases versionadas e journal persistente | atualiza apenas ferramentas/scripts, não mundos/modpack/systemd |
| Administração remota opcional | `discord-bot/` → `discord-agent/` | gRPC, systemd, RCON | autenticação e permissões separadas do Hub |

## Fronteiras de confiança

- `/usr/local/libexec/crias/`: ferramentas administrativas root-owned; gerenciadores validam bibliotecas antes de executá-las com privilégios.
- `/opt/minecraft-server/` e equivalente do Terraria: dados controlados pelo usuário do serviço, nunca origem confiável para scripts root.
- `/opt/crias-server`: referência versionada para a release administrativa; atualizador mantém um alvo anterior para recuperação.
- `runtime.env` e `server.properties` podem conter segredos ou parâmetros que mudam o comportamento; evitar expor valores completos em logs.
- RCON do Minecraft é local e não criptografado; o SSH/Tailscale protege o caminho de administração, não a porta RCON exposta.
- `systemd` é autoridade para cota de processo e estado da unit; `-Xmx` limita apenas o heap Java, não memória nativa.

## Fluxo de alteração segura

Para cada ação de escrita: entrada validada → cálculo sem efeitos → preparação e snapshot → aplicação coordenada → validação efetiva → sucesso ou recuperação. O código atual ainda precisa de revisão de transação conjunta em `cmd_reconfigure_hardware()`; não declarar que essa propriedade já está totalmente atendida.

## Lacunas reconhecidas

- `crias-tui.sh` concentra a navegação principal numa função longa.
- Instalação de mods extras e QoL repete alguma lógica de detecção.
- `tests/run-all.sh` e a lista do CI não representam exatamente a mesma suíte.
- O QEMU inicia servidores reais até o prompt de EULA, **sem mundo ativo**; testes RCON/Chunky também usam mocks.
- Algumas descrições de versões antigas em ROADMAP/CHANGELOG e guias precisam de revisão editorial incremental.

Consulte [qualidade](engineering-quality.md), [linha de base](quality-baseline.md), [QEMU](testing-qemu.md), [atualizações](updates.md) e [segurança](security.md).
