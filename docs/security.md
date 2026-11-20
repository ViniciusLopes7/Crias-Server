# Segurança e Operação

Referência de segurança e operação: firewall, SSH, permissões, logs, serviços systemd e políticas de limpeza. Execute comandos que modificam acesso remoto somente depois de validar como recuperar o host.

## Firewall

Abertura de portas e permissões devem ser revistas no host de destino. Para servidores expostos à internet, permita apenas os serviços necessários; não presuma que as regras existentes foram alteradas pelo instalador.

- **Minecraft**: porta configurada em `server.properties` (default: `25565`)
- **Terraria**: porta configurada em `config/serverconfig.txt` (default: `7777`)
- **crias-agent**: `127.0.0.1:8473` apenas (não expor direto — usar Tailscale Funnel)
- **SSH** (v1.2.0): porta `22` (default OpenSSH) — libere apenas se `INSTALL_SSH=true`

### Exemplo: restringir acesso à interface Tailscale (nftables)

> **AVISO (CR-27)**: aplicar `policy drop` sem as regras de estado/ICMP abaixo
> pode cortar o seu próprio acesso SSH (sessões fora de `tailscale0`, respostas
> de conexões iniciadas pelo host). Aplique SEMPRE com um plano de rollback
> (console físico, out-of-band, ou um job agendado que reverte o firewall):
>
> ```bash
> # Exemplo de rollback temporizado — reverte em 3 min se você não confirmar:
> sudo sh -c 'echo "systemctl stop nftables" | at now + 3 minutes'
> ```

```nft
# /etc/nftables.conf
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback
        iifname "lo" accept

        # Conexões já estabelecidas/relacionadas (sem isto, respostas de
        # conexões INICIADAS pelo host são descartadas e o host "perde" rede)
        ct state established,related accept

        # ICMP/ICMPv6 — essenciais (PMTUD, NDP; sem IPv6-ND o host perde
        # conectividade v6 inteira)
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        # Tailscale (interface VPN — tráfego de confiança)
        iifname "tailscale0" tcp dport 25565 accept comment "Minecraft"
        iifname "tailscale0" tcp dport 7777 accept comment "Terraria"

        # SSH admin — ajuste a interface/porta para a SUA topologia antes de
        # aplicar. Se você administra por uma interface que não é a tailscale0,
        # libere-a AQUI, senão perde o acesso no momento em que o firewall sobe.
        iifname "tailscale0" tcp dport 22 accept comment "SSH via Tailscale"
    }
}
```

```bash
# Aplique com rollback armado (ver AVISO acima) e confira o acesso ANTES:
sudo systemctl enable --now nftables
# Nova sessão SSH em outro terminal para validar; só então cancele o rollback.
```

## SSH (v1.2.0)

### Live ISO (legado — descontinuado)

O fluxo de live ISO customizada foi descontinuado; o procedimento
histórico (credenciais, autologin, sshd manual) está preservado em
[docs/legacy-iso.md](legacy-iso.md). O fluxo suportado é o bootstrap no
host instalado (`crias-bootstrap.sh`).

### Host instalado (`INSTALL_SSH=true`)

Se você responder "sim" à pergunta *"Habilitar SSH no servidor instalado?"*
(ou setar `INSTALL_SSH=true`), o `install.sh` configura:

1. Instala `openssh` (se não presente) via `pacman`.
2. Cria o usuário **`crias`** (grupo `wheel` = sudo), com senha pedida
   interativamente (`read -s`, sem echo). Em `NON_INTERACTIVE`, o usuário é
   criado com senha bloqueada (login por chave pública apenas).
3. Cria `/etc/sudoers.d/crias-wheel` (`%wheel ALL=(ALL) ALL`) — sudo exige senha.
4. Cria drop-in `/etc/ssh/sshd_config.d/10-crias.conf`:
   ```
   PermitRootLogin no
   PasswordAuthentication yes
   PubkeyAuthentication yes
   ```
5. Habilita e (re)inicia `sshd.service`.

