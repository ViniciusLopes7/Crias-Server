#!/bin/bash
# Run inside a disposable Arch VM as root. No third-party game EULA is accepted.
set -euo pipefail
root="${1:?repository path required}"
hub_systemd_test="${2:-}"
# Resumo legivel e logs integrais separados: coletados pelo runner QEMU
# tanto em sucesso quanto em falha. Somente dados sinteticos de teste.
MC_QEMU_LOG_DIR=/tmp/crias-qemu-minecraft
mkdir -p "$MC_QEMU_LOG_DIR"
: > "$MC_QEMU_LOG_DIR/summary.tsv"
mc_ci_event() {
    local kind="$1" scenario="$2" detail="${3:-}"
    printf "[QEMU][MINECRAFT][%s] %s: %s\n" "$kind" "$scenario" "$detail"
    printf "%s\t%s\t%s\n" "$kind" "$scenario" "$detail" >> "$MC_QEMU_LOG_DIR/summary.tsv"
}
mc_ci_preview() {
    local scenario="$1" file="$2" count
    echo "[QEMU][MINECRAFT][RESUMO] $scenario (logs completos no artefato)"
    grep -m 1 "^Java:" "$file" || true
    grep -m 1 -Ei "agree.*eula|eula.*agree" "$file" || true
    count="$(grep -Eci "WARN|WARNING" "$file" || true)"
    printf "[QEMU][MINECRAFT][AVISOS] %s: %s linha(s) contendo WARN/WARNING, sem supressao no arquivo original\n" "$scenario" "$count"
}

[ "$(ps -p 1 -o comm=)" = systemd ] || { echo 'systemd is not PID 1' >&2; exit 1; }
pacman -Syu --noconfirm --needed bash coreutils gettext jq tar zstd zip unzip jdk21-openjdk python
cd "$root"
bash tests/crias-bootstrap-test.sh
bash tests/backup-integrity-test.sh
bash tests/modpack-state-test.sh
bash tests/temp-cleanup-test.sh

# Executa contratos criticos tambem num Arch com systemd real.
echo "[QEMU] Contratos de install, rollback, modpacks, memoria e TUI..."
bash tests/install-contracts.sh
mc_ci_event "ESPERADO" "rollback" "teste injeta falha para validar preservacao de dados"
bash tests/stack-rollback-test.sh
mc_ci_event "PASS" "rollback" "falha intencional detectada; artefatos restaurados"
bash tests/manager-safety-test.sh
bash tests/custom-mrpack-test.sh
bash tests/minecraft-tuning-test.sh
bash tests/minecraft-memory-contract-test.sh
bash tests/minecraft-logs-test.sh
bash tests/minecraft-console-contract-test.sh
bash tests/minecraft-voicechat-test.sh
bash tests/crias-tui-deploy-test.sh
bash tests/hub-gum-test.sh
bash tests/hub-ssh-console-status-test.sh
bash tests/chunky-progress-watch-test.sh
bash tests/minecraft-heap-control-test.sh
bash tests/hub-files-test.sh
bash tests/crias-update-test.sh

