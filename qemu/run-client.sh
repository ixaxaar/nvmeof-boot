#!/usr/bin/env bash
# qemu/run-client.sh — boot the diskless client VM for a full stage 1→2 run.
#
#   qemu/run-client.sh            # foreground, serial console on stdio
#   qemu/run-client.sh --daemon   # background; serial on unix socket + logfile
#
# Netboots via direct -kernel/-initrd (stage 3 replaces this with real PXE).
# Gets one empty local NVMe (qemu serial=$LOCAL_NVME_SERIAL) as copy target.
# Renders the kernel cmdline from client/kernel-cmdline.txt + env.sh vars.
# Every run drops its serial log + env into $ARTIFACT_RUN_DIR (default:
# measure/artifacts/client-<timestamp>/).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

DAEMON=0
[ "${1:-}" = "--daemon" ] && DAEMON=1

KERNEL="$(detect_guest_kernel)"
[ -f "$CLIENT_INITRAMFS" ] || die "$CLIENT_INITRAMFS missing — run: make initramfs-client"
ip link show "$TAP_CLIENT" >/dev/null 2>&1 || die "$TAP_CLIENT missing — run: make net"

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
RUN_DIR="${ARTIFACT_RUN_DIR:-$ARTIFACTS_DIR/client-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RUN_DIR"
SERIAL_LOG="$RUN_DIR/serial-client.log"
PIDFILE="$STATE_DIR/client.pid"
SOCK="$STATE_DIR/client.serial"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    die "client already running (pid $(cat "$PIDFILE")) — kill it or 'make clean-state' first"
fi
rm -f "$SOCK"

[ -f "$LOCAL_IMG" ] || qemu-img create -f raw "$LOCAL_IMG" "$LOCAL_IMG_SIZE" >/dev/null

# render the canonical cmdline: strip comments/blanks, substitute @VARS@
render_cmdline() {
    local line
    while read -r line; do
        line="${line//@TARGET_IP@/$TARGET_IP}"
        line="${line//@NQN@/$NQN}"
        line="${line//@CLIENT_NETDEV@/$CLIENT_NETDEV}"
        line="${line//@COPY_MODE@/$COPY_MODE}"
        line="${line//@CLIENT_IP@/$CLIENT_IP}"
        line="${line//@NETMASK@/$NETMASK}"
        line="${line//@CRYPT@/$CRYPT}"
        line="${line//@SAFE_OFFLOADS@/$SAFE_OFFLOADS}"
        line="${line//@PHASE_LOG@/$PHASE_LOG}"
        line="${line//@ROOT_ARG@/$ROOT_ARG}"
        printf '%s ' "$line"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$CLIENT_DIR/kernel-cmdline.txt")
}
CMDLINE="$(render_cmdline)"
echo "$CMDLINE" > "$RUN_DIR/kernel-cmdline.rendered"

{
    echo "role=client"
    echo "kernel=$KERNEL"
    echo "initramfs=$CLIENT_INITRAMFS"
    echo "local_img=$LOCAL_IMG"
    echo "local_img_size=$(stat -c %s "$LOCAL_IMG")"
    echo "rootfs_img=$ROOTFS_IMG"
    [ -f "$ROOTFS_IMG" ] && echo "rootfs_size=$(stat -c %s "$ROOTFS_IMG")"
    echo "crypt=$CRYPT copy_mode=$COPY_MODE nqn=$NQN target_ip=$TARGET_IP mtu=$MTU"
    echo "date=$(date -Is)"
} > "$RUN_DIR/env.txt"

QEMU_ARGS=(
    -enable-kvm -machine q35 -cpu host
    -m "$VM_MEM" -smp "$VM_SMP"
    -kernel "$KERNEL"
    -initrd "$CLIENT_INITRAMFS"
    -append "$CMDLINE"
    -no-reboot
    -netdev "tap,id=n0,ifname=$TAP_CLIENT,script=no,downscript=no"
    -device "virtio-net-pci,netdev=n0,mac=$CLIENT_MAC"
    -drive "file=$LOCAL_IMG,if=none,id=localnvme0,format=raw,cache=none"
    -device "nvme,drive=localnvme0,serial=$LOCAL_NVME_SERIAL"
    -object "rng-random,filename=/dev/urandom"
    -device virtio-rng-pci
    -display none -vga none
    -monitor "unix:$STATE_DIR/client.mon,server,nowait"
    -pidfile "$PIDFILE"
)

log "booting client VM (copy_mode=$COPY_MODE crypt=$CRYPT; log: $SERIAL_LOG)"
if [ "$DAEMON" = "1" ]; then
    qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -chardev "socket,id=ser0,path=$SOCK,server=on,wait=off,logfile=$SERIAL_LOG" \
        -serial chardev:ser0 \
        -daemonize
    log "client VM daemonized, pid $(cat "$PIDFILE")"
else
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -chardev "stdio,id=ser0,logfile=$SERIAL_LOG" \
        -serial chardev:ser0
fi
