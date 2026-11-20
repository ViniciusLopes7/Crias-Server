#!/bin/bash
# Exercises the production launcher using a real JVM and a harmless Java main.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/Probe.java" <<'JAVA'
public class Probe {
    public static void main(String[] args) {
        if (args.length != 1 || !args[0].equals("nogui")) throw new IllegalArgumentException("wrong args");
        System.out.println("CRIAS_LAUNCH_OK");
    }
}
JAVA
javac "$tmp/Probe.java"
jar --create --file "$tmp/server.jar" --main-class Probe -C "$tmp" Probe.class
printf 'server-port=0\n' > "$tmp/server.properties"
for loader in vanilla fabric quilt forge neoforge; do
    version=1.21
    if [ "${TEST_JAVA_MAJOR:-21}" = 25 ]; then version=26.1; fi
    printf 'MINECRAFT_LOADER=%s\nMINECRAFT_VERSION=%s\nMIN_RAM=32M\nMAX_RAM=128M\n' "$loader" "$version" > "$tmp/runtime.env"
    rm -rf "$tmp/libraries"
    if [ "$loader" = forge ] || [ "$loader" = neoforge ]; then
        path="$tmp/libraries/net/test/$loader/test"
        mkdir -p "$path"
        printf '%s\n' '-cp' "$tmp" 'Probe' > "$path/unix_args.txt"
    fi
    SERVER_DIR="$tmp" JAVA_BIN="$(command -v java)" bash "$root/minecraft/start-server.sh" > "$tmp/output" 2>&1 || { cat "$tmp/output" >&2; exit 1; }
    grep -q CRIAS_LAUNCH_OK "$tmp/output" || { cat "$tmp/output" >&2; exit 1; }
done
# Ambiente do Java nao pode sobrescrever Xmx/Xms de runtime.env.
printf 'MINECRAFT_LOADER=vanilla\nMINECRAFT_VERSION=%s\nMIN_RAM=32M\nMAX_RAM=128M\n' "$version" > "$tmp/runtime.env"
for java_env_name in JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS; do
    if env "$java_env_name=-Xmx1024M" SERVER_DIR="$tmp" JAVA_BIN="$(command -v java)" \
        bash "$root/minecraft/start-server.sh" > "$tmp/output" 2>&1; then
        echo "FAIL: launcher aceitou $java_env_name sobrescrevendo Xmx" >&2
        exit 1
    fi
    grep -q "$java_env_name define limite de memoria JVM" "$tmp/output" || {
        cat "$tmp/output" >&2
        exit 1
    }
done

# Forge: MaxDirectMemorySize tambem altera orcamento nativo da JVM.
mkdir -p "$tmp/libraries/net/test/forge/test"
printf '%s\n' '-cp' "$tmp" 'Probe' > "$tmp/libraries/net/test/forge/test/unix_args.txt"
printf '%s\n' '-XX:MaxDirectMemorySize=16g' > "$tmp/user_jvm_args.txt"
printf 'MINECRAFT_LOADER=forge\nMINECRAFT_VERSION=%s\nMIN_RAM=32M\nMAX_RAM=128M\n' "$version" > "$tmp/runtime.env"
if SERVER_DIR="$tmp" JAVA_BIN="$(command -v java)" bash "$root/minecraft/start-server.sh" > "$tmp/output" 2>&1; then
    echo "FAIL: Forge aceitou MaxDirectMemorySize conflitante" >&2
    exit 1
fi
grep -q "user_jvm_args.txt contem opcao conflitante" "$tmp/output"

echo "OK: Java ${TEST_JAVA_MAJOR:-21} real JVM launched five loader paths, rejected hidden memory overrides"
