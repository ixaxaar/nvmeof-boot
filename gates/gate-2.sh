#!/usr/bin/env bash
# gate-2 — stage-2 Definition of Done (also gate-2.5 when CRYPT=1, invoked
# via gate-2.5.sh):
#   client VM boots kernel+initramfs, connects, copies, pivots, and lands in
#   the target's rootfs — proven by the BOOT-PROOF UUID on the serial console.
#   The fabric session must be disconnected in the booted system, and the
#   phase log must be complete. With CRYPT=1, root must additionally be on
#   the LUKS mapper.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

GATE_NAME="gate-2"
[ "$CRYPT" = "1" ] && GATE_NAME="gate-2.5"

RUN_DIR="$ARTIFACTS_DIR/${GATE_NAME}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR" "$STATE_DIR"
log "$GATE_NAME: artifacts in $RUN_DIR"

# --- preconditions -----------------------------------------------------------
[ -f "$CLIENT_INITRAMFS" ] || die "$CLIENT_INITRAMFS missing — run: make initramfs-client"
[ -f "$TARGET_INITRAMFS" ] || die "$TARGET_INITRAMFS missing — run: make initramfs-target"
[ -f "$ROOTFS_IMG" ]       || die "$ROOTFS_IMG missing — run: make rootfs (CRYPT=$CRYPT)"
[ -s "$BOOT_PROOF_FILE" ]  || die "$BOOT_PROOF_FILE missing — build the rootfs first"
ip link show "$BRIDGE" >/dev/null 2>&1 || ./qemu/net-setup.sh

# target must be serving the image that matches CRYPT
want_img="$(basename "$ROOTFS_IMG")"
have_img="$(cat "$STATE_DIR/target.image" 2>/dev/null || echo none)"
if [ -f "$STATE_DIR/target.pid" ] && kill -0 "$(cat "$STATE_DIR/target.pid")" 2>/dev/null \
   && [ "$have_img" = "$want_img" ]; then
    log "target VM already serving $want_img"
else
    log "(re)starting target VM with $want_img (was: $have_img)"
    [ -f "$STATE_DIR/target.pid" ] && kill "$(cat "$STATE_DIR/target.pid")" 2>/dev/null || true
    sleep 1
    ./qemu/run-target.sh --daemon
fi
./qemu/serial-expect.py "$STATE_DIR/target.serial" wait "TARGET-READY" \
    --timeout "$TARGET_READY_TIMEOUT" \
    --logfile "$ARTIFACTS_DIR/target/serial-target.log" > "$RUN_DIR/target-ready.txt" \
    || die "target never became ready"

# --- boot the client for a full pivot ---------------------------------------
rm -f "$LOCAL_IMG"   # pristine empty local disk every run
UUID="$(cat "$BOOT_PROOF_FILE")"
log "booting client; expecting BOOT-PROOF $UUID"

ARTIFACT_RUN_DIR="$RUN_DIR" ./qemu/run-client.sh --daemon

stop_client() { [ -f "$STATE_DIR/client.pid" ] && kill "$(cat "$STATE_DIR/client.pid")" 2>/dev/null || true; }
trap stop_client EXIT

SERIAL_LOG="$RUN_DIR/serial-client.log"
SOCK="$STATE_DIR/client.serial"

./qemu/serial-expect.py "$SOCK" wait "$UUID" \
    --timeout "$BOOT_TIMEOUT" --logfile "$SERIAL_LOG" \
    | tee "$RUN_DIR/wait-proof.txt" \
    || die "BOOT-PROOF UUID never appeared — pivot did not land (see $SERIAL_LOG)"
log "BOOT-PROOF matched — client is running the remote rootfs off its local NVMe"

./qemu/serial-expect.py "$SOCK" wait "BOOTPHASE userspace_ready" \
    --timeout 60 --logfile "$SERIAL_LOG" > /dev/null \
    || die "userspace_ready never marked"

# fabric must be disconnected in the booted system
./qemu/serial-expect.py "$SOCK" sendwait \
    'echo FABRICS=$(ls /sys/class/nvme-fabrics/ctl 2>/dev/null | wc -l)' 'FABRICS=0' \
    --timeout 30 --logfile "$SERIAL_LOG" --retry 3 >> "$RUN_DIR/wait-proof.txt" \
    || die "fabric session still present in booted system (nvme disconnect leaked)"
log "fabric disconnected: OK"

if [ "$CRYPT" = "1" ]; then
    ./qemu/serial-expect.py "$SOCK" sendwait \
        "grep -q '^/dev/mapper/$LUKS_MAPPER ' /proc/mounts && echo CRYPTROOT-OK" 'CRYPTROOT-OK' \
        --timeout 30 --logfile "$SERIAL_LOG" --retry 3 >> "$RUN_DIR/wait-proof.txt" \
        || die "root is not on /dev/mapper/$LUKS_MAPPER"
    log "LUKS root: OK"
fi

# phase log completeness
missing=()
for p in initramfs_entry net_up rdma_up nvme_connected copy_start copy_end \
         root_ready switch_root_done userspace_ready; do
    grep -q "^BOOTPHASE $p " "$SERIAL_LOG" || missing+=("$p")
done
if [ "$CRYPT" = "1" ]; then
    grep -q "^BOOTPHASE crypt_open " "$SERIAL_LOG" || missing+=(crypt_open)
fi
[ "${#missing[@]}" = "0" ] || die "phase log incomplete, missing: ${missing[*]}"
log "phase log complete: OK"

stop_client
trap - EXIT

./measure/parse-timeline.sh "$SERIAL_LOG" > "$RUN_DIR/timeline.txt" 2>/dev/null || true

log "$GATE_NAME PASS"
log "timeline:"
cat "$RUN_DIR/timeline.txt" 2>/dev/null || true
