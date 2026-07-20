#!/usr/bin/env bash
# gate-0 — stage-0 Definition of Done:
#   from the host, `nvme discover -t rdma` lists the subsystem, `nvme connect`
#   works, and the namespace appears with the right size. Then disconnect
#   cleanly. No boot involved.
#
# Auto-ensures preconditions (bridge/taps + target VM up) so `make gate-0`
# works from a clean state. The host-side rxe link is temporary and removed
# on exit (trap), pass or fail.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

RUN_DIR="$ARTIFACTS_DIR/gate0-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR" "$STATE_DIR"
log "gate-0: artifacts in $RUN_DIR"

# --- preconditions ----------------------------------------------------------
[ -f "$TARGET_INITRAMFS" ] || die "$TARGET_INITRAMFS missing — run: make initramfs-target"
[ -f "$ROOTFS_IMG_PLAIN" ] || die "$ROOTFS_IMG_PLAIN missing — run: make rootfs"
ip link show "$BRIDGE" >/dev/null 2>&1 || ./qemu/net-setup.sh

if [ -f "$STATE_DIR/target.pid" ] && kill -0 "$(cat "$STATE_DIR/target.pid")" 2>/dev/null; then
    log "target VM already running (pid $(cat "$STATE_DIR/target.pid"))"
else
    log "starting target VM..."
    ./qemu/run-target.sh --daemon
fi

./qemu/serial-expect.py "$STATE_DIR/target.serial" wait "TARGET-READY" \
    --timeout "$TARGET_READY_TIMEOUT" \
    --logfile "$ARTIFACTS_DIR/target/serial-target.log" > "$RUN_DIR/target-ready.txt" \
    || die "target never became ready (see $RUN_DIR/target-ready.txt)"
log "target is READY"

# --- the actual gate ---------------------------------------------------------
cleanup() {
    sudo nvme disconnect -n "$NQN" >/dev/null 2>&1 || true
    sudo rdma link del "$GATE_RXE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo modprobe rdma_rxe nvme_fabrics nvme_rdma
sudo rdma link add "$GATE_RXE_NAME" type rxe netdev "$BRIDGE" \
    || die "rdma link add $GATE_RXE_NAME on $BRIDGE failed"
sudo rdma link show | tee "$RUN_DIR/rdma-link.txt"

log "discovering $NQN on rdma://$TARGET_IP:$NVME_PORT ..."
sudo nvme discover -t rdma -a "$TARGET_IP" -s "$NVME_PORT" | tee "$RUN_DIR/discover.txt"
grep -q "$NQN" "$RUN_DIR/discover.txt" || die "discover did not list $NQN"
log "discover: OK"

sudo nvme connect -t rdma -a "$TARGET_IP" -s "$NVME_PORT" -n "$NQN" \
    || die "nvme connect failed"

REMOTE=""
for i in $(seq 1 100); do
    REMOTE="$(resolve_remote_ns)" && break
    sleep 0.1
done
[ -n "$REMOTE" ] || die "namespace device never appeared after connect"

sudo nvme list | tee "$RUN_DIR/nvme-list.txt"

expected_sectors=$(( $(stat -c %s "$ROOTFS_IMG_PLAIN") / 512 ))
actual_sectors="$(sudo blockdev --getsz "$REMOTE")"
log "namespace $REMOTE: $actual_sectors sectors (expected $expected_sectors)"
[ "$actual_sectors" = "$expected_sectors" ] \
    || die "namespace size mismatch: $actual_sectors != $expected_sectors"

sudo nvme disconnect -n "$NQN" || die "nvme disconnect failed"

sudo dmesg | tail -n 50 > "$RUN_DIR/dmesg-tail.txt" 2>/dev/null || true

log "GATE-0 PASS: discover + connect + size + clean disconnect"