Conexão: `ssh crias@<ip-do-servidor>` (use a senha definida, ou configure
chaves em `~crias/.ssh/authorized_keys`).

### Hardening recomendado (pós-install)

Para produção, considere endurecer ainda mais:

```bash
# Desabilitar login por senha (apenas chave pública):
sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' \
    /etc/ssh/sshd_config.d/10-crias.conf
sudo systemctl restart sshd

# Adicionar sua chave pública ao usuário crias:
sudo -u crias mkdir -p /home/crias/.ssh
sudo -u crias tee /home/crias/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub
sudo -u crias chmod 700 /home/crias/.ssh
sudo -u crias chmod 600 /home/crias/.ssh/authorized_keys
```

### Host keys

As host keys SSH (`/etc/ssh/ssh_host_*`) **não** são pré-bakeadas na ISO —
são geradas ephemeramente por `sshdgenkeys.service` no primeiro boot. Cada
instância da ISO tem chaves únicas. Clientes verão "host key changed" se
reinstalarem/recriarem a ISO — isso é esperado e seguro.

## Logs e rotação

| Stack | Arquivo de log | Rotação |
|-------|----------------|---------|
| Minecraft | `$MINECRAFT_SERVER_DIR/logs/*.log` | `/etc/logrotate.d/crias-minecraft` (diário, 14 dias, compressão) |
| Terraria | `journalctl -u terraria` (sem arquivo) | Configurar `SystemMaxUse=500M` em `/etc/systemd/journald.conf` |
| crias-agent | `/var/log/crias-agent/` + journalctl | Limitado por `MemoryMax=128M` no systemd |

Se mudar o diretório do servidor, reinstale ou reaplique a configuração para atualizar o caminho do `logrotate`.

## Health checks

```bash
# Minecraft: porta + RCON
sudo /usr/local/libexec/crias/mc-manager.sh health

# Terraria: apenas porta (sem RCON nativo)
sudo /usr/local/libexec/crias/tt-manager.sh health

# crias-agent: porta + RCON via gRPC GetHealth
# (validado pelo bot Discord automaticamente a cada 5 min)
```

## Hardening systemd

Os templates `.service` do projeto aplicam hardening:

```ini
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RemoveIPC=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallArchitectures=native
```

> **Atenção**: `MemoryDenyWriteExecute=yes` **NÃO** é aplicado em
> `minecraft.service`/`terraria.service` porque JVM/Mono precisam de JIT. É
> aplicado em `crias-agent.service` (Go é AOT-compiled).
>
> **Exceção do crias-agent (CR-02)**: a unit do AGENTE **não** aplica
> `NoNewPrivileges`, `RestrictSUIDSGID`, `CapabilityBoundingSet=` nem
> `AmbientCapabilities=` — o agente invoca `/usr/bin/sudo` (setuid) para o
> systemctl allowlistado, e essas diretivas bloqueiam a recuperação de
> privilégios pelo setuid (controle remoto falhava em silêncio). A fronteira
> de privilégio do agente é o sudoers allowlist; todo o RESTO do hardening
> acima permanece. **Não "corrija" a unit do agente de volta** — ver seção
> "Hardening do agente (crias-agent)" no final deste documento.

### Editar units (cuidado com `Conflicts=`)

As units de Minecraft e Terraria têm `Conflicts=terraria.service` e `Conflicts=minecraft.service` respectivamente — impede ambos rodarem simultaneamente.

`Conflicts=` **não pode** ser sobrescrito por drop-in (`/etc/systemd/system/servicename.d/*.conf`). Para alterar:

```bash
sudo systemctl edit --full minecraft.service
# editar Conflicts= no editor
sudo systemctl daemon-reload
sudo systemctl restart minecraft
```

Documente qualquer alteração de unit no runbook operacional para evitar conflitos durante updates de pacote via `pacman`.

## MAC (AppArmor / SELinux)

O repositório **não** embarca perfis AppArmor ou SELinux.

- Se você usa AppArmor ou SELinux, trate-os como configuração local do host.
- O instalador não gera nem gerencia políticas MAC automaticamente.

