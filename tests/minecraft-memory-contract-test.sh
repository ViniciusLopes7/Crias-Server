#!/bin/bash
# Validacao de hierarquias cgroup e contratos entre host, JVM e systemd.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$root/shared/lib/common.sh"
# shellcheck source=/dev/null
source "$root/shared/lib/hardware-profile.sh"
# shellcheck source=/dev/null
source "$root/shared/lib/minecraft-tuning.sh"
tmp="$(mktemp -d)"
trap '_crias_cleanup_temps; rm -rf -- "$tmp"' EXIT

# Menor limite de qualquer pai precisa prevalecer sobre o filho.
mkdir -p "$tmp/cg/parent/child"
printf 'max\n' > "$tmp/cg/memory.max"
printf '2147483648\n' > "$tmp/cg/parent/memory.max"
printf '4294967296\n' > "$tmp/cg/parent/child/memory.max"
[ "$(cgroup_v2_effective_memory_mb "$tmp/cg" /parent/child)" = 2048 ]
printf '1073741824\n' > "$tmp/cg/parent/child/memory.max"
[ "$(cgroup_v2_effective_memory_mb "$tmp/cg" /parent/child)" = 1024 ]
printf 'max\n' > "$tmp/cg/parent/child/memory.max"
[ "$(cgroup_v2_effective_memory_mb "$tmp/cg" /)" = "" ] || true
if cgroup_v2_effective_memory_mb "$tmp/cg" /../outside >/dev/null; then
    echo "FAIL: cgroup path traversal permitido" >&2; exit 1
fi

# Em hosts pequenos um heap minimo artificial nao pode exceder a cota.
for mb in 0 128 512 768 1000; do
    if compute_minecraft_tuning "$mb" 4 SSD MID >/dev/null 2>&1; then
        echo "FAIL: tuning aceitou host com apenas ${mb}MB" >&2; exit 1
    fi
done
for mb in 1024 1536 2048 3072 4096 8192 16384 32768; do
    compute_minecraft_tuning "$mb" 4 SSD MID
    xmx="${MC_MAX_RAM%M}"
    xms="${MC_MIN_RAM%M}"
    cap="$MC_SERVICE_MEMORY_MAX_MB"
    [ "$xms" -le "$xmx" ] && [ "$xmx" -lt "$cap" ]
    [ "$((xmx + MC_NATIVE_OVERHEAD_MB))" -eq "$cap" ] || {
        echo "FAIL: RAM $mb, heap+native != cap" >&2; exit 1;
    }
    [ "$((cap + MC_HOST_RESERVE_MB))" -le "$mb" ] || {
        echo "FAIL: RAM $mb, reserva OS comprometida" >&2; exit 1;
    }
done

# Testa escrita e rollback do drop-in sem alterar unidades do sistema.
MOCK_VERIFY_FAIL=0
systemctl() {
    case "$*" in
        daemon-reload) return 0 ;;
        *) echo "systemctl inesperado: $*" >&2; return 1 ;;
    esac
}
systemd-analyze() {
    [ "$*" = "verify minecraft.service" ] || return 1
    [ "$MOCK_VERIFY_FAIL" -eq 0 ]
}
dir="$tmp/minecraft.service.d"
write_minecraft_systemd_memory_limit 1536 "$dir"
grep -qx "MemoryMax=1536M" "$dir/20-crias-memory.conf"
MOCK_VERIFY_FAIL=1
if write_minecraft_systemd_memory_limit 2048 "$dir" >/dev/null 2>&1; then
    echo "FAIL: systemd verify quebrado foi ignorado" >&2; exit 1
fi
grep -qx "MemoryMax=1536M" "$dir/20-crias-memory.conf" || {
    echo "FAIL: rollback da cota anterior nao funcionou" >&2; exit 1;
}
MOCK_VERIFY_FAIL=0
ln -s "$dir" "$tmp/symlink"
if write_minecraft_systemd_memory_limit 2048 "$tmp/symlink" >/dev/null 2>&1; then
    echo "FAIL: symlink aceito para drop-in" >&2; exit 1
fi

echo "OK: cgroup ancestral, baixo RAM fail-closed, heap/native/MemoryMax e rollback systemd"
