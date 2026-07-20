#!/usr/bin/env bash
# qemu/net-teardown.sh — remove the rdb-* bridge and taps. Idempotent.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

for t in "$TAP_TARGET" "$TAP_CLIENT"; do
    if ip link show "$t" >/dev/null 2>&1; then
        sudo ip link del "$t" && log "removed $t"
    fi
done

if ip link show "$BRIDGE" >/dev/null 2>&1; then
    sudo ip link del "$BRIDGE" && log "removed $BRIDGE"
fi

log "network teardown done"
