#!/usr/bin/env bash
# Dracut module 90nvmet-target: turns an initramfs into the entire target-VM
# OS. The target is "stock plumbing": modules + tools + our /init that runs
# setup-target.sh and then idles while serving the namespace.

check() {
    # included only when explicitly requested via --add
    return 0
}

depends() {
    return 0
}

installkernel() {
    instmods nvmet nvmet_rdma rdma_rxe ib_core rdma_cm virtio_net virtio_blk nvme nvme_core
}

install() {
    inst_multiple ip rdma nvme ethtool modprobe
    inst_simple "$moddir/../../../setup-target.sh"    /sbin/setup-target.sh
    inst_simple "$moddir/../../../teardown-target.sh" /sbin/teardown-target.sh
    inst_simple "$moddir/../../../../env.sh"          /etc/rdmaboot/env.sh
    # Replace dracut's /init entirely: this initramfs never pivots, it serves.
    inst_simple "$moddir/target-init.sh"              /init
}
