#!/usr/bin/env bash
# Heap policy invariants: safe ceiling, Xms=Xmx, no world/backups modifications,
# custom override persistence and atomic update of runtime.env.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/shared/lib/common.sh"
source "$root/shared/lib/hardware-profile.sh"
source "$root/shared/lib/minecraft-tuning.sh"
tmp="$(mktemp -d /tmp/crias-heap-control-XXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

compute_minecraft_tuning 8192 8 SSD MID
auto_max="${MC_MAX_RAM%M}"
auto_min="${MC_MIN_RAM%M}"
[ "$auto_min" -lt "$auto_max" ] || fail "automatic mode no longer elastic"
minecraft_heap_apply_policy fixed 0 || fail "fixed policy rejected"
[ "$MC_MIN_RAM" = "$MC_MAX_RAM" ] || fail "fixed mode failed to equalize Xms/Xmx"
[ "${MC_MAX_RAM%M}" = "$auto_max" ] || fail "fixed mode changed safe Xmx"
[ "$MC_HEAP_POLICY_MODE" = fixed ] || fail "fixed policy mode not tracked"

compute_minecraft_tuning 8192 8 SSD MID
minecraft_heap_apply_policy custom-fixed 3072 || fail "bounded fixed override rejected"
[ "$MC_MAX_RAM" = 3072M ] && [ "$MC_MIN_RAM" = 3072M ] || fail "custom fixed invalid"
[ "$MC_SERVICE_MEMORY_MAX_MB" -gt 3072 ] || fail "systemd native headroom missing"
[ "$MC_HOST_RESERVE_MB" -ge 512 ] || fail "host RAM reserve removed"
[ "$MC_G1_REGION_SIZE" = 8M ] || fail "G1 size inconsistent"
if minecraft_heap_apply_policy custom-fixed 999999 >/dev/null 2>&1; then
    fail "unsafe override larger than host accepted"
fi
if minecraft_heap_apply_policy custom-fixed -1 >/dev/null 2>&1; then
    fail "negative override accepted"
fi
if minecraft_heap_apply_policy custom-fixed '$(touch /tmp/exploit)' >/dev/null 2>&1; then
    fail "shell injection accepted"
fi
if ! minecraft_heap_apply_policy custom-fixed 384 >/dev/null 2>&1; then
    fail "minimum allowed heap should be accepted"
fi
compute_minecraft_tuning 8192 8 SSD MID
minecraft_heap_apply_policy custom-dynamic 3072 || fail "dynamic policy failed"
[ "$MC_MAX_RAM" = 3072M ] && [ "${MC_MIN_RAM%M}" -lt 3072 ] || fail "dynamic growth incorrect"
compute_minecraft_tuning 8192 8 SSD MID
minecraft_heap_apply_policy auto 0 || fail "auto policy failed"
[ "$MC_MIN_RAM" = "${auto_min}M" ] && [ "$MC_MAX_RAM" = "${auto_max}M" ] || fail "auto reset mismatch"

mkdir -p "$tmp/world"
printf 'world-must-remain\n' > "$tmp/world/level.dat"
cat > "$tmp/runtime.env" <<'ENV'
MINECRAFT_VERSION="1.20.1"
MINECRAFT_LOADER="forge"
SERVER_JAR="server.jar"
BACKUP_NOTIFY_WEBHOOK="https://example.invalid/private"
MIN_RAM="1280M"
MAX_RAM="4096M"
G1_REGION_SIZE="8M"
NATIVE_OVERHEAD_MB="1024"
BACKUP_INCLUDE_MODS="true"
ENV
chmod 600 "$tmp/runtime.env"
cp "$tmp/runtime.env" "$tmp/before.env"
compute_minecraft_tuning 8192 8 SSD MID
minecraft_heap_apply_policy custom-fixed 3072 || fail "policy failed before persistence"
minecraft_heap_update_runtime "$tmp/runtime.env" custom-fixed 3072 || fail "write failed"
grep -qx 'MIN_RAM="3072M"' "$tmp/runtime.env" || fail "Xms was not written"
grep -qx 'MAX_RAM="3072M"' "$tmp/runtime.env" || fail "Xmx was not written"
grep -qx 'HEAP_MODE="custom-fixed"' "$tmp/runtime.env" || fail "mode not persisted"
grep -qx 'HEAP_OVERRIDE_MB="3072"' "$tmp/runtime.env" || fail "size not persisted"
grep -qx 'BACKUP_INCLUDE_MODS="true"' "$tmp/runtime.env" || fail "backup setting dropped"
grep -qx 'BACKUP_NOTIFY_WEBHOOK="https://example.invalid/private"' "$tmp/runtime.env" || fail "webhook dropped"
grep -qx 'MINECRAFT_LOADER="forge"' "$tmp/runtime.env" || fail "loader changed"
[ "$(stat -c %a "$tmp/runtime.env")" = 600 ] || fail "runtime secrets exposed"
[ "$(cat "$tmp/world/level.dat")" = world-must-remain ] || fail "world changed"

# Running a hardware recalibration must honor the persisted bounded override.
compute_minecraft_tuning 8192 8 SSD MID
minecraft_heap_apply_policy "$(env_file_read_value "$tmp/runtime.env" HEAP_MODE)" \
    "$(env_file_read_value "$tmp/runtime.env" HEAP_OVERRIDE_MB)"
[ "$MC_MIN_RAM" = 3072M ] && [ "$MC_MAX_RAM" = 3072M ] || fail "reconfigure would lose custom policy"
write_minecraft_runtime_env "$tmp/runtime.env" >/dev/null
grep -qx 'HEAP_MODE="custom-fixed"' "$tmp/runtime.env" || fail "mode lost after regenerated env"
grep -qx 'MAX_RAM="3072M"' "$tmp/runtime.env" || fail "Xmx lost after reconfigure"
grep -qx 'MINECRAFT_LOADER="forge"' "$tmp/runtime.env" || fail "Forge loader lost after reconfigure"

# Real source guard: no live changes; only stopped minecraft can update heap.
grep -Fq 'if [ "$unit_state" != inactive ] && [ "$unit_state" != failed ]' \
    "$root/minecraft/mc-manager.sh" || fail "stopped-only guard missing"
grep -Fq 'minecraft_heap_apply_policy "${heap_mode:-auto}" "${heap_override:-0}"' \
    "$root/minecraft/mc-manager.sh" || fail "reconfigure policy hook missing"

echo "OK: heap auto/fixed/custom safe budgets, persisted modes, Forge/backups/world intact"
