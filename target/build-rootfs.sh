#!/usr/bin/env bash
# target/build-rootfs.sh — build the payload rootfs image served over NVMe-oF.
#
#   ./target/build-rootfs.sh           # plain ext4 image  -> target/rootfs.img
#   CRYPT=1 ./target/build-rootfs.sh   # LUKS2-wrapped     -> target/rootfs-crypt.img
#
# The image is a sparse raw file ($ROOTFS_SIZE) with a GPT and one partition:
#   CRYPT=0: p1 = ext4 rootfs
#   CRYPT=1: p1 = LUKS2 container holding the *same* ext4 rootfs
# The rootfs is a minimal busybox userspace with /etc/BOOT-PROOF containing a
# UUID; the client greps it post-pivot to prove where it landed.
#
# Privileged steps (losetup/mount/mkfs/cryptsetup) run via sudo. Idempotent:
# rebuilds from scratch every time. The LUKS key ($LUKS_KEYFILE) is generated
# once and reused so rebuilds don't rekey.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

for c in qemu-img sgdisk losetup mkfs.ext4 mount umount busybox; do need_cmd "$c"; done
[ "$CRYPT" = "1" ] && need_cmd cryptsetup

log "building $ROOTFS_IMG (CRYPT=$CRYPT, size=$ROOTFS_SIZE)"

# --- stage the rootfs tree ---------------------------------------------------
WORK="$(mktemp -d)"
LOOP=""
MAPPER_OPEN=""
MOUNTED=""

cleanup() {
    set +e
    [ -n "$MOUNTED" ] && sudo umount "$MOUNTED" 2>/dev/null
    [ -n "$MAPPER_OPEN" ] && sudo cryptsetup close "$MAPPER_OPEN" 2>/dev/null
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/rootfs"
mkdir -p "$STAGE"/{bin,sbin,etc,proc,sys,dev,run,mnt}

# busybox + its shared libs, plus applet symlinks the payload init uses
BB="$(command -v busybox)"
inst_prog "$BB" "$STAGE"
mkdir -p "$STAGE/bin"
cp -L "$BB" "$STAGE/bin/busybox"
for app in sh mount cat echo sleep cut uname setsid poweroff ls grep wc ip; do
    ln -sf busybox "$STAGE/bin/$app"
done

# boot-proof marker: one UUID per build tree, gates compare against it
if [ ! -s "$BOOT_PROOF_FILE" ]; then
    uuidgen > "$BOOT_PROOF_FILE"
    log "generated BOOT-PROOF UUID: $(cat "$BOOT_PROOF_FILE")"
fi
echo "BOOT-PROOF $(cat "$BOOT_PROOF_FILE")" > "$STAGE/etc/BOOT-PROOF"

cat > "$STAGE/etc/os-release" <<EOF
NAME=rdmaboot-payload
PRETTY_NAME="rdmaboot payload rootfs (CRYPT=$CRYPT)"
EOF

# /sbin/init — busybox init, keeps phases + boot-proof on the serial console
cat > "$STAGE/sbin/init" <<'INIT'
#!/bin/sh
PATH=/bin:/sbin
export PATH

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t tmpfs    tmpfs    /run

upt() { cut -d' ' -f1 /proc/uptime; }

# switch_root_done: first userspace code after the pivot
echo "switch_root_done $(upt)" >> /run/boot-phases 2>/dev/null
echo "BOOTPHASE switch_root_done $(upt)" > /dev/console

echo "================================================"
echo " rdmaboot payload rootfs — pivot successful"
cat /etc/BOOT-PROOF
echo " kernel: $(uname -r)"

echo "userspace_ready $(upt)" >> /run/boot-phases 2>/dev/null
echo "BOOTPHASE userspace_ready $(upt)" > /dev/console
echo " shell on console below; 'poweroff -f' to stop"
echo "================================================"

while :; do
    setsid sh -c 'exec sh </dev/console >/dev/console 2>&1'
    sleep 1
done
INIT
chmod +x "$STAGE/sbin/init"

# --- create the image --------------------------------------------------------
rm -f "$ROOTFS_IMG"
qemu-img create -f raw "$ROOTFS_IMG" "$ROOTFS_SIZE" >/dev/null
sgdisk -Z "$ROOTFS_IMG" >/dev/null
sgdisk -n 1:0:0 -t 1:8300 -c 1:"$ROOTFS_LABEL" "$ROOTFS_IMG" >/dev/null

LOOP="$(sudo losetup -fP --show "$ROOTFS_IMG")"
wait_for_block "${LOOP}p1" 50 || die "loop partition ${LOOP}p1 did not appear"

MNT="$WORK/mnt"
mkdir -p "$MNT"

if [ "$CRYPT" = "1" ]; then
    if [ ! -s "$LUKS_KEYFILE" ]; then
        dd if=/dev/urandom of="$LUKS_KEYFILE" bs=32 count=1 status=none
        chmod 600 "$LUKS_KEYFILE"
        log "generated LUKS keyfile: $LUKS_KEYFILE (POC grade — keep it secret)"
    fi
    sudo cryptsetup luksFormat --type luks2 --batch-mode \
        --key-file "$LUKS_KEYFILE" "${LOOP}p1"
    sudo cryptsetup open --key-file "$LUKS_KEYFILE" "${LOOP}p1" rdbbuild
    MAPPER_OPEN=rdbbuild
    sudo mkfs.ext4 -q -L "$ROOTFS_LABEL" /dev/mapper/rdbbuild
    sudo mount /dev/mapper/rdbbuild "$MNT"
else
    sudo mkfs.ext4 -q -L "$ROOTFS_LABEL" "${LOOP}p1"
    sudo mount "${LOOP}p1" "$MNT"
fi
MOUNTED="$MNT"

sudo cp -a "$STAGE/." "$MNT/"
sudo chown -R 0:0 "$MNT"

USED="$(du -sh --apparent-size "$MNT" | cut -f1)"
log "rootfs content installed (used: $USED of $ROOTFS_SIZE image)"

sudo umount "$MNT";  MOUNTED=""
if [ -n "$MAPPER_OPEN" ]; then sudo cryptsetup close "$MAPPER_OPEN"; MAPPER_OPEN=""; fi
sudo losetup -d "$LOOP"; LOOP=""

log "done: $ROOTFS_IMG"
log "boot-proof UUID: $(cat "$BOOT_PROOF_FILE")"
