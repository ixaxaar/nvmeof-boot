#!/usr/bin/env bash
# Dracut module 90rdma-localboot — THE stage-2 payload. We deliberately do
# not use dracut's built-in nvmf autoconnect; we own the logic end to end:
# net → soft-roce → nvme connect → copy remote→local → (luks) → mark root.

check() {
    return 0
}

depends() {
    # NOTE: no dependency on dracut's 'network' or 'nvmf' modules — the hook
    # does its own netdev/RDMA setup.
    return 0
}

installkernel() {
    instmods nvme nvme_core nvme_fabrics nvme_rdma rdma_rxe ib_core rdma_cm virtio_net ext4
    if [ "${RDB_CRYPT:-0}" = "1" ]; then
        instmods dm_crypt dm_mod
    fi
}

install() {
    inst_multiple ip rdma nvme jq ethtool partprobe sgdisk blockdev blkid udevadm
    inst_multiple partclone.ext4

    if [ "${RDB_CRYPT:-0}" = "1" ]; then
        [ -s "${RDB_LUKS_KEYFILE:-}" ] || \
            { dwarn "rdma-localboot: CRYPT=1 but no keyfile at RDB_LUKS_KEYFILE"; return 1; }
        inst_multiple cryptsetup
        inst_simple "$RDB_LUKS_KEYFILE" "$RDB_LUKS_KEYFILE_INITRD"
        chmod 0400 "${initdir}${RDB_LUKS_KEYFILE_INITRD}"
    fi

    inst_hook cmdline   50 "$moddir/parse-rdma-localboot.sh"
    inst_hook pre-mount 90 "$moddir/rdma-localboot.sh"
    inst_simple "$moddir/../../../../env.sh" /etc/rdmaboot/env.sh
}
