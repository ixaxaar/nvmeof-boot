#!/usr/bin/env bash
# gate-1 — build-sanity gate between target bring-up and the full boot:
# both initramfs images exist and contain every module/binary/script the
# runtime path needs. Catches dracut packaging mistakes before a slow boot.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

need_cmd lsinitrd

fail=0
check_img() {  # check_img <image> <pattern...>
    local img="$1"; shift
    [ -f "$img" ] || { echo "  [MISSING] $img — run: make initramfs"; fail=1; return; }
    # capture once: piping lsinitrd into `grep -q` under pipefail races on SIGPIPE
    local contents pat
    contents="$(lsinitrd "$img")"
    for pat in "$@"; do
        if grep -qE "$pat" <<< "$contents"; then
            printf '  [ok]      %-40s in %s\n' "$pat" "$(basename "$img")"
        else
            printf '  [MISSING] %-40s in %s\n' "$pat" "$(basename "$img")"
            fail=1
        fi
    done
}

echo "[gate-1] client initramfs contents"
# NOTE: ext4/virtio_blk are built into the reference kernel (=y) — no .ko to
# check. partclone 0.3.47+ ships one unified binary (partclone.extfs) with
# per-fs symlinks. Hook paths are var/lib/dracut/hooks/... (dracut 111).
client_pats=(
    'nvme-rdma\.ko' 'nvme-fabrics\.ko' 'nvme\.ko' 'rdma_rxe\.ko' 'ib_core\.ko'
    'rdma_cm\.ko' 'virtio_net\.ko'
    'usr/bin/nvme$' 'usr/bin/jq$' 'usr/bin/rdma$' 'usr/bin/ip$'
    'partclone\.extfs' 'sgdisk$' 'partprobe$' 'ethtool$'
    'rdma-localboot\.sh$' 'parse-rdma-localboot\.sh$' 'etc/rdmaboot/env\.sh$'
)
[ "$CRYPT" = "1" ] && client_pats+=( 'dm-crypt\.ko' 'cryptsetup$' 'rdb/luks\.key$' )
check_img "$CLIENT_INITRAMFS" "${client_pats[@]}"

echo "[gate-1] target initramfs contents (hand-rolled cpio)"
check_target_img() {
    local img="$TARGET_INITRAMFS" pat
    [ -f "$img" ] || { echo "  [MISSING] $img — run: make initramfs-target"; fail=1; return; }
    local contents
    contents="$(zcat "$img" | cpio -t 2>/dev/null)"
    for pat in '^init$' 'busybox$' 'usr/bin/bash$' 'setup-target\.sh$' 'teardown-target\.sh$' \
               'etc/rdmaboot/env\.sh$' 'nvmet-rdma\.ko$' 'nvmet\.ko$' 'rdma_rxe\.ko$' \
               'ib_core\.ko$' 'virtio_net\.ko$' 'modules\.dep$' 'usr/bin/ip$' 'usr/bin/rdma$'; do
        if grep -qE "$pat" <<< "$contents"; then
            printf '  [ok]      %-40s in %s\n' "$pat" "$(basename "$img")"
        else
            printf '  [MISSING] %-40s in %s\n' "$pat" "$(basename "$img")"
            fail=1
        fi
    done
}
check_target_img

echo "[gate-1] payload image"
[ -f "$ROOTFS_IMG" ] || { echo "  [MISSING] $ROOTFS_IMG — run: make rootfs"; fail=1; }
[ -s "$BOOT_PROOF_FILE" ] || { echo "  [MISSING] $BOOT_PROOF_FILE"; fail=1; }

[ "$fail" = "0" ] || die "GATE-1 FAIL"
log "GATE-1 PASS (CRYPT=$CRYPT)"