## Rollback em caso de falha

Se a instalação falhar, o rollback é **best-effort**:
- Artefatos gerados (`.service`, logrotate, scripts em `/opt/`) são removidos
- Se o diretório `/opt/<stack>` **não** pré-existia, é removido inteiro
- Se pré-existia, apenas artefatos do installer são removidos (dados do usuário preservados)

O rollback é disparado automaticamente via `trap EXIT` em `run_stack_install`.

---

## Política de cleanup do stack oposto

Quando `CLEANUP_OTHER_STACK=true` (default), o instalador detecta stack oposto e pergunta se deseja desativá-lo.

### O que é desativado (não destrutivo)

- `systemctl stop <stack>` + `systemctl disable <stack>`
- Remoção do autoload de aliases em `/etc/profile.d/crias-server.sh`
- Remoção de entradas de crontab do backup

### O que NÃO é feito

- Dados em `/opt/` são **preservados**
- Usuários do sistema são **preservados**
- Backups existentes são **preservados**

Operações destrutivas adicionais (remoção de `/opt` ou usuário) exigem comando manual opt-in separado.

### Recarregar shell após cleanup

```bash
source /etc/profile.d/crias-server.sh
# ou abra um novo terminal
```

### Recomendação antes de cleanup

1. Faça backup externo dos mundos e arquivos importantes.
2. Revise manualmente o que será desativado.
3. Confirme que o stack selecionado para manter é o correto.

---

## Veja também

- [tutorial.md](tutorial.md) — Tutorial de operação
- [Tailscale.md](Tailscale.md) — Conexão via Tailscale
- [../README.md](../README.md) — README principal (hardening do crias-agent)


## Fronteira root x usuário do jogo (EXP-33/EXP-34)

A partir desta versão os artefatos administrativos vivem FORA do diretório
do servidor:

| Artefato | Local | Dono | Motivo |
|---|---|---|---|
| Managers (`mc-manager.sh`, `tt-manager.sh`) | `/usr/local/libexec/crias/` | root:root 0755 | executados via `sudo` — não podem ser graváveis pelo jogo |
| `setup-cron.sh` (wrapper administrativo) | `/usr/local/libexec/crias/` | root:root 0755 | roda como root via manager |
| Libs compartilhadas administrativas | `/usr/local/libexec/crias/lib/` | root:root 0644 | sourced por managers root |
| Scripts de runtime (`start-server.sh`, `backup-cron.sh`) | diretório do servidor | usuário do jogo | executam com o privilégio do próprio jogo |
| `/etc/profile.d/crias-server.sh` | `/etc/profile.d/` | root:root 0644 | aliases ESTÁTICOS — nunca faz `source` de `comandos.sh` no diretório do jogo |

Defesa em profundidade:

- Managers, ao rodar como root, **recusam** executar/ler qualquer script que
  não seja `root:root` sem escrita para grupo/outros (bypass explícito de
  desenvolvimento: `CRIS_MANAGER_ALLOW_UNSAFE=1`).
- O deploy do instalador **remove** as cópias legadas de
  `mc-manager.sh`/`tt-manager.sh`/`setup-cron.sh`/`.shared/manager-common.sh`
  do diretório do jogo (migração automática de instalações antigas).
- O gerador de aliases do perfil global não referencia nenhum caminho dentro
  do diretório do servidor (verificado por `tests/manager-safety-test.sh`).

Contraverificação sugerida em host real:

```bash
sudo -u minecraft test -w /usr/local/libexec/crias/mc-manager.sh   # deve FALHAR
sudo -u minecraft test -w /usr/local/libexec/crias/lib/common.sh   # deve FALHAR
stat -c '%U %G %a %n' /etc/profile.d/crias-server.sh              # root root 644
grep -r 'source.*comandos' /etc/profile.d/crias-server.sh          # vazio
```

## Hardening do agente (crias-agent)

