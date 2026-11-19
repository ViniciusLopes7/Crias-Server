#!/bin/bash
# Run inside a disposable Arch VM as root. No third-party game EULA is accepted.
set -euo pipefail
root="${1:?repository path required}"
[ "$(ps -p 1 -o comm=)" = systemd ] || { echo 'systemd is not PID 1' >&2; exit 1; }
pacman -Syu --noconfirm --needed bash coreutils gettext jq tar zstd zip unzip jdk21-openjdk
cd "$root"
bash tests/crias-bootstrap-test.sh
bash tests/backup-integrity-test.sh
bash tests/modpack-state-test.sh
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
env SERVER_USER=criasvm SERVER_DIR="$server" MEMORY_MAX_MB=512 envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB}' < minecraft/minecraft.service > /etc/systemd/system/minecraft.service
systemd-analyze verify /etc/systemd/system/minecraft.service
systemctl daemon-reload
systemctl start minecraft.service
for i in $(seq 1 30); do
    journalctl -u minecraft.service --no-pager | grep -q CRIAS_VM_PROBE_STARTED && break
    sleep 1
done
systemctl is-active --quiet minecraft.service
journalctl -u minecraft.service --no-pager | grep -q CRIAS_VM_PROBE_STARTED
systemctl stop minecraft.service
! systemctl is-active --quiet minecraft.service
echo 'PASS: Arch VM, systemd PID 1, real hardened unit and JVM probe, backup restore and bootstrap tests'
