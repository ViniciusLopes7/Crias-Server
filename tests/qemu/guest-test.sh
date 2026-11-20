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
bash tests/temp-cleanup-test.sh
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
STACK_NAME=minecraft
STACK_USER=criasvm
STACK_SERVER_DIR="$server"
STACK_SERVICE_TEMPLATE="$root/minecraft/minecraft.service"
STACK_SERVICE_MEMORY_MAX_MB=512
DRY_RUN=false
install_stack_service
systemd-analyze verify /etc/systemd/system/minecraft.service
systemctl start minecraft.service
for i in $(seq 1 30); do
    journalctl -u minecraft.service --no-pager | grep -q CRIAS_VM_PROBE_STARTED && break
    sleep 1
done
systemctl is-active --quiet minecraft.service
journalctl -u minecraft.service --no-pager | grep -q CRIAS_VM_PROBE_STARTED
systemctl stop minecraft.service
! systemctl is-active --quiet minecraft.service
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

# Exercise the real Minecraft downloader and launcher up to the EULA prompt.
# The test keeps eula=false and does not create or play a Minecraft world.
# shellcheck source=/dev/null
source "$root/minecraft/install.sh"
DRY_RUN=false
MRPACK_INSTALL_VERSION=v0.23.0
install_mrpack_install
for loader in vanilla fabric quilt forge neoforge; do
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
    cat "$real_server/output.log"
    if [ "$status" -eq 124 ] || ! grep -Ei 'agree.*eula|eula.*agree' "$real_server/output.log"; then
        echo "FAIL: $loader did not reach the Minecraft EULA prompt" >&2
        exit 1
    fi
    grep -qx 'eula=false' "$real_server/eula.txt"
    echo "PASS: real $loader server reached EULA prompt without acceptance"
done


# Real mrpack-install with a locally generated personal pack (no EULA accepted).
pack_dir="/tmp/personal-pack-fixture"
mkdir -p "$pack_dir/server-overrides/config" /opt/crias-custom-pack
printf '%s\n' '{"formatVersion":1,"game":"minecraft","versionId":"test","name":"Personal","files":[],"dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.0"}}' > "$pack_dir/modrinth.index.json"
printf 'fixture=ok\n' > "$pack_dir/server-overrides/config/personal.txt"
(cd "$pack_dir" && zip -qr '/tmp/personal pack.mrpack' modrinth.index.json server-overrides)
_validate_custom_mrpack '/tmp/personal pack.mrpack'
timeout 300 mrpack-install '/tmp/personal pack.mrpack' --server-dir /opt/crias-custom-pack --server-file server.jar
grep -qx 'fixture=ok' /opt/crias-custom-pack/config/personal.txt
MINECRAFT_SERVER_DIR=/opt/crias-custom-pack
_resolve_modpack_effective_versions
[ "$MC_EFFECTIVE_VERSION" = 1.21.1 ] && [ "$MINECRAFT_LOADER" = fabric ]
echo 'PASS: real mrpack-install imported personal local archive and server overrides'

# Download real optional mods for the user's Forge version and verify duplicate detection.
MINECRAFT_SERVER_DIR=/opt/crias-extra-test
MINECRAFT_LOADER=forge
MC_EFFECTIVE_VERSION=1.20.1
MINECRAFT_EXTRA_MODS=skinrestorer,spark,chunky
MINECRAFT_PENDING_MODS=()
stack_install_extra_mods
[ "${#MINECRAFT_PENDING_MODS[@]}" -eq 0 ]
for mod in skinrestorer spark chunky; do unzip -tq "$MINECRAFT_SERVER_DIR/mods/$mod.jar" >/dev/null; done
mv "$MINECRAFT_SERVER_DIR/mods/spark.jar" "$MINECRAFT_SERVER_DIR/mods/spark-versioned.jar"
stack_install_extra_mods
[ ! -e "$MINECRAFT_SERVER_DIR/mods/spark.jar" ]
echo 'PASS: real Forge 1.20.1 server extras downloaded and duplicates avoided'


echo 'PASS: Arch VM, systemd PID 1, real service installer, backup restore, bootstrap and real server pre-EULA launch'
