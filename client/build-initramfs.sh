#!/usr/bin/env bash
# client/build-initramfs.sh — build the client initramfs (kernel + dracut
# module 90rdma-localboot). With CRYPT=1 the LUKS keyfile is baked in
# (POC-grade key delivery — see README security note).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

need_cmd dracut

drivers="nvme nvme_core nvme_fabrics nvme_rdma rdma_rxe ib_core rdma_cm virtio_net ext4"
export RDB_CRYPT="$CRYPT"
export RDB_LUKS_KEYFILE="$LUKS_KEYFILE"
export RDB_LUKS_KEYFILE_INITRD="$LUKS_KEYFILE_INITRD"

if [ "$CRYPT" = "1" ]; then
    [ -s "$LUKS_KEYFILE" ] || die "CRYPT=1 but $LUKS_KEYFILE missing — run 'make rootfs-crypt' first"
    drivers="$drivers dm_crypt dm_mod"
fi

log "building $CLIENT_INITRAMFS (kver=$KVER, CRYPT=$CRYPT)"

# dracut 111 has no --modules-dir; overlay our module via a symlinked base dir
DRACUT_BASE="$BUILD_DIR/dracut-client"
make_dracut_base "$DRACUT_BASE" "$CLIENT_DIR/dracut/modules.d/90rdma-localboot"

sudo dracutbasedir="$DRACUT_BASE" \
    RDB_CRYPT="$RDB_CRYPT" \
    RDB_LUKS_KEYFILE="$RDB_LUKS_KEYFILE" \
    RDB_LUKS_KEYFILE_INITRD="$RDB_LUKS_KEYFILE_INITRD" \
    dracut --force --kver "$KVER" \
    --no-hostonly-cmdline --no-hostonly-default-device \
    --omit " zfs nvmf " \
    --add " rdma-localboot " \
    --add-drivers " $drivers " \
    "$CLIENT_INITRAMFS"

sudo chown "$(id -u):$(id -g)" "$CLIENT_INITRAMFS"
log "built $CLIENT_INITRAMFS"
