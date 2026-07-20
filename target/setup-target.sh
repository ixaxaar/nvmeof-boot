#!/usr/bin/env bash
# target/setup-target.sh — idempotent nvmet/RDMA bring-up.
#
# Runs INSIDE the target VM (invoked by the target initramfs' /init), but is
# written to also work on any Linux host for debugging. Tears down any
# existing config for our NQN first, so it is safe to re-run.
set -euo pipefail

if [ -f /etc/rdmaboot/env.sh ]; then
    . /etc/rdmaboot/env.sh      # inside the target VM
else
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    . ./env.sh                  # on a host, from the repo
fi

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

log "setting up nvmet target: nqn=$NQN dev=$TARGET_BACKING_DEV ${TARGET_IP}:${NVME_PORT}"

# one modprobe per module: busybox modprobe (and kmod --show-depends) treat
# extra arguments as module PARAMETERS, not more modules
for m in nvmet nvmet_rdma rdma_rxe; do
    $SUDO modprobe "$m"
done

# soft-RoCE link (no-op if a real RNIC is present; real hardware swap-in point)
if ! $SUDO rdma link show | grep -v "link rxe" | grep -q .; then
    $SUDO rdma link add "$RXE_NAME" type rxe netdev "$TARGET_NETDEV" 2>/dev/null || true
fi
$SUDO rdma link show

CFG=/sys/kernel/config/nvmet
[ -d "$CFG" ] || die "configfs nvmet not available (is nvmet loaded?)"

# teardown-first idempotency for our NQN/port
if [ -d "$CFG/subsystems/$NQN" ]; then
    log "existing config for $NQN found — tearing down first"
    "$(dirname "${BASH_SOURCE[0]}")/teardown-target.sh" 2>/dev/null || true
fi

[ -b "$TARGET_BACKING_DEV" ] || die "backing device $TARGET_BACKING_DEV not found"

$SUDO mkdir -p "$CFG/subsystems/$NQN"
echo 1 | $SUDO tee "$CFG/subsystems/$NQN/attr_allow_any_host" >/dev/null   # POC only — see README
$SUDO mkdir -p "$CFG/subsystems/$NQN/namespaces/1"
echo -n "$TARGET_BACKING_DEV" | $SUDO tee "$CFG/subsystems/$NQN/namespaces/1/device_path" >/dev/null
echo 1 | $SUDO tee "$CFG/subsystems/$NQN/namespaces/1/enable" >/dev/null

$SUDO mkdir -p "$CFG/ports/1"
echo "$TARGET_IP" | $SUDO tee "$CFG/ports/1/addr_traddr"  >/dev/null
echo rdma         | $SUDO tee "$CFG/ports/1/addr_trtype"  >/dev/null
echo "$NVME_PORT" | $SUDO tee "$CFG/ports/1/addr_trsvcid" >/dev/null
echo ipv4         | $SUDO tee "$CFG/ports/1/addr_adrfam"  >/dev/null
$SUDO ln -sfn "$CFG/subsystems/$NQN" "$CFG/ports/1/subsystems/$NQN"

log "nvmet target up: $NQN on rdma://${TARGET_IP}:${NVME_PORT} backing=$TARGET_BACKING_DEV"