# Contraprova funcional do deploy: comando real em /usr/local/bin, permissao
# root:root, modo executavel e --doctor independente de servico instalado.
# shellcheck source=/dev/null
source "$root/install.sh"
DRY_RUN=false
deploy_crias_tui
test -x /usr/local/bin/crias-tui
test "$(stat -c %U:%G /usr/local/bin/crias-tui)" = root:root
/usr/local/bin/crias-tui --doctor > /tmp/crias-tui-doctor.log
grep -q "Diagnostico do Crias-Server" /tmp/crias-tui-doctor.log
echo "PASS: TUI instalado antecipadamente, fallback e doctor no host Arch"
# Testa OpenSSH em Arch real ANTES da instalacao Minecraft. O usuario ci
# ja existe no guest, sem senha nova, e o processo SSH em curso permanece.
INSTALL_SSH=true
SSH_USER=ci
# A conta ci ja tem NOPASSWD via cloud-init. O instalador nao pode
# substituir essa regra por uma politica global de wheel que exige senha.
runuser -u ci -- sudo -n true || { echo 'FAIL: sudo inicial de ci exige senha' >&2; exit 1; }
install_ssh_if_enabled
runuser -u ci -- sudo -n true || { echo 'FAIL: instalacao SSH alterou sudo NOPASSWD da conta ci' >&2; exit 1; }
systemctl is-active --quiet sshd.service
ss -H -ltn 'sport = :22' | grep -q .
echo "PASS: OpenSSH habilitado e porta 22 escutando antes do Minecraft"
# Build a harmless JVM probe and run it through the actual systemd unit and
# production launcher, with the same sandbox and a non-root service account.
useradd -r -M -s /usr/bin/nologin criasvm
server=/opt/crias-qemu-test
mkdir -p "$server/.shared"
cp minecraft/start-server.sh "$server/"
cp shared/lib/*.sh "$server/.shared/"
chmod +x "$server/start-server.sh"
cat > "$server/Probe.java" <<'JAVA'
public class Probe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !"nogui".equals(args[0])) throw new Exception("bad args");
        System.out.println("CRIAS_VM_PROBE_STARTED");
        Thread.sleep(600000);
    }
}
JAVA
javac "$server/Probe.java"
jar --create --file "$server/server.jar" --main-class Probe -C "$server" Probe.class
printf 'server-port=0\n' > "$server/server.properties"
printf 'MINECRAFT_VERSION=1.21.1\nMINECRAFT_LOADER=vanilla\nMIN_RAM=128M\nMAX_RAM=256M\n' > "$server/runtime.env"
chown -R criasvm:criasvm "$server"
# Exercise the actual installer routine, including unit validation and enable.
# shellcheck source=/dev/null
source "$root/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$root/shared/lib/stack-installer.sh"
# Carrega helpers de recalibracao antes dos testes reais de MemoryMax.
# minecraft/install.sh so e carregado mais tarde no teste pre-EULA.
# shellcheck source=/dev/null
source "$root/shared/lib/minecraft-tuning.sh"
STACK_NAME=minecraft
STACK_USER=criasvm
STACK_SERVER_DIR="$server"
STACK_SERVICE_TEMPLATE="$root/minecraft/minecraft.service"
STACK_SERVICE_MEMORY_MAX_MB=512
DRY_RUN=false
install_stack_service
systemd-analyze verify /etc/systemd/system/minecraft.service
mc_ci_event "INICIO" "systemd" "executar JVM inofensiva em usuario sem privilegios"
systemctl start minecraft.service
for i in $(seq 1 30); do
    journalctl -u minecraft.service --no-pager | grep -q CRIAS_VM_PROBE_STARTED && break
    sleep 1
done
systemctl is-active --quiet minecraft.service
journalctl -u minecraft.service --no-pager | grep -q CRIAS_VM_PROBE_STARTED
# Teste do isolamento e dos limites reais da unit gerada.
[ "$(systemctl show -p User --value minecraft.service)" = criasvm ]
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 536870912 ]
[ "$(systemctl show -p MemorySwapMax --value minecraft.service)" = 536870912 ]
[ "$(systemctl show -p MemoryHigh --value minecraft.service)" = 509607936 ]
[ "$(systemctl show -p NoNewPrivileges --value minecraft.service)" = yes ]
[ "$(systemctl show -p OOMScoreAdjust --value minecraft.service)" = 200 ]
[ "$(systemctl show -p Restart --value minecraft.service)" = no ]
[ "$(systemctl show -p StartLimitBurst --value minecraft.service)" = 3 ]
systemctl cat minecraft.service | grep -q "^StartLimitIntervalSec=300s$"
systemctl cat minecraft.service | grep -q "^OOMPolicy=stop$"
systemctl cat minecraft.service | grep -q '^MemoryHigh='
server_pid="$(systemctl show -p MainPID --value minecraft.service)"
[ "$server_pid" -gt 1 ]
[ "$(ps -o user= -p "$server_pid" | xargs)" = criasvm ]
echo "PASS: unit systemd real isolada, sem root e com limites aplicados"
mc_ci_event "PASS" "systemd" "servico como criasvm e MemoryMax/MemorySwapMax aplicados"
if [ -n "$hub_systemd_test" ]; then
    test -x "$hub_systemd_test"
    runuser -u ci -- env CRIAS_HUB_REAL_SYSTEMD=active "$hub_systemd_test" -test.run '^TestRealSystemdReadOnly
# A recalibracao NAO pode alterar MemoryMax com a JVM ativa.
if CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW >/tmp/crias-memory-active-test.log 2>&1; then
    echo "FAIL: reconfigure-hardware aceitou alterar RAM com JVM ativa" >&2
    exit 1
fi
grep -q "completamente parado" /tmp/crias-memory-active-test.log
systemctl stop minecraft.service
if [ -n "$hub_systemd_test" ]; then
    runuser -u ci -- env CRIAS_HUB_REAL_SYSTEMD=inactive "$hub_systemd_test" -test.run '^TestRealSystemdReadOnly! systemctl is-active --quiet minecraft.service
# Valide o limite persistente de memoria usando systemd real e drop-in.
write_minecraft_systemd_memory_limit 640
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 671088640 ]
write_minecraft_systemd_memory_limit 768
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 805306368 ]
echo "PASS: MemoryMax sincronizado via drop-in e validado pelo systemd real"
# Integre a reconfiguracao de ponta a ponta (manager -> env -> systemd).
CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW > /tmp/crias-mc-memory-reconfig.log 2>&1 || {
        cat /tmp/crias-mc-memory-reconfig.log >&2
        echo "FAIL: manager nao sincronizou heap/MemoryMax" >&2
        exit 1
    }
configured_mb="$(sed -n 's/^MC_SERVICE_MEMORY_MAX_MB="\([0-9][0-9]*\)"$/\1/p' "$server/hardware-profile.env")"
[ -n "$configured_mb" ]
[ "$(systemctl show minecraft.service -p MemoryMax --value)" = "$((configured_mb * 1048576))" ]
grep -q "^NATIVE_OVERHEAD_MB=" "$server/runtime.env"
grep -qx 'MINECRAFT_LOADER="vanilla"' "$server/runtime.env"
echo "PASS: manager recalibrou RAM com unit parada e sincronizou Xmx/MemoryMax"
mc_ci_event "PASS" "reconfigure-memory" "manager validou limites efetivos no systemd"

# Injeta OOM isolado para validar a observabilidade de falha de cgroup.
# Nao altera a unit do jogo; a VM e descartavel e nao aceita EULA.
cat > /etc/systemd/system/crias-oom-test.service <<EOF
[Unit]
Description=Crias CI OOM fault injection
[Service]
Type=simple
User=criasvm
WorkingDirectory=/opt/crias-qemu-test
ExecStart=/usr/bin/java -Xms256m -Xmx256m -XX:+AlwaysPreTouch -cp /opt/crias-qemu-test Probe nogui
MemoryMax=64M
MemorySwapMax=0
OOMPolicy=stop
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "oom-injetado" "limite artificial de 64 MB; nao e o Minecraft de producao"
systemctl start crias-oom-test.service
oom_result=""
for i in $(seq 1 40); do
    oom_result="$(systemctl show -p Result --value crias-oom-test.service)"
    [ "$oom_result" = "oom-kill" ] && break
    if ! systemctl is-active --quiet crias-oom-test.service; then break; fi
    sleep 1
done
if [ "$oom_result" != "oom-kill" ]; then
    systemctl status crias-oom-test.service --no-pager -l >&2 || true
    journalctl -u crias-oom-test.service --no-pager >&2 || true
    echo "FAIL: cgroup OOM nao foi detectado como oom-kill ($oom_result)" >&2
    exit 1
fi
echo "PASS: fault injection OOM marcado corretamente pelo systemd"
mc_ci_event "PASS" "oom-injetado" "systemd identificou oom-kill na unidade descartavel"
# Contraprova: depois de falha artificial, o servico DESCARTAVEL
# permanece parado. Reinicios manuais regulares nao ficam bloqueados por
# um contador vitalicio.
cat > /etc/systemd/system/crias-restart-test.service <<'EOF'
[Unit]
Description=Crias CI fail-closed restart check
StartLimitIntervalSec=300s
StartLimitBurst=3
[Service]
Type=simple
ExecStart=/usr/bin/false
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "restart-injetado" "falha artificial sem reinicio automatico"
systemctl start crias-restart-test.service >/dev/null 2>&1 || true
restart_result=""
for i in $(seq 1 10); do
    restart_result="$(systemctl show -p Result --value crias-restart-test.service)"
    [ "$restart_result" = "exit-code" ] && break
    sleep 1
done
[ "$restart_result" = "exit-code" ] || {
    echo "FAIL: falha artificial nao reportada como exit-code ($restart_result)" >&2
    exit 1
}
before_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
sleep 3
after_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
[ "$before_restarts" = 0 ] && [ "$after_restarts" = 0 ] || {
    echo "FAIL: falha provocou reinicio automatico ($before_restarts -> $after_restarts)" >&2
    exit 1
}
mc_ci_event "PASS" "restart-injetado" "servico parou na falha sem novos starts"

# Install in a fresh shell so Minecraft hook functions cannot leak into Terraria.
env TERRARIA_SERVER_DIR=/opt/terraria-server TERRARIA_USER=terraria \
    TERRARIA_USE_TMODLOADER=false FORCE_HARDWARE_TIER=LOW \
    APPLY_SYSTEM_TUNING=false DRY_RUN=false \
    bash -c 'set -euo pipefail; source "$1"; run_stack_install' _ "$root/terraria/install.sh" 2>&1 | tee /tmp/crias-terraria-install.log
if grep -Eq 'safe_remove_dir recebeu caminho invalido|Diretorio temporario nao reconhecido|Diretorio temporario nao registrado' /tmp/crias-terraria-install.log; then
    echo 'FAIL: Terraria installer rejected its own temporary directory' >&2
    exit 1
fi
systemctl start terraria.service
ready=false
for i in $(seq 1 180); do
    if ss -H -ltn 'sport = :7777' | grep -q .; then ready=true; break; fi
    if systemctl is-failed --quiet terraria.service; then break; fi
    sleep 2
done
if [ "$ready" != true ]; then
    journalctl -u terraria.service --no-pager >&2
    echo 'FAIL: Terraria did not listen on port 7777' >&2
    exit 1
fi
systemctl stop terraria.service
echo 'PASS: real Terraria stack installed and opened its game port'

# C00: observational baseline against the installed legacy Hub, with real
# Arch/systemd discovery as the unprivileged ci account. Both stacks are
# stopped or use disposable fixtures; no game workload or Gum is measured.
# The harness intercepts administrative calls, including automatic package
# recovery. Report in guest.log (already retained by the QEMU workflow).
echo '[QEMU] C00 baseline: installed numeric Hub, real systemd, unprivileged'
test "$(id -u ci)" -ne 0
runuser -u ci -- python3 "$root/tools/hub-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 \
    > /tmp/crias-qemu-hub-baseline.json
python3 - /tmp/crias-qemu-hub-baseline.json <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
if report["mode"] != "host" or report["startup_ms"]["count"] != 30 or report["navigation_ms"]["count"] != 60:
    raise SystemExit("unexpected C00 host benchmark report")
print("HUB_BASELINE_ARCH_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 installed Hub numeric PTY baseline (Arch VM; timings observational)'

# Real Gum is needed only inside the disposable VM, not on production hosts.
# All samples run unprivileged and refuse fallback/unknown screens.
pacman -S --needed --noconfirm gum
for stack in minecraft terraria; do
    runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
        --mode fixture --stack "$stack" --samples 3 --idle-seconds 2 \
        > "/tmp/crias-qemu-gum-${stack}.json"
done
runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 --idle-seconds 5 \
    > /tmp/crias-qemu-gum-host.json
python3 - /tmp/crias-qemu-gum-minecraft.json /tmp/crias-qemu-gum-terraria.json /tmp/crias-qemu-gum-host.json <<'PY'
import json
import sys
for path, mode, count in zip(sys.argv[1:], ("fixture", "fixture", "host"), (3, 3, 30)):
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
    if report["mode"] != mode or report["startup_ms"]["count"] != count or report["navigation_ms"]["count"] != 2*count:
        raise SystemExit("unexpected Gum benchmark report")
    print("HUB_BASELINE_GUM_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 real Gum controlling PTY benchmark (Arch VM; timings observational)'



# Exercise the real Minecraft downloader and launcher up to the EULA prompt.
# The test keeps eula=false and does not create or play a Minecraft world.
# shellcheck source=/dev/null
source "$root/minecraft/install.sh"
DRY_RUN=false
MRPACK_INSTALL_VERSION=v0.23.0
install_mrpack_install
for loader in vanilla fabric quilt forge neoforge; do
    mc_ci_event "INICIO" "$loader-1.21.1" "instalacao real do loader; EULA permanece false"
    real_server="/opt/crias-real-${loader}"
    mkdir -p "$real_server/.shared"
    cp "$root"/shared/lib/*.sh "$real_server/.shared/"
    MINECRAFT_SERVER_DIR="$real_server"
    MINECRAFT_LOADER="$loader"
    MINECRAFT_VERSION=1.21.1
    _install_minecraft_server_base
    printf 'eula=false\n' > "$real_server/eula.txt"
    printf 'server-port=0\n' > "$real_server/server.properties"
    printf 'MINECRAFT_VERSION=1.21.1\nMINECRAFT_LOADER=%s\nMIN_RAM=128M\nMAX_RAM=512M\n' "$loader" > "$real_server/runtime.env"
    chown -R criasvm:criasvm "$real_server"
    set +e
    timeout 180 runuser -u criasvm -- env SERVER_DIR="$real_server" bash "$root/minecraft/start-server.sh" > "$real_server/output.log" 2>&1
    status=$?
    set -e
    cp "$real_server/output.log" "$MC_QEMU_LOG_DIR/${loader}-1.21.1.log"
    if [ "$status" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$real_server/output.log"; then
        mc_ci_event "FALHA" "$loader-1.21.1" "nao chegou ao prompt EULA; codigo=$status"
        tail -n 100 "$real_server/output.log" >&2
        exit 1
    fi
    grep -qx "eula=false" "$real_server/eula.txt"
    mc_ci_preview "$loader-1.21.1" "$real_server/output.log"
    mc_ci_event "PASS" "$loader-1.21.1" "Java iniciou o loader real e chegou a EULA; status=$status"
    echo "PASS: real $loader server reached EULA prompt without acceptance"
done



# Contraprova especifica do modpack CriasRealms (Forge 1.20.1 / Java 17).
# Os testes acima executam 1.21.1. Aqui verificamos a versao antiga do loader
# com Java 17 de verdade, incluindo a escolha automatica do binario correto.
# O teste termina na EULA: nao ha aceitacao, criacao de mundo ou multiplayer.
mc_ci_event "INICIO" "forge-1.20.1" "Forge real + Java 17; EULA permanece false"
pacman -S --needed --noconfirm jdk17-openjdk
forge1201_dir=/opt/crias-real-forge-1201
mkdir -p "$forge1201_dir/.shared"
cp "$root"/shared/lib/*.sh "$forge1201_dir/.shared/"
MINECRAFT_SERVER_DIR="$forge1201_dir"
MINECRAFT_LOADER=forge
MINECRAFT_VERSION=1.20.1
_install_minecraft_server_base
printf "eula=false\n" > "$forge1201_dir/eula.txt"
printf "server-port=0\n" > "$forge1201_dir/server.properties"
printf "MINECRAFT_VERSION=1.20.1\nMINECRAFT_LOADER=forge\nMIN_RAM=128M\nMAX_RAM=512M\n" > "$forge1201_dir/runtime.env"
chown -R criasvm:criasvm "$forge1201_dir"
set +e
timeout 240 runuser -u criasvm -- env SERVER_DIR="$forge1201_dir" bash "$root/minecraft/start-server.sh" > "$forge1201_dir/output.log" 2>&1
forge1201_rc=$?
set -e
cp "$forge1201_dir/output.log" "$MC_QEMU_LOG_DIR/forge-1.20.1.log"
if [ "$forge1201_rc" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Forge nao chegou a EULA; codigo=$forge1201_rc"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
if ! grep -Eq 'Java: .*"17[.]' "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Java selecionado nao e 17"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
grep -qx "eula=false" "$forge1201_dir/eula.txt"
mc_ci_preview "forge-1.20.1" "$forge1201_dir/output.log"
mc_ci_event "PASS" "forge-1.20.1" "Java 17 confirmado; EULA nao aceita; codigo=$forge1201_rc"
echo "PASS: Minecraft Forge 1.20.1 iniciou com Java 17 e chegou a EULA sem aceitar"
# Real mrpack-install with a locally generated personal pack (no EULA accepted).
pack_dir="/tmp/personal-pack-fixture"
mkdir -p "$pack_dir/server-overrides/config" /opt/crias-custom-pack
printf '%s\n' '{"formatVersion":1,"game":"minecraft","versionId":"test","name":"Personal","files":[],"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"}}' > "$pack_dir/modrinth.index.json"
printf 'fixture=ok\n' > "$pack_dir/server-overrides/config/personal.txt"
(cd "$pack_dir" && zip -qr '/tmp/personal pack.mrpack' modrinth.index.json server-overrides)
_validate_custom_mrpack '/tmp/personal pack.mrpack'
mc_ci_event "INICIO" "mrpack-local" "pacote sintetico sem dependencias remotas; resposta Modrinth 404 nao invalida o teste"
timeout 300 mrpack-install '/tmp/personal pack.mrpack' --server-dir /opt/crias-custom-pack --server-file server.jar 2>&1 | tee "$MC_QEMU_LOG_DIR/mrpack-local.log"
grep -qx 'fixture=ok' /opt/crias-custom-pack/config/personal.txt
MINECRAFT_SERVER_DIR=/opt/crias-custom-pack
_resolve_modpack_effective_versions
[ "$MC_EFFECTIVE_VERSION" = 1.21.1 ] && [ "$MINECRAFT_LOADER" = fabric ]
mc_ci_event "PASS" "mrpack-local" "arquivo e overrides importados, loader/versao reconhecidos"
echo 'PASS: real mrpack-install imported personal local archive and server overrides'

# Download real optional mods for Forge 1.20.1 and verify duplicate detection.
MINECRAFT_SERVER_DIR=/opt/crias-extra-test
MINECRAFT_LOADER=forge
MC_EFFECTIVE_VERSION=1.20.1
mc_ci_event "INICIO" "extras-forge-1.20.1" "download de tres mods opcionais e deteccao de duplicatas"
MINECRAFT_EXTRA_MODS=skinrestorer,spark,chunky
MINECRAFT_PENDING_MODS=()
stack_install_extra_mods
[ "${#MINECRAFT_PENDING_MODS[@]}" -eq 0 ]
for mod in skinrestorer spark chunky; do unzip -tq "$MINECRAFT_SERVER_DIR/mods/$mod.jar" >/dev/null; done
mv "$MINECRAFT_SERVER_DIR/mods/spark.jar" "$MINECRAFT_SERVER_DIR/mods/spark-versioned.jar"
stack_install_extra_mods
[ ! -e "$MINECRAFT_SERVER_DIR/mods/spark.jar" ]
mc_ci_event "PASS" "extras-forge-1.20.1" "jars validados; duplicata spark evitada"
echo 'PASS: real Forge 1.20.1 server extras downloaded and duplicates avoided'


echo "[QEMU][MINECRAFT][RESUMO-FINAL] Resultados por cenario:"
cat "$MC_QEMU_LOG_DIR/summary.tsv"
echo "PASS: Arch VM, systemd PID 1, real service installer, backup restore, bootstrap and real server pre-EULA launch"
 -test.v -test.timeout=20s
fi
# A recalibracao NAO pode alterar MemoryMax com a JVM ativa.
if CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW >/tmp/crias-memory-active-test.log 2>&1; then
    echo "FAIL: reconfigure-hardware aceitou alterar RAM com JVM ativa" >&2
    exit 1
fi
grep -q "completamente parado" /tmp/crias-memory-active-test.log
systemctl stop minecraft.service
! systemctl is-active --quiet minecraft.service
# Valide o limite persistente de memoria usando systemd real e drop-in.
write_minecraft_systemd_memory_limit 640
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 671088640 ]
write_minecraft_systemd_memory_limit 768
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 805306368 ]
echo "PASS: MemoryMax sincronizado via drop-in e validado pelo systemd real"
# Integre a reconfiguracao de ponta a ponta (manager -> env -> systemd).
CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW > /tmp/crias-mc-memory-reconfig.log 2>&1 || {
        cat /tmp/crias-mc-memory-reconfig.log >&2
        echo "FAIL: manager nao sincronizou heap/MemoryMax" >&2
        exit 1
    }
configured_mb="$(sed -n 's/^MC_SERVICE_MEMORY_MAX_MB="\([0-9][0-9]*\)"$/\1/p' "$server/hardware-profile.env")"
[ -n "$configured_mb" ]
[ "$(systemctl show minecraft.service -p MemoryMax --value)" = "$((configured_mb * 1048576))" ]
grep -q "^NATIVE_OVERHEAD_MB=" "$server/runtime.env"
grep -qx 'MINECRAFT_LOADER="vanilla"' "$server/runtime.env"
echo "PASS: manager recalibrou RAM com unit parada e sincronizou Xmx/MemoryMax"
mc_ci_event "PASS" "reconfigure-memory" "manager validou limites efetivos no systemd"

# Injeta OOM isolado para validar a observabilidade de falha de cgroup.
# Nao altera a unit do jogo; a VM e descartavel e nao aceita EULA.
cat > /etc/systemd/system/crias-oom-test.service <<EOF
[Unit]
Description=Crias CI OOM fault injection
[Service]
Type=simple
User=criasvm
WorkingDirectory=/opt/crias-qemu-test
ExecStart=/usr/bin/java -Xms256m -Xmx256m -XX:+AlwaysPreTouch -cp /opt/crias-qemu-test Probe nogui
MemoryMax=64M
MemorySwapMax=0
OOMPolicy=stop
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "oom-injetado" "limite artificial de 64 MB; nao e o Minecraft de producao"
systemctl start crias-oom-test.service
oom_result=""
for i in $(seq 1 40); do
    oom_result="$(systemctl show -p Result --value crias-oom-test.service)"
    [ "$oom_result" = "oom-kill" ] && break
    if ! systemctl is-active --quiet crias-oom-test.service; then break; fi
    sleep 1
done
if [ "$oom_result" != "oom-kill" ]; then
    systemctl status crias-oom-test.service --no-pager -l >&2 || true
    journalctl -u crias-oom-test.service --no-pager >&2 || true
    echo "FAIL: cgroup OOM nao foi detectado como oom-kill ($oom_result)" >&2
    exit 1
fi
echo "PASS: fault injection OOM marcado corretamente pelo systemd"
mc_ci_event "PASS" "oom-injetado" "systemd identificou oom-kill na unidade descartavel"
# Contraprova: depois de falha artificial, o servico DESCARTAVEL
# permanece parado. Reinicios manuais regulares nao ficam bloqueados por
# um contador vitalicio.
cat > /etc/systemd/system/crias-restart-test.service <<'EOF'
[Unit]
Description=Crias CI fail-closed restart check
StartLimitIntervalSec=300s
StartLimitBurst=3
[Service]
Type=simple
ExecStart=/usr/bin/false
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "restart-injetado" "falha artificial sem reinicio automatico"
systemctl start crias-restart-test.service >/dev/null 2>&1 || true
restart_result=""
for i in $(seq 1 10); do
    restart_result="$(systemctl show -p Result --value crias-restart-test.service)"
    [ "$restart_result" = "exit-code" ] && break
    sleep 1
done
[ "$restart_result" = "exit-code" ] || {
    echo "FAIL: falha artificial nao reportada como exit-code ($restart_result)" >&2
    exit 1
}
before_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
sleep 3
after_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
[ "$before_restarts" = 0 ] && [ "$after_restarts" = 0 ] || {
    echo "FAIL: falha provocou reinicio automatico ($before_restarts -> $after_restarts)" >&2
    exit 1
}
mc_ci_event "PASS" "restart-injetado" "servico parou na falha sem novos starts"

# Install in a fresh shell so Minecraft hook functions cannot leak into Terraria.
env TERRARIA_SERVER_DIR=/opt/terraria-server TERRARIA_USER=terraria \
    TERRARIA_USE_TMODLOADER=false FORCE_HARDWARE_TIER=LOW \
    APPLY_SYSTEM_TUNING=false DRY_RUN=false \
    bash -c 'set -euo pipefail; source "$1"; run_stack_install' _ "$root/terraria/install.sh" 2>&1 | tee /tmp/crias-terraria-install.log
if grep -Eq 'safe_remove_dir recebeu caminho invalido|Diretorio temporario nao reconhecido|Diretorio temporario nao registrado' /tmp/crias-terraria-install.log; then
    echo 'FAIL: Terraria installer rejected its own temporary directory' >&2
    exit 1
fi
systemctl start terraria.service
ready=false
for i in $(seq 1 180); do
    if ss -H -ltn 'sport = :7777' | grep -q .; then ready=true; break; fi
    if systemctl is-failed --quiet terraria.service; then break; fi
    sleep 2
done
if [ "$ready" != true ]; then
    journalctl -u terraria.service --no-pager >&2
    echo 'FAIL: Terraria did not listen on port 7777' >&2
    exit 1
fi
systemctl stop terraria.service
echo 'PASS: real Terraria stack installed and opened its game port'

# C00: observational baseline against the installed legacy Hub, with real
# Arch/systemd discovery as the unprivileged ci account. Both stacks are
# stopped or use disposable fixtures; no game workload or Gum is measured.
# The harness intercepts administrative calls, including automatic package
# recovery. Report in guest.log (already retained by the QEMU workflow).
echo '[QEMU] C00 baseline: installed numeric Hub, real systemd, unprivileged'
test "$(id -u ci)" -ne 0
runuser -u ci -- python3 "$root/tools/hub-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 \
    > /tmp/crias-qemu-hub-baseline.json
python3 - /tmp/crias-qemu-hub-baseline.json <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
if report["mode"] != "host" or report["startup_ms"]["count"] != 30 or report["navigation_ms"]["count"] != 60:
    raise SystemExit("unexpected C00 host benchmark report")
print("HUB_BASELINE_ARCH_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 installed Hub numeric PTY baseline (Arch VM; timings observational)'

# Real Gum is needed only inside the disposable VM, not on production hosts.
# All samples run unprivileged and refuse fallback/unknown screens.
pacman -S --needed --noconfirm gum
for stack in minecraft terraria; do
    runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
        --mode fixture --stack "$stack" --samples 3 --idle-seconds 2 \
        > "/tmp/crias-qemu-gum-${stack}.json"
done
runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 --idle-seconds 5 \
    > /tmp/crias-qemu-gum-host.json
python3 - /tmp/crias-qemu-gum-minecraft.json /tmp/crias-qemu-gum-terraria.json /tmp/crias-qemu-gum-host.json <<'PY'
import json
import sys
for path, mode, count in zip(sys.argv[1:], ("fixture", "fixture", "host"), (3, 3, 30)):
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
    if report["mode"] != mode or report["startup_ms"]["count"] != count or report["navigation_ms"]["count"] != 2*count:
        raise SystemExit("unexpected Gum benchmark report")
    print("HUB_BASELINE_GUM_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 real Gum controlling PTY benchmark (Arch VM; timings observational)'



# Exercise the real Minecraft downloader and launcher up to the EULA prompt.
# The test keeps eula=false and does not create or play a Minecraft world.
# shellcheck source=/dev/null
source "$root/minecraft/install.sh"
DRY_RUN=false
MRPACK_INSTALL_VERSION=v0.23.0
install_mrpack_install
for loader in vanilla fabric quilt forge neoforge; do
    mc_ci_event "INICIO" "$loader-1.21.1" "instalacao real do loader; EULA permanece false"
    real_server="/opt/crias-real-${loader}"
    mkdir -p "$real_server/.shared"
    cp "$root"/shared/lib/*.sh "$real_server/.shared/"
    MINECRAFT_SERVER_DIR="$real_server"
    MINECRAFT_LOADER="$loader"
    MINECRAFT_VERSION=1.21.1
    _install_minecraft_server_base
    printf 'eula=false\n' > "$real_server/eula.txt"
    printf 'server-port=0\n' > "$real_server/server.properties"
    printf 'MINECRAFT_VERSION=1.21.1\nMINECRAFT_LOADER=%s\nMIN_RAM=128M\nMAX_RAM=512M\n' "$loader" > "$real_server/runtime.env"
    chown -R criasvm:criasvm "$real_server"
    set +e
    timeout 180 runuser -u criasvm -- env SERVER_DIR="$real_server" bash "$root/minecraft/start-server.sh" > "$real_server/output.log" 2>&1
    status=$?
    set -e
    cp "$real_server/output.log" "$MC_QEMU_LOG_DIR/${loader}-1.21.1.log"
    if [ "$status" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$real_server/output.log"; then
        mc_ci_event "FALHA" "$loader-1.21.1" "nao chegou ao prompt EULA; codigo=$status"
        tail -n 100 "$real_server/output.log" >&2
        exit 1
    fi
    grep -qx "eula=false" "$real_server/eula.txt"
    mc_ci_preview "$loader-1.21.1" "$real_server/output.log"
    mc_ci_event "PASS" "$loader-1.21.1" "Java iniciou o loader real e chegou a EULA; status=$status"
    echo "PASS: real $loader server reached EULA prompt without acceptance"
done



# Contraprova especifica do modpack CriasRealms (Forge 1.20.1 / Java 17).
# Os testes acima executam 1.21.1. Aqui verificamos a versao antiga do loader
# com Java 17 de verdade, incluindo a escolha automatica do binario correto.
# O teste termina na EULA: nao ha aceitacao, criacao de mundo ou multiplayer.
mc_ci_event "INICIO" "forge-1.20.1" "Forge real + Java 17; EULA permanece false"
pacman -S --needed --noconfirm jdk17-openjdk
forge1201_dir=/opt/crias-real-forge-1201
mkdir -p "$forge1201_dir/.shared"
cp "$root"/shared/lib/*.sh "$forge1201_dir/.shared/"
MINECRAFT_SERVER_DIR="$forge1201_dir"
MINECRAFT_LOADER=forge
MINECRAFT_VERSION=1.20.1
_install_minecraft_server_base
printf "eula=false\n" > "$forge1201_dir/eula.txt"
printf "server-port=0\n" > "$forge1201_dir/server.properties"
printf "MINECRAFT_VERSION=1.20.1\nMINECRAFT_LOADER=forge\nMIN_RAM=128M\nMAX_RAM=512M\n" > "$forge1201_dir/runtime.env"
chown -R criasvm:criasvm "$forge1201_dir"
set +e
timeout 240 runuser -u criasvm -- env SERVER_DIR="$forge1201_dir" bash "$root/minecraft/start-server.sh" > "$forge1201_dir/output.log" 2>&1
forge1201_rc=$?
set -e
cp "$forge1201_dir/output.log" "$MC_QEMU_LOG_DIR/forge-1.20.1.log"
if [ "$forge1201_rc" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Forge nao chegou a EULA; codigo=$forge1201_rc"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
if ! grep -Eq 'Java: .*"17[.]' "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Java selecionado nao e 17"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
grep -qx "eula=false" "$forge1201_dir/eula.txt"
mc_ci_preview "forge-1.20.1" "$forge1201_dir/output.log"
mc_ci_event "PASS" "forge-1.20.1" "Java 17 confirmado; EULA nao aceita; codigo=$forge1201_rc"
echo "PASS: Minecraft Forge 1.20.1 iniciou com Java 17 e chegou a EULA sem aceitar"
# Real mrpack-install with a locally generated personal pack (no EULA accepted).
pack_dir="/tmp/personal-pack-fixture"
mkdir -p "$pack_dir/server-overrides/config" /opt/crias-custom-pack
printf '%s\n' '{"formatVersion":1,"game":"minecraft","versionId":"test","name":"Personal","files":[],"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"}}' > "$pack_dir/modrinth.index.json"
printf 'fixture=ok\n' > "$pack_dir/server-overrides/config/personal.txt"
(cd "$pack_dir" && zip -qr '/tmp/personal pack.mrpack' modrinth.index.json server-overrides)
_validate_custom_mrpack '/tmp/personal pack.mrpack'
mc_ci_event "INICIO" "mrpack-local" "pacote sintetico sem dependencias remotas; resposta Modrinth 404 nao invalida o teste"
timeout 300 mrpack-install '/tmp/personal pack.mrpack' --server-dir /opt/crias-custom-pack --server-file server.jar 2>&1 | tee "$MC_QEMU_LOG_DIR/mrpack-local.log"
grep -qx 'fixture=ok' /opt/crias-custom-pack/config/personal.txt
MINECRAFT_SERVER_DIR=/opt/crias-custom-pack
_resolve_modpack_effective_versions
[ "$MC_EFFECTIVE_VERSION" = 1.21.1 ] && [ "$MINECRAFT_LOADER" = fabric ]
mc_ci_event "PASS" "mrpack-local" "arquivo e overrides importados, loader/versao reconhecidos"
echo 'PASS: real mrpack-install imported personal local archive and server overrides'

# Download real optional mods for Forge 1.20.1 and verify duplicate detection.
MINECRAFT_SERVER_DIR=/opt/crias-extra-test
MINECRAFT_LOADER=forge
MC_EFFECTIVE_VERSION=1.20.1
mc_ci_event "INICIO" "extras-forge-1.20.1" "download de tres mods opcionais e deteccao de duplicatas"
MINECRAFT_EXTRA_MODS=skinrestorer,spark,chunky
MINECRAFT_PENDING_MODS=()
stack_install_extra_mods
[ "${#MINECRAFT_PENDING_MODS[@]}" -eq 0 ]
for mod in skinrestorer spark chunky; do unzip -tq "$MINECRAFT_SERVER_DIR/mods/$mod.jar" >/dev/null; done
mv "$MINECRAFT_SERVER_DIR/mods/spark.jar" "$MINECRAFT_SERVER_DIR/mods/spark-versioned.jar"
stack_install_extra_mods
[ ! -e "$MINECRAFT_SERVER_DIR/mods/spark.jar" ]
mc_ci_event "PASS" "extras-forge-1.20.1" "jars validados; duplicata spark evitada"
echo 'PASS: real Forge 1.20.1 server extras downloaded and duplicates avoided'


echo "[QEMU][MINECRAFT][RESUMO-FINAL] Resultados por cenario:"
cat "$MC_QEMU_LOG_DIR/summary.tsv"
echo "PASS: Arch VM, systemd PID 1, real service installer, backup restore, bootstrap and real server pre-EULA launch"
 -test.v -test.timeout=20s
fi
! systemctl is-active --quiet minecraft.service
# Valide o limite persistente de memoria usando systemd real e drop-in.
write_minecraft_systemd_memory_limit 640
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 671088640 ]
write_minecraft_systemd_memory_limit 768
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 805306368 ]
echo "PASS: MemoryMax sincronizado via drop-in e validado pelo systemd real"
# Integre a reconfiguracao de ponta a ponta (manager -> env -> systemd).
CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW > /tmp/crias-mc-memory-reconfig.log 2>&1 || {
        cat /tmp/crias-mc-memory-reconfig.log >&2
        echo "FAIL: manager nao sincronizou heap/MemoryMax" >&2
        exit 1
    }
configured_mb="$(sed -n 's/^MC_SERVICE_MEMORY_MAX_MB="\([0-9][0-9]*\)"$/\1/p' "$server/hardware-profile.env")"
[ -n "$configured_mb" ]
[ "$(systemctl show minecraft.service -p MemoryMax --value)" = "$((configured_mb * 1048576))" ]
grep -q "^NATIVE_OVERHEAD_MB=" "$server/runtime.env"
grep -qx 'MINECRAFT_LOADER="vanilla"' "$server/runtime.env"
echo "PASS: manager recalibrou RAM com unit parada e sincronizou Xmx/MemoryMax"
mc_ci_event "PASS" "reconfigure-memory" "manager validou limites efetivos no systemd"

# Injeta OOM isolado para validar a observabilidade de falha de cgroup.
# Nao altera a unit do jogo; a VM e descartavel e nao aceita EULA.
cat > /etc/systemd/system/crias-oom-test.service <<EOF
[Unit]
Description=Crias CI OOM fault injection
[Service]
Type=simple
User=criasvm
WorkingDirectory=/opt/crias-qemu-test
ExecStart=/usr/bin/java -Xms256m -Xmx256m -XX:+AlwaysPreTouch -cp /opt/crias-qemu-test Probe nogui
MemoryMax=64M
MemorySwapMax=0
OOMPolicy=stop
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "oom-injetado" "limite artificial de 64 MB; nao e o Minecraft de producao"
systemctl start crias-oom-test.service
oom_result=""
for i in $(seq 1 40); do
    oom_result="$(systemctl show -p Result --value crias-oom-test.service)"
    [ "$oom_result" = "oom-kill" ] && break
    if ! systemctl is-active --quiet crias-oom-test.service; then break; fi
    sleep 1
done
if [ "$oom_result" != "oom-kill" ]; then
    systemctl status crias-oom-test.service --no-pager -l >&2 || true
    journalctl -u crias-oom-test.service --no-pager >&2 || true
    echo "FAIL: cgroup OOM nao foi detectado como oom-kill ($oom_result)" >&2
    exit 1
fi
echo "PASS: fault injection OOM marcado corretamente pelo systemd"
mc_ci_event "PASS" "oom-injetado" "systemd identificou oom-kill na unidade descartavel"
# Contraprova: depois de falha artificial, o servico DESCARTAVEL
# permanece parado. Reinicios manuais regulares nao ficam bloqueados por
# um contador vitalicio.
cat > /etc/systemd/system/crias-restart-test.service <<'EOF'
[Unit]
Description=Crias CI fail-closed restart check
StartLimitIntervalSec=300s
StartLimitBurst=3
[Service]
Type=simple
ExecStart=/usr/bin/false
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "restart-injetado" "falha artificial sem reinicio automatico"
systemctl start crias-restart-test.service >/dev/null 2>&1 || true
restart_result=""
for i in $(seq 1 10); do
    restart_result="$(systemctl show -p Result --value crias-restart-test.service)"
    [ "$restart_result" = "exit-code" ] && break
    sleep 1
done
[ "$restart_result" = "exit-code" ] || {
    echo "FAIL: falha artificial nao reportada como exit-code ($restart_result)" >&2
    exit 1
}
before_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
sleep 3
after_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
[ "$before_restarts" = 0 ] && [ "$after_restarts" = 0 ] || {
    echo "FAIL: falha provocou reinicio automatico ($before_restarts -> $after_restarts)" >&2
    exit 1
}
mc_ci_event "PASS" "restart-injetado" "servico parou na falha sem novos starts"

# Install in a fresh shell so Minecraft hook functions cannot leak into Terraria.
env TERRARIA_SERVER_DIR=/opt/terraria-server TERRARIA_USER=terraria \
    TERRARIA_USE_TMODLOADER=false FORCE_HARDWARE_TIER=LOW \
    APPLY_SYSTEM_TUNING=false DRY_RUN=false \
    bash -c 'set -euo pipefail; source "$1"; run_stack_install' _ "$root/terraria/install.sh" 2>&1 | tee /tmp/crias-terraria-install.log
if grep -Eq 'safe_remove_dir recebeu caminho invalido|Diretorio temporario nao reconhecido|Diretorio temporario nao registrado' /tmp/crias-terraria-install.log; then
    echo 'FAIL: Terraria installer rejected its own temporary directory' >&2
    exit 1
fi
systemctl start terraria.service
ready=false
for i in $(seq 1 180); do
    if ss -H -ltn 'sport = :7777' | grep -q .; then ready=true; break; fi
    if systemctl is-failed --quiet terraria.service; then break; fi
    sleep 2
done
if [ "$ready" != true ]; then
    journalctl -u terraria.service --no-pager >&2
    echo 'FAIL: Terraria did not listen on port 7777' >&2
    exit 1
fi
systemctl stop terraria.service
echo 'PASS: real Terraria stack installed and opened its game port'

# C00: observational baseline against the installed legacy Hub, with real
# Arch/systemd discovery as the unprivileged ci account. Both stacks are
# stopped or use disposable fixtures; no game workload or Gum is measured.
# The harness intercepts administrative calls, including automatic package
# recovery. Report in guest.log (already retained by the QEMU workflow).
echo '[QEMU] C00 baseline: installed numeric Hub, real systemd, unprivileged'
test "$(id -u ci)" -ne 0
runuser -u ci -- python3 "$root/tools/hub-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 \
    > /tmp/crias-qemu-hub-baseline.json
python3 - /tmp/crias-qemu-hub-baseline.json <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
if report["mode"] != "host" or report["startup_ms"]["count"] != 30 or report["navigation_ms"]["count"] != 60:
    raise SystemExit("unexpected C00 host benchmark report")
print("HUB_BASELINE_ARCH_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 installed Hub numeric PTY baseline (Arch VM; timings observational)'

# Real Gum is needed only inside the disposable VM, not on production hosts.
# All samples run unprivileged and refuse fallback/unknown screens.
pacman -S --needed --noconfirm gum
for stack in minecraft terraria; do
    runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
        --mode fixture --stack "$stack" --samples 3 --idle-seconds 2 \
        > "/tmp/crias-qemu-gum-${stack}.json"
done
runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 --idle-seconds 5 \
    > /tmp/crias-qemu-gum-host.json
python3 - /tmp/crias-qemu-gum-minecraft.json /tmp/crias-qemu-gum-terraria.json /tmp/crias-qemu-gum-host.json <<'PY'
import json
import sys
for path, mode, count in zip(sys.argv[1:], ("fixture", "fixture", "host"), (3, 3, 30)):
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
    if report["mode"] != mode or report["startup_ms"]["count"] != count or report["navigation_ms"]["count"] != 2*count:
        raise SystemExit("unexpected Gum benchmark report")
    print("HUB_BASELINE_GUM_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 real Gum controlling PTY benchmark (Arch VM; timings observational)'



# Exercise the real Minecraft downloader and launcher up to the EULA prompt.
# The test keeps eula=false and does not create or play a Minecraft world.
# shellcheck source=/dev/null
source "$root/minecraft/install.sh"
DRY_RUN=false
MRPACK_INSTALL_VERSION=v0.23.0
install_mrpack_install
for loader in vanilla fabric quilt forge neoforge; do
    mc_ci_event "INICIO" "$loader-1.21.1" "instalacao real do loader; EULA permanece false"
    real_server="/opt/crias-real-${loader}"
    mkdir -p "$real_server/.shared"
    cp "$root"/shared/lib/*.sh "$real_server/.shared/"
    MINECRAFT_SERVER_DIR="$real_server"
    MINECRAFT_LOADER="$loader"
    MINECRAFT_VERSION=1.21.1
    _install_minecraft_server_base
    printf 'eula=false\n' > "$real_server/eula.txt"
    printf 'server-port=0\n' > "$real_server/server.properties"
    printf 'MINECRAFT_VERSION=1.21.1\nMINECRAFT_LOADER=%s\nMIN_RAM=128M\nMAX_RAM=512M\n' "$loader" > "$real_server/runtime.env"
    chown -R criasvm:criasvm "$real_server"
    set +e
    timeout 180 runuser -u criasvm -- env SERVER_DIR="$real_server" bash "$root/minecraft/start-server.sh" > "$real_server/output.log" 2>&1
    status=$?
    set -e
    cp "$real_server/output.log" "$MC_QEMU_LOG_DIR/${loader}-1.21.1.log"
    if [ "$status" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$real_server/output.log"; then
        mc_ci_event "FALHA" "$loader-1.21.1" "nao chegou ao prompt EULA; codigo=$status"
        tail -n 100 "$real_server/output.log" >&2
        exit 1
    fi
    grep -qx "eula=false" "$real_server/eula.txt"
    mc_ci_preview "$loader-1.21.1" "$real_server/output.log"
    mc_ci_event "PASS" "$loader-1.21.1" "Java iniciou o loader real e chegou a EULA; status=$status"
    echo "PASS: real $loader server reached EULA prompt without acceptance"
done



# Contraprova especifica do modpack CriasRealms (Forge 1.20.1 / Java 17).
# Os testes acima executam 1.21.1. Aqui verificamos a versao antiga do loader
# com Java 17 de verdade, incluindo a escolha automatica do binario correto.
# O teste termina na EULA: nao ha aceitacao, criacao de mundo ou multiplayer.
mc_ci_event "INICIO" "forge-1.20.1" "Forge real + Java 17; EULA permanece false"
pacman -S --needed --noconfirm jdk17-openjdk
forge1201_dir=/opt/crias-real-forge-1201
mkdir -p "$forge1201_dir/.shared"
cp "$root"/shared/lib/*.sh "$forge1201_dir/.shared/"
MINECRAFT_SERVER_DIR="$forge1201_dir"
MINECRAFT_LOADER=forge
MINECRAFT_VERSION=1.20.1
_install_minecraft_server_base
printf "eula=false\n" > "$forge1201_dir/eula.txt"
printf "server-port=0\n" > "$forge1201_dir/server.properties"
printf "MINECRAFT_VERSION=1.20.1\nMINECRAFT_LOADER=forge\nMIN_RAM=128M\nMAX_RAM=512M\n" > "$forge1201_dir/runtime.env"
chown -R criasvm:criasvm "$forge1201_dir"
set +e
timeout 240 runuser -u criasvm -- env SERVER_DIR="$forge1201_dir" bash "$root/minecraft/start-server.sh" > "$forge1201_dir/output.log" 2>&1
forge1201_rc=$?
set -e
cp "$forge1201_dir/output.log" "$MC_QEMU_LOG_DIR/forge-1.20.1.log"
if [ "$forge1201_rc" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Forge nao chegou a EULA; codigo=$forge1201_rc"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
if ! grep -Eq 'Java: .*"17[.]' "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Java selecionado nao e 17"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
grep -qx "eula=false" "$forge1201_dir/eula.txt"
mc_ci_preview "forge-1.20.1" "$forge1201_dir/output.log"
mc_ci_event "PASS" "forge-1.20.1" "Java 17 confirmado; EULA nao aceita; codigo=$forge1201_rc"
echo "PASS: Minecraft Forge 1.20.1 iniciou com Java 17 e chegou a EULA sem aceitar"
# Real mrpack-install with a locally generated personal pack (no EULA accepted).
pack_dir="/tmp/personal-pack-fixture"
mkdir -p "$pack_dir/server-overrides/config" /opt/crias-custom-pack
printf '%s\n' '{"formatVersion":1,"game":"minecraft","versionId":"test","name":"Personal","files":[],"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"}}' > "$pack_dir/modrinth.index.json"
printf 'fixture=ok\n' > "$pack_dir/server-overrides/config/personal.txt"
(cd "$pack_dir" && zip -qr '/tmp/personal pack.mrpack' modrinth.index.json server-overrides)
_validate_custom_mrpack '/tmp/personal pack.mrpack'
mc_ci_event "INICIO" "mrpack-local" "pacote sintetico sem dependencias remotas; resposta Modrinth 404 nao invalida o teste"
timeout 300 mrpack-install '/tmp/personal pack.mrpack' --server-dir /opt/crias-custom-pack --server-file server.jar 2>&1 | tee "$MC_QEMU_LOG_DIR/mrpack-local.log"
grep -qx 'fixture=ok' /opt/crias-custom-pack/config/personal.txt
MINECRAFT_SERVER_DIR=/opt/crias-custom-pack
_resolve_modpack_effective_versions
[ "$MC_EFFECTIVE_VERSION" = 1.21.1 ] && [ "$MINECRAFT_LOADER" = fabric ]
mc_ci_event "PASS" "mrpack-local" "arquivo e overrides importados, loader/versao reconhecidos"
echo 'PASS: real mrpack-install imported personal local archive and server overrides'

# Download real optional mods for Forge 1.20.1 and verify duplicate detection.
MINECRAFT_SERVER_DIR=/opt/crias-extra-test
MINECRAFT_LOADER=forge
MC_EFFECTIVE_VERSION=1.20.1
mc_ci_event "INICIO" "extras-forge-1.20.1" "download de tres mods opcionais e deteccao de duplicatas"
MINECRAFT_EXTRA_MODS=skinrestorer,spark,chunky
MINECRAFT_PENDING_MODS=()
stack_install_extra_mods
[ "${#MINECRAFT_PENDING_MODS[@]}" -eq 0 ]
for mod in skinrestorer spark chunky; do unzip -tq "$MINECRAFT_SERVER_DIR/mods/$mod.jar" >/dev/null; done
mv "$MINECRAFT_SERVER_DIR/mods/spark.jar" "$MINECRAFT_SERVER_DIR/mods/spark-versioned.jar"
stack_install_extra_mods
[ ! -e "$MINECRAFT_SERVER_DIR/mods/spark.jar" ]
mc_ci_event "PASS" "extras-forge-1.20.1" "jars validados; duplicata spark evitada"
echo 'PASS: real Forge 1.20.1 server extras downloaded and duplicates avoided'


echo "[QEMU][MINECRAFT][RESUMO-FINAL] Resultados por cenario:"
cat "$MC_QEMU_LOG_DIR/summary.tsv"
echo "PASS: Arch VM, systemd PID 1, real service installer, backup restore, bootstrap and real server pre-EULA launch"
 -test.v -test.timeout=20s
fi
# A recalibracao NAO pode alterar MemoryMax com a JVM ativa.
if CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW >/tmp/crias-memory-active-test.log 2>&1; then
    echo "FAIL: reconfigure-hardware aceitou alterar RAM com JVM ativa" >&2
    exit 1
fi
grep -q "completamente parado" /tmp/crias-memory-active-test.log
systemctl stop minecraft.service
! systemctl is-active --quiet minecraft.service
# Valide o limite persistente de memoria usando systemd real e drop-in.
write_minecraft_systemd_memory_limit 640
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 671088640 ]
write_minecraft_systemd_memory_limit 768
[ "$(systemctl show -p MemoryMax --value minecraft.service)" = 805306368 ]
echo "PASS: MemoryMax sincronizado via drop-in e validado pelo systemd real"
# Integre a reconfiguracao de ponta a ponta (manager -> env -> systemd).
CRIS_MANAGER_ALLOW_UNSAFE=1 SERVER_DIR="$server" SERVER_USER=criasvm \
    bash "$root/minecraft/mc-manager.sh" reconfigure-hardware LOW > /tmp/crias-mc-memory-reconfig.log 2>&1 || {
        cat /tmp/crias-mc-memory-reconfig.log >&2
        echo "FAIL: manager nao sincronizou heap/MemoryMax" >&2
        exit 1
    }
configured_mb="$(sed -n 's/^MC_SERVICE_MEMORY_MAX_MB="\([0-9][0-9]*\)"$/\1/p' "$server/hardware-profile.env")"
[ -n "$configured_mb" ]
[ "$(systemctl show minecraft.service -p MemoryMax --value)" = "$((configured_mb * 1048576))" ]
grep -q "^NATIVE_OVERHEAD_MB=" "$server/runtime.env"
grep -qx 'MINECRAFT_LOADER="vanilla"' "$server/runtime.env"
echo "PASS: manager recalibrou RAM com unit parada e sincronizou Xmx/MemoryMax"
mc_ci_event "PASS" "reconfigure-memory" "manager validou limites efetivos no systemd"

# Injeta OOM isolado para validar a observabilidade de falha de cgroup.
# Nao altera a unit do jogo; a VM e descartavel e nao aceita EULA.
cat > /etc/systemd/system/crias-oom-test.service <<EOF
[Unit]
Description=Crias CI OOM fault injection
[Service]
Type=simple
User=criasvm
WorkingDirectory=/opt/crias-qemu-test
ExecStart=/usr/bin/java -Xms256m -Xmx256m -XX:+AlwaysPreTouch -cp /opt/crias-qemu-test Probe nogui
MemoryMax=64M
MemorySwapMax=0
OOMPolicy=stop
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "oom-injetado" "limite artificial de 64 MB; nao e o Minecraft de producao"
systemctl start crias-oom-test.service
oom_result=""
for i in $(seq 1 40); do
    oom_result="$(systemctl show -p Result --value crias-oom-test.service)"
    [ "$oom_result" = "oom-kill" ] && break
    if ! systemctl is-active --quiet crias-oom-test.service; then break; fi
    sleep 1
done
if [ "$oom_result" != "oom-kill" ]; then
    systemctl status crias-oom-test.service --no-pager -l >&2 || true
    journalctl -u crias-oom-test.service --no-pager >&2 || true
    echo "FAIL: cgroup OOM nao foi detectado como oom-kill ($oom_result)" >&2
    exit 1
fi
echo "PASS: fault injection OOM marcado corretamente pelo systemd"
mc_ci_event "PASS" "oom-injetado" "systemd identificou oom-kill na unidade descartavel"
# Contraprova: depois de falha artificial, o servico DESCARTAVEL
# permanece parado. Reinicios manuais regulares nao ficam bloqueados por
# um contador vitalicio.
cat > /etc/systemd/system/crias-restart-test.service <<'EOF'
[Unit]
Description=Crias CI fail-closed restart check
StartLimitIntervalSec=300s
StartLimitBurst=3
[Service]
Type=simple
ExecStart=/usr/bin/false
Restart=no
EOF
systemctl daemon-reload
mc_ci_event "ESPERADO" "restart-injetado" "falha artificial sem reinicio automatico"
systemctl start crias-restart-test.service >/dev/null 2>&1 || true
restart_result=""
for i in $(seq 1 10); do
    restart_result="$(systemctl show -p Result --value crias-restart-test.service)"
    [ "$restart_result" = "exit-code" ] && break
    sleep 1
done
[ "$restart_result" = "exit-code" ] || {
    echo "FAIL: falha artificial nao reportada como exit-code ($restart_result)" >&2
    exit 1
}
before_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
sleep 3
after_restarts="$(systemctl show -p NRestarts --value crias-restart-test.service)"
[ "$before_restarts" = 0 ] && [ "$after_restarts" = 0 ] || {
    echo "FAIL: falha provocou reinicio automatico ($before_restarts -> $after_restarts)" >&2
    exit 1
}
mc_ci_event "PASS" "restart-injetado" "servico parou na falha sem novos starts"

# Install in a fresh shell so Minecraft hook functions cannot leak into Terraria.
env TERRARIA_SERVER_DIR=/opt/terraria-server TERRARIA_USER=terraria \
    TERRARIA_USE_TMODLOADER=false FORCE_HARDWARE_TIER=LOW \
    APPLY_SYSTEM_TUNING=false DRY_RUN=false \
    bash -c 'set -euo pipefail; source "$1"; run_stack_install' _ "$root/terraria/install.sh" 2>&1 | tee /tmp/crias-terraria-install.log
if grep -Eq 'safe_remove_dir recebeu caminho invalido|Diretorio temporario nao reconhecido|Diretorio temporario nao registrado' /tmp/crias-terraria-install.log; then
    echo 'FAIL: Terraria installer rejected its own temporary directory' >&2
    exit 1
fi
systemctl start terraria.service
ready=false
for i in $(seq 1 180); do
    if ss -H -ltn 'sport = :7777' | grep -q .; then ready=true; break; fi
    if systemctl is-failed --quiet terraria.service; then break; fi
    sleep 2
done
if [ "$ready" != true ]; then
    journalctl -u terraria.service --no-pager >&2
    echo 'FAIL: Terraria did not listen on port 7777' >&2
    exit 1
fi
systemctl stop terraria.service
echo 'PASS: real Terraria stack installed and opened its game port'

# C00: observational baseline against the installed legacy Hub, with real
# Arch/systemd discovery as the unprivileged ci account. Both stacks are
# stopped or use disposable fixtures; no game workload or Gum is measured.
# The harness intercepts administrative calls, including automatic package
# recovery. Report in guest.log (already retained by the QEMU workflow).
echo '[QEMU] C00 baseline: installed numeric Hub, real systemd, unprivileged'
test "$(id -u ci)" -ne 0
runuser -u ci -- python3 "$root/tools/hub-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 \
    > /tmp/crias-qemu-hub-baseline.json
python3 - /tmp/crias-qemu-hub-baseline.json <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
if report["mode"] != "host" or report["startup_ms"]["count"] != 30 or report["navigation_ms"]["count"] != 60:
    raise SystemExit("unexpected C00 host benchmark report")
print("HUB_BASELINE_ARCH_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 installed Hub numeric PTY baseline (Arch VM; timings observational)'

# Real Gum is needed only inside the disposable VM, not on production hosts.
# All samples run unprivileged and refuse fallback/unknown screens.
pacman -S --needed --noconfirm gum
for stack in minecraft terraria; do
    runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
        --mode fixture --stack "$stack" --samples 3 --idle-seconds 2 \
        > "/tmp/crias-qemu-gum-${stack}.json"
done
runuser -u ci -- python3 "$root/tools/hub-gum-baseline.py" \
    --hub /usr/local/bin/crias-tui --mode host --samples 30 --idle-seconds 5 \
    > /tmp/crias-qemu-gum-host.json
python3 - /tmp/crias-qemu-gum-minecraft.json /tmp/crias-qemu-gum-terraria.json /tmp/crias-qemu-gum-host.json <<'PY'
import json
import sys
for path, mode, count in zip(sys.argv[1:], ("fixture", "fixture", "host"), (3, 3, 30)):
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
    if report["mode"] != mode or report["startup_ms"]["count"] != count or report["navigation_ms"]["count"] != 2*count:
        raise SystemExit("unexpected Gum benchmark report")
    print("HUB_BASELINE_GUM_JSON=" + json.dumps(report, separators=(",", ":")))
PY
echo 'PASS: C00 real Gum controlling PTY benchmark (Arch VM; timings observational)'



# Exercise the real Minecraft downloader and launcher up to the EULA prompt.
# The test keeps eula=false and does not create or play a Minecraft world.
# shellcheck source=/dev/null
source "$root/minecraft/install.sh"
DRY_RUN=false
MRPACK_INSTALL_VERSION=v0.23.0
install_mrpack_install
for loader in vanilla fabric quilt forge neoforge; do
    mc_ci_event "INICIO" "$loader-1.21.1" "instalacao real do loader; EULA permanece false"
    real_server="/opt/crias-real-${loader}"
    mkdir -p "$real_server/.shared"
    cp "$root"/shared/lib/*.sh "$real_server/.shared/"
    MINECRAFT_SERVER_DIR="$real_server"
    MINECRAFT_LOADER="$loader"
    MINECRAFT_VERSION=1.21.1
    _install_minecraft_server_base
    printf 'eula=false\n' > "$real_server/eula.txt"
    printf 'server-port=0\n' > "$real_server/server.properties"
    printf 'MINECRAFT_VERSION=1.21.1\nMINECRAFT_LOADER=%s\nMIN_RAM=128M\nMAX_RAM=512M\n' "$loader" > "$real_server/runtime.env"
    chown -R criasvm:criasvm "$real_server"
    set +e
    timeout 180 runuser -u criasvm -- env SERVER_DIR="$real_server" bash "$root/minecraft/start-server.sh" > "$real_server/output.log" 2>&1
    status=$?
    set -e
    cp "$real_server/output.log" "$MC_QEMU_LOG_DIR/${loader}-1.21.1.log"
    if [ "$status" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$real_server/output.log"; then
        mc_ci_event "FALHA" "$loader-1.21.1" "nao chegou ao prompt EULA; codigo=$status"
        tail -n 100 "$real_server/output.log" >&2
        exit 1
    fi
    grep -qx "eula=false" "$real_server/eula.txt"
    mc_ci_preview "$loader-1.21.1" "$real_server/output.log"
    mc_ci_event "PASS" "$loader-1.21.1" "Java iniciou o loader real e chegou a EULA; status=$status"
    echo "PASS: real $loader server reached EULA prompt without acceptance"
done



# Contraprova especifica do modpack CriasRealms (Forge 1.20.1 / Java 17).
# Os testes acima executam 1.21.1. Aqui verificamos a versao antiga do loader
# com Java 17 de verdade, incluindo a escolha automatica do binario correto.
# O teste termina na EULA: nao ha aceitacao, criacao de mundo ou multiplayer.
mc_ci_event "INICIO" "forge-1.20.1" "Forge real + Java 17; EULA permanece false"
pacman -S --needed --noconfirm jdk17-openjdk
forge1201_dir=/opt/crias-real-forge-1201
mkdir -p "$forge1201_dir/.shared"
cp "$root"/shared/lib/*.sh "$forge1201_dir/.shared/"
MINECRAFT_SERVER_DIR="$forge1201_dir"
MINECRAFT_LOADER=forge
MINECRAFT_VERSION=1.20.1
_install_minecraft_server_base
printf "eula=false\n" > "$forge1201_dir/eula.txt"
printf "server-port=0\n" > "$forge1201_dir/server.properties"
printf "MINECRAFT_VERSION=1.20.1\nMINECRAFT_LOADER=forge\nMIN_RAM=128M\nMAX_RAM=512M\n" > "$forge1201_dir/runtime.env"
chown -R criasvm:criasvm "$forge1201_dir"
set +e
timeout 240 runuser -u criasvm -- env SERVER_DIR="$forge1201_dir" bash "$root/minecraft/start-server.sh" > "$forge1201_dir/output.log" 2>&1
forge1201_rc=$?
set -e
cp "$forge1201_dir/output.log" "$MC_QEMU_LOG_DIR/forge-1.20.1.log"
if [ "$forge1201_rc" -eq 124 ] || ! grep -Eiq "agree.*eula|eula.*agree" "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Forge nao chegou a EULA; codigo=$forge1201_rc"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
if ! grep -Eq 'Java: .*"17[.]' "$forge1201_dir/output.log"; then
    mc_ci_event "FALHA" "forge-1.20.1" "Java selecionado nao e 17"
    tail -n 100 "$forge1201_dir/output.log" >&2
    exit 1
fi
grep -qx "eula=false" "$forge1201_dir/eula.txt"
mc_ci_preview "forge-1.20.1" "$forge1201_dir/output.log"
mc_ci_event "PASS" "forge-1.20.1" "Java 17 confirmado; EULA nao aceita; codigo=$forge1201_rc"
echo "PASS: Minecraft Forge 1.20.1 iniciou com Java 17 e chegou a EULA sem aceitar"
# Real mrpack-install with a locally generated personal pack (no EULA accepted).
pack_dir="/tmp/personal-pack-fixture"
mkdir -p "$pack_dir/server-overrides/config" /opt/crias-custom-pack
printf '%s\n' '{"formatVersion":1,"game":"minecraft","versionId":"test","name":"Personal","files":[],"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"}}' > "$pack_dir/modrinth.index.json"
printf 'fixture=ok\n' > "$pack_dir/server-overrides/config/personal.txt"
(cd "$pack_dir" && zip -qr '/tmp/personal pack.mrpack' modrinth.index.json server-overrides)
_validate_custom_mrpack '/tmp/personal pack.mrpack'
mc_ci_event "INICIO" "mrpack-local" "pacote sintetico sem dependencias remotas; resposta Modrinth 404 nao invalida o teste"
timeout 300 mrpack-install '/tmp/personal pack.mrpack' --server-dir /opt/crias-custom-pack --server-file server.jar 2>&1 | tee "$MC_QEMU_LOG_DIR/mrpack-local.log"
grep -qx 'fixture=ok' /opt/crias-custom-pack/config/personal.txt
MINECRAFT_SERVER_DIR=/opt/crias-custom-pack
_resolve_modpack_effective_versions
[ "$MC_EFFECTIVE_VERSION" = 1.21.1 ] && [ "$MINECRAFT_LOADER" = fabric ]
mc_ci_event "PASS" "mrpack-local" "arquivo e overrides importados, loader/versao reconhecidos"
echo 'PASS: real mrpack-install imported personal local archive and server overrides'

# Download real optional mods for Forge 1.20.1 and verify duplicate detection.
MINECRAFT_SERVER_DIR=/opt/crias-extra-test
MINECRAFT_LOADER=forge
MC_EFFECTIVE_VERSION=1.20.1
mc_ci_event "INICIO" "extras-forge-1.20.1" "download de tres mods opcionais e deteccao de duplicatas"
MINECRAFT_EXTRA_MODS=skinrestorer,spark,chunky
MINECRAFT_PENDING_MODS=()
stack_install_extra_mods
[ "${#MINECRAFT_PENDING_MODS[@]}" -eq 0 ]
for mod in skinrestorer spark chunky; do unzip -tq "$MINECRAFT_SERVER_DIR/mods/$mod.jar" >/dev/null; done
mv "$MINECRAFT_SERVER_DIR/mods/spark.jar" "$MINECRAFT_SERVER_DIR/mods/spark-versioned.jar"
stack_install_extra_mods
[ ! -e "$MINECRAFT_SERVER_DIR/mods/spark.jar" ]
mc_ci_event "PASS" "extras-forge-1.20.1" "jars validados; duplicata spark evitada"
echo 'PASS: real Forge 1.20.1 server extras downloaded and duplicates avoided'


echo "[QEMU][MINECRAFT][RESUMO-FINAL] Resultados por cenario:"
cat "$MC_QEMU_LOG_DIR/summary.tsv"
echo "PASS: Arch VM, systemd PID 1, real service installer, backup restore, bootstrap and real server pre-EULA launch"
