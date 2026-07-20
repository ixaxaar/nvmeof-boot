#!/usr/bin/env bash
# qemu/run-target.sh — boot the target VM (nvmet/RDMA storage server).
#
#   qemu/run-target.sh            # foreground, serial console on stdio
#   qemu/run-target.sh --daemon   # background; serial on unix socket + logfile
#
# The VM boots the host kernel with the target initramfs as its entire OS.
# $ROOTFS_IMG (per CRYPT) is attached as virtio-blk and becomes the nvmet
# backing device ($TARGET_BACKING_DEV). Records the booted image name in
# $STATE_DIR/target.image so gates can detect a CRYPT mismatch.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

DAEMON=0
[ "${1:-}" = "--daemon" ] && DAEMON=1

KERNEL="$(detect_guest_kernel)"
[ -f "$TARGET_INITRAMFS" ] || die "$TARGET_INITRAMFS missing — run: make initramfs-target"
[ -f "$ROOTFS_IMG" ] || die "$ROOTFS_IMG missing — run: make rootfs (CRYPT=$CRYPT)"
ip link show "$TAP_TARGET" >/dev/null 2>&1 || die "$TAP_TARGET missing — run: make net"

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
RUN_DIR="${ARTIFACT_RUN_DIR:-$ARTIFACTS_DIR/target}"
mkdir -p "$RUN_DIR"
SERIAL_LOG="$RUN_DIR/serial-target.log"
PIDFILE="$STATE_DIR/target.pid"
SOCK="$STATE_DIR/target.serial"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    die "target already running (pid $(cat "$PIDFILE")) — 'make target-down' first"
fi
rm -f "$SOCK" "$SERIAL_LOG"

# evidence for the run header
{
    echo "role=target"
    echo "kernel=$KERNEL"
    echo "initramfs=$TARGET_INITRAMFS"
    echo "rootfs_img=$ROOTFS_IMG"
    echo "rootfs_size=$(stat -c %s "$ROOTFS_IMG")"
    echo "crypt=$CRYPT nqn=$NQN ip=$TARGET_IP port=$NVME_PORT mtu=$MTU"
    echo "date=$(date -Is)"
} > "$RUN_DIR/env.txt"

QEMU_ARGS=(
    -enable-kvm -machine q35 -cpu host
    -m "$VM_MEM" -smp "$VM_SMP"
    -kernel "$KERNEL"
    -initrd "$TARGET_INITRAMFS"
    -append "console=ttyS0 loglevel=7 panic=10"
    -no-reboot
    -netdev "tap,id=n0,ifname=$TAP_TARGET,script=no,downscript=no"
    -device "virtio-net-pci,netdev=n0,mac=$TARGET_MAC"
    -drive "file=$ROOTFS_IMG,if=virtio,format=raw,cache=none"
    -display none -vga none
    -monitor "unix:$STATE_DIR/target.mon,server,nowait"
    -pidfile "$PIDFILE"
)

log "booting target VM (image: $(basename "$ROOTFS_IMG"))"
if [ "$DAEMON" = "1" ]; then
    qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -chardev "socket,id=ser0,path=$SOCK,server=on,wait=off,logfile=$SERIAL_LOG" \
        -serial chardev:ser0 \
        -daemonize
    echo "$(basename "$ROOTFS_IMG")" > "$STATE_DIR/target.image"
    log "target VM daemonized, pid $(cat "$PIDFILE"); serial: $SERIAL_LOG"
else
    qemu-system-x86_64 "${QEMU_ARGS[@]}" \
        -chardev "stdio,id=ser0,logfile=$SERIAL_LOG" \
        -serial chardev:ser0
fi