A unit `crias-agent.service` mantém todo o sandbox (`ProtectSystem=strict`,
`MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`, ...) EXCETO o
bounding set de capabilities: um `CapabilityBoundingSet=` vazio sobrevive ao
`exec` e também aos binários setuid — o `/usr/bin/sudo` do agente não
conseguiria recuperar privilégios e TODO controle remoto falharia em
silêncio (CR-02). A fronteira de privilégio real é o sudoers allowlist:
apenas `systemctl <verbo> <jogo>` e os comandos do manager.

O usuário `crias-agent` é adicionado ao grupo `systemd-journal` para que o
`/mc console` (journalctl sem sudo) funcione em hosts com journal restrito
(CR-14). Implicação: o agente pode ler o journal GLOBAL do host — tradeoff
documentado; uma alternativa mais restrita exigiria um helper de journal
dedicado.

O token de autenticação do agente é **reutilizado** em reinstalações
(EXP-44); rotação explícita via `AGENT_ROTATE_TOKEN=true`.

## SSH no host instalado

O drop-in `/etc/ssh/sshd_config.d/10-crias.conf` aplica `PermitRootLogin no`
e **preserva a política de senha existente** (EXP-65): se o host já está
configurado com `PasswordAuthentication no` (key-only), o instalador não
reativa senha. A configuração é validada com `sshd -t` ANTES do restart.

## Integridade e autenticidade da release

O bootstrap valida o SHA-256 dos assets contra o `sha256sums.txt` da MESMA
release. Isso protege contra corrupção/URL intermediária, mas não contra um
atacante que controle os assets da release (checksum e binário vieram da
mesma fonte). Para cadeia de custódia completa, assine o manifesto (cosign/
minisign) ou valide a proveniência do workflow no momento do uso — a
infraestrutura de assinatura ainda não está implementada.

O bootstrap exibe a tag e o commit-alvo da release antes de instalar
(EXP-40). A branch `main` pode estar à frente da release `latest`; para
pinar: `CRIAS_RELEASE_TAG=v2026.11.19-<sha> crias-bootstrap`.

## Diagnóstico sem ampliar privilégios

O comando `sudo crias-tui --doctor` coleta informações de serviços, RAM/swap e mensagens OOM sem modificar unidades ou iniciar o jogo. Para um problema de memória, confira `systemctl show minecraft -p MemoryMax -p MemoryPeak -p MemorySwapMax -p NRestarts` e os logs do kernel antes de editar `MemoryMax`. Não use `chmod 777`, desative o sandbox ou execute o Java como root para contornar erros de permissão.

## Arquivos temporários e snapshots

Scripts que carregam `shared/lib/common.sh` criam arquivos temporários por `mktemp_crias_file` ou `mktemp_crias_dir`. O registro é privado (0600) e a limpeza em `EXIT` só remove caminhos gerados por modelos previamente autorizados; entradas desconhecidas, traversal e links simbólicos são ignorados. Unidades systemd temporárias são publicadas por renomeação atômica no diretório de destino e também registradas.

Em execução privilegiada, `TMPDIR` herdado é ignorado: os temporários comuns são criados em `/tmp`, com nomes aleatórios e permissões restritas. O bootstrap igualmente usa `/tmp` diretamente. Isso evita confiar em diretórios de trabalho controláveis por outros usuários, mas **não substitui** a verificação de origem dos downloads.

Snapshots de reinstalação agora são registrados e removidos mesmo quando a captura falha antes do início das alterações. O rollback precisa ocorrer antes da limpeza de temporários — alterar a ordem do `EXIT trap` pode destruir a cópia de recuperação.

Para investigar resíduos sem apagar dados manualmente:

```bash
sudo find /tmp -maxdepth 1 -name 'crias.*' -printf '%TY-%Tm-%Td %TH:%TM %p\n'
sudo journalctl -u minecraft -n 80 --no-pager
```

Não execute `sudo rm -rf /tmp/crias*` como rotina de manutenção. Confirme o processo proprietário e se existe uma instalação ou restauração ativa antes de remover qualquer arquivo.
