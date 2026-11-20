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
if cgroup_v2_effective_memory_mb "$tmp/cg" / >/dev/null; then
    echo "FAIL: cgroup root sem cota retornou limite" >&2; exit 1
fi
mkdir -p "$tmp/outside"
printf '1073741824\n' > "$tmp/outside/memory.max"
if cgroup_v2_effective_memory_mb "$tmp/cg" /../outside >/dev/null; then
    echo "FAIL: cgroup path traversal permitido" >&2; exit 1
fi

# Quotas de CPU em ancestrais reduzem nproc efetivo, sem confundir
# cpu.max="max" com um limite numerico.
mkdir -p "$tmp/cpu/parent/child"
printf 'max 100000\n' > "$tmp/cpu/cpu.max"
printf '150000 100000\n' > "$tmp/cpu/parent/cpu.max"
printf '400000 100000\n' > "$tmp/cpu/parent/child/cpu.max"
[ "$(cgroup_v2_effective_cpu_cores "$tmp/cpu" /parent/child)" = 1 ] || {
    echo "FAIL: quota de 1.5 cores precisa arredondar para 1" >&2; exit 1;
}
printf '60000 100000\n' > "$tmp/cpu/parent/child/cpu.max"
[ "$(cgroup_v2_effective_cpu_cores "$tmp/cpu" /parent/child)" = 1 ]
printf '400000 100000\n' > "$tmp/cpu/parent/cpu.max"
printf '200000 100000\n' > "$tmp/cpu/parent/child/cpu.max"
[ "$(cgroup_v2_effective_cpu_cores "$tmp/cpu" /parent/child)" = 2 ]
if cgroup_v2_effective_cpu_cores "$tmp/cpu" /../parent >/dev/null; then
    echo "FAIL: traversal aceito em cpu.max" >&2; exit 1
fi

# Folga de RAM do pai, nao apenas memory.max do filho.
printf '3221225472\n' > "$tmp/cg/parent/memory.max"
printf '2147483648\n' > "$tmp/cg/parent/memory.current"
printf '4294967296\n' > "$tmp/cg/parent/child/memory.max"
printf '536870912\n' > "$tmp/cg/parent/child/memory.current"
[ "$(cgroup_v2_available_memory_mb "$tmp/cg" /parent/child)" = 1024 ] || {
    echo "FAIL: memory.current do pai foi ignorado" >&2; exit 1;
}
printf '3435973836\n' > "$tmp/cg/parent/memory.current"
[ "$(cgroup_v2_available_memory_mb "$tmp/cg" /parent/child)" = 0 ] || {
    echo "FAIL: cgroup saturado nao retornou zero" >&2; exit 1;
}
if cgroup_v2_available_memory_mb "$tmp/cg" /../outside >/dev/null; then
    echo "FAIL: traversal aceito em memory.current" >&2; exit 1
fi

# Inactive file cache no memory.stat pode ser reclamado parcialmente.
printf '4294967296\n' > "$tmp/cg/parent/memory.max"
printf '3221225472\n' > "$tmp/cg/parent/memory.current"
printf 'inactive_file 2147483648\n' > "$tmp/cg/parent/memory.stat"
[ "$(cgroup_v2_available_memory_mb "$tmp/cg" /parent/child)" = 2048 ] || {
    echo "FAIL: cache inativo nao foi considerado com margem conservadora" >&2; exit 1;
}

# Heap reduzido por pressao: nunca ultrapassar a folga real de RAM.
compute_minecraft_tuning 4096 4 SSD MID 2048
[ "$((MC_SERVICE_MEMORY_MAX_MB + MC_PRESSURE_RESERVE_MB))" -le 2048 ] || {
    echo "FAIL: tuning consumiu a margem MemAvailable" >&2; exit 1;
}
if compute_minecraft_tuning 4096 4 SSD MID 800 >/dev/null 2>&1; then
    echo "FAIL: tuning aceitou host sem folga para JVM nativa" >&2; exit 1
fi
if compute_minecraft_tuning 4096 4 SSD MID 8192 >/dev/null 2>&1; then
    echo "FAIL: MemAvailable maior que MemTotal foi aceito" >&2; exit 1
fi

# Captura consistente de /proc/meminfo, independente de execucoes de free.
cat > "$tmp/meminfo" <<'EOF'
MemTotal:        8388608 kB
MemAvailable:    4194304 kB
SwapTotal:       2097152 kB
EOF
detect_hardware_profile "$tmp" "" "$tmp/meminfo"
[ "$HW_TOTAL_RAM_MB" -ge 1 ] && [ "$HW_TOTAL_RAM_MB" -le 8192 ]
[ "$HW_AVAILABLE_RAM_MB" -ge 0 ] && [ "$HW_AVAILABLE_RAM_MB" -le 4096 ]
[ "$HW_SWAP_MB" = 2048 ]
[ "$HW_CPU_CORES" -ge 1 ]
[ "$HW_CPU_QUOTA_CORES" -ge 0 ]

# Nunca modificar governor, dispositivos ou zram no host sem opt-in.
grep -qx 'APPLY_SYSTEM_TUNING="false"' "$root/config.env"
grep -qx 'SYSTEM_TUNING_SCOPE="none"' "$root/config.env"
grep -qx 'CRIAS_TUNE_CPU_GOVERNOR="false"' "$root/config.env"
grep -qx 'CRIAS_TUNE_BLOCK_DEVICE="false"' "$root/config.env"

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
MOCK_EFFECTIVE_WRONG=0
MOCK_PARENT_CAP=0
systemctl() {
    case "$*" in
        daemon-reload) return 0 ;;
        "show minecraft.service -p MemoryMax --value")
            if [ "$MOCK_EFFECTIVE_WRONG" -eq 1 ]; then echo 42; return 0; fi
            local mb
            mb="$(sed -n 's/^MemoryMax=\([0-9][0-9]*\)M$/\1/p' "$dir/20-crias-memory.conf")"
            echo "$((mb * 1048576))"
            return 0
            ;;
        "show minecraft.service -p EffectiveMemoryMax --value")
            if [ "$MOCK_PARENT_CAP" -gt 0 ]; then echo "$MOCK_PARENT_CAP"; else
                local mb
                mb="$(sed -n 's/^MemoryMax=\([0-9][0-9]*\)M$/\1/p' "$dir/20-crias-memory.conf")"
                echo "$((mb * 1048576))"
            fi
            return 0
            ;;
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
MOCK_EFFECTIVE_WRONG=1
if write_minecraft_systemd_memory_limit 3072 "$dir" >/dev/null 2>&1; then
    echo "FAIL: MemoryMax diferente do planejado foi aceito" >&2; exit 1
fi
grep -qx "MemoryMax=1536M" "$dir/20-crias-memory.conf"
MOCK_EFFECTIVE_WRONG=0
MOCK_PARENT_CAP=1048576
if write_minecraft_systemd_memory_limit 4096 "$dir" >/dev/null 2>&1; then
    echo "FAIL: cota inferior de slice herdada foi ignorada" >&2; exit 1
fi
grep -qx "MemoryMax=1536M" "$dir/20-crias-memory.conf"
MOCK_PARENT_CAP=0
ln -s "$dir" "$tmp/symlink"
if write_minecraft_systemd_memory_limit 2048 "$tmp/symlink" >/dev/null 2>&1; then
    echo "FAIL: symlink aceito para drop-in" >&2; exit 1
fi

echo "OK: cgroup ancestral, baixo RAM fail-closed, heap/native/MemoryMax e rollback systemd"
