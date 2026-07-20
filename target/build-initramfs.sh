#!/usr/bin/env bash
# target/build-initramfs.sh — build the target VM's initramfs OS, hand-rolled
# cpio (no dracut). Why not dracut: dracut 111 builds a systemd initramfs and
# owns /init; our whole target OS *is* the init script, so we keep full
# control instead (AGENT.md decisions log #1).
#
# Contents: bash (our scripts are bash), busybox (core applets), iproute2's
# ip+rdma, nvme, ethtool, the dep-closure of nvmet_rdma/rdma_rxe/virtio_net
# (decompressed: busybox modprobe + plain .ko = zero surprises), our
# setup/teardown scripts, env.sh, and target-init.sh as /init.
#
# Runs unprivileged: static busybox, CONFIG_DEVTMPFS_MOUNT=y (kernel mounts
# devtmpfs before /init, so no static device nodes needed).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

for c in busybox depmod cpio gzip zstd realpath; do need_cmd "$c"; done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
INITRD="$WORK/initrd"
mkdir -p "$INITRD"/{proc,sys,dev,etc/rdmaboot,usr/bin}
mkdir -p "$INITRD/sys/kernel/config"

# usrmerge-compatible layout (Arch): bin,sbin,lib,lib64 → usr/*
ln -s usr/bin "$INITRD/bin"
ln -s usr/bin "$INITRD/sbin"
ln -s usr/lib "$INITRD/lib"
ln -s usr/lib "$INITRD/lib64"

log "staging userspace (bash, busybox, ip, rdma, nvme, ethtool)"
inst_prog "$(command -v bash)"    "$INITRD"
inst_prog "$(command -v busybox)" "$INITRD"
inst_prog "$(command -v ip)"      "$INITRD"
inst_prog "$(command -v rdma)"    "$INITRD"
inst_prog "$(command -v nvme)"    "$INITRD"
inst_prog "$(command -v ethtool)" "$INITRD"

# busybox applet symlinks the scripts use
for app in sh mount umount mkdir echo cat sleep cut grep tee rmdir ln seq setsid sync; do
    ln -sfn busybox "$INITRD/usr/bin/$app"
done

# our scripts + shared env
cp "$TARGET_DIR/target-init.sh"     "$INITRD/init"
cp "$TARGET_DIR/setup-target.sh"    "$INITRD/usr/bin/setup-target.sh"
cp "$TARGET_DIR/teardown-target.sh" "$INITRD/usr/bin/teardown-target.sh"
cp env.sh                           "$INITRD/etc/rdmaboot/env.sh"
chmod +x "$INITRD/init" "$INITRD/usr/bin/setup-target.sh" "$INITRD/usr/bin/teardown-target.sh"

# kernel modules: full dependency closure, DECOMPRESSED to plain .ko so
# busybox modprobe (no guaranteed zstd support) can load them
log "staging kernel modules ($KVER): nvmet_rdma + rdma_rxe + virtio_net closures"
# NB: modprobe --show-depends accepts ONE module (extra args become module
# parameters!) — query each top module separately.
MODS="$(for top in nvmet_rdma rdma_rxe virtio_net; do
            modprobe --show-depends "$top"
        done | awk '/^insmod/{print $2}' | sort -u)"
[ -n "$MODS" ] || die "modprobe --show-depends returned nothing"
for m in $MODS; do
    rp="$(realpath "$m")"
    case "$rp" in
        *.zst)
            mkdir -p "$INITRD$(dirname "$rp")"
            zstd -dc "$rp" > "$INITRD${rp%.zst}"
            ;;
        *)
            cp --parents -L "$rp" "$INITRD"
            ;;
    esac
done

depmod -b "$INITRD" "$KVER"
[ -f "$INITRD/usr/lib/modules/$KVER/modules.dep" ] || die "depmod produced no modules.dep"

log "packing $TARGET_INITRAMFS"
( cd "$INITRD" && find . -print | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$TARGET_INITRAMFS"

log "built $TARGET_INITRAMFS ($(stat -c %s "$TARGET_INITRAMFS") bytes, $(echo "$MODS" | wc -l) modules)"
