#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source shared/lib/hardware-profile.sh
# shellcheck source=/dev/null
source shared/lib/minecraft-tuning.sh

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "[minecraft-tuning-test] $message: expected=$expected actual=$actual" >&2
        exit 1
    fi
}

assert_match() {
    local value="$1"
    local pattern="$2"
    local message="$3"

    if ! [[ "$value" =~ $pattern ]]; then
        echo "[minecraft-tuning-test] $message: value=$value pattern=$pattern" >&2
        exit 1
    fi
}

compute_minecraft_tuning 4096 4 SSD MID
assert_match "$MC_MIN_RAM" '^[0-9]+M$' 'MC_MIN_RAM format'
assert_match "$MC_MAX_RAM" '^[0-9]+M$' 'MC_MAX_RAM format'
assert_match "$MC_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'MC_SERVICE_MEMORY_MAX_MB format'

min_mb=${MC_MIN_RAM%M}
max_mb=${MC_MAX_RAM%M}
service_mb=$MC_SERVICE_MEMORY_MAX_MB

if [ "$min_mb" -ge "$max_mb" ]; then
    echo "[minecraft-tuning-test] Expected Xms < Xmx, got $min_mb >= $max_mb" >&2
    exit 1
fi

if [ "$service_mb" -le "$max_mb" ]; then
    echo "[minecraft-tuning-test] Expected systemd memory cap to be above Xmx, got service=$service_mb xmx=$max_mb" >&2
    exit 1
fi

compute_minecraft_tuning 2048 2 HDD LOW
assert_match "$MC_MIN_RAM" '^[0-9]+M$' 'MC_MIN_RAM format low'
assert_match "$MC_MAX_RAM" '^[0-9]+M$' 'MC_MAX_RAM format low'
assert_match "$MC_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'MC_SERVICE_MEMORY_MAX_MB format low'

low_xmx=${MC_MAX_RAM%M}
low_xms=${MC_MIN_RAM%M}

if [ "$low_xms" -ge "$low_xmx" ]; then
    echo "[minecraft-tuning-test] Expected low-memory Xms < Xmx, got $low_xms >= $low_xmx" >&2
    exit 1
fi

compute_minecraft_tuning 1024 2 HDD LOW
assert_match "$MC_MIN_RAM" '^[0-9]+M$' 'MC_MIN_RAM format very low'
assert_match "$MC_MAX_RAM" '^[0-9]+M$' 'MC_MAX_RAM format very low'
assert_match "$MC_SERVICE_MEMORY_MAX_MB" '^[0-9]+$' 'MC_SERVICE_MEMORY_MAX_MB format very low'

very_low_xmx=${MC_MAX_RAM%M}
very_low_xms=${MC_MIN_RAM%M}

if [ "$very_low_xms" -ge "$very_low_xmx" ]; then
    echo "[minecraft-tuning-test] Expected very-low-memory Xms < Xmx, got $very_low_xms >= $very_low_xmx" >&2
    exit 1
fi

if [ "$MC_SERVICE_MEMORY_MAX_MB" -lt "$very_low_xmx" ]; then
    echo "[minecraft-tuning-test] Expected systemd cap to stay at or above Xmx, got service=$MC_SERVICE_MEMORY_MAX_MB xmx=$very_low_xmx" >&2
    exit 1
fi

echo "[minecraft-tuning-test] OK"