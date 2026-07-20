#!/usr/bin/env bash
# target/build-initramfs.sh — build the target VM's initramfs OS with dracut.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

need_cmd dracut

log "building $TARGET_INITRAMFS (kver=$KVER)"

# dracut needs root (device nodes inside the cpio archive)
sudo dracut --force --kver "$KVER" \
    --modules-dir "$TARGET_DIR/dracut/modules.d" \
    --add " nvmet-target " \
    --add-drivers " nvmet nvmet_rdma rdma_rxe ib_core rdma_cm virtio_net virtio_blk " \
    "$TARGET_INITRAMFS"

sudo chown "$(id -u):$(id -g)" "$TARGET_INITRAMFS"
log "built $TARGET_INITRAMFS"
