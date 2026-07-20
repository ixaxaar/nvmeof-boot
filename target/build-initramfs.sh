#!/usr/bin/env bash
# target/build-initramfs.sh — build the target VM's initramfs OS with dracut.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

need_cmd dracut

log "building $TARGET_INITRAMFS (kver=$KVER)"

# dracut 111 has no --modules-dir; overlay our module via a symlinked base dir
DRACUT_BASE="$BUILD_DIR/dracut-target"
make_dracut_base "$DRACUT_BASE" "$TARGET_DIR/dracut/modules.d/90nvmet-target"

# dracut needs root (device nodes inside the cpio archive)
sudo dracutbasedir="$DRACUT_BASE" dracut --force --kver "$KVER" \
    --add " nvmet-target " \
    --add-drivers " nvmet nvmet_rdma rdma_rxe ib_core rdma_cm virtio_net virtio_blk " \
    "$TARGET_INITRAMFS"

sudo chown "$(id -u):$(id -g)" "$TARGET_INITRAMFS"
log "built $TARGET_INITRAMFS"
