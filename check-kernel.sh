#!/usr/bin/env bash
# check-kernel.sh — verify the running kernel has every config this POC needs
# (as module or built-in) and that required tools exist. Pure read-only check;
# fails loud. The guest VMs boot this same kernel, so one check covers both.
#
#   ./check-kernel.sh                  # configs + tools
#   ./check-kernel.sh --configs-only   # configs only (used by bootstrap.sh)
set -euo pipefail

CONFIGS_ONLY=0
[ "${1:-}" = "--configs-only" ] && CONFIGS_ONLY=1

REQUIRED_CONFIGS=(
    CONFIG_INFINIBAND
    CONFIG_INFINIBAND_USER_ACCESS
    CONFIG_RDMA_RXE
    CONFIG_NVME_CORE
    CONFIG_BLK_DEV_NVME
    CONFIG_NVME_FABRICS
    CONFIG_NVME_RDMA
    CONFIG_NVME_TARGET
    CONFIG_NVME_TARGET_RDMA
    CONFIG_DM_CRYPT            # stage 2.5
    CONFIG_EXT4_FS
    CONFIG_CONFIGFS_FS         # nvmet
    CONFIG_VIRTIO_NET
    CONFIG_VIRTIO_PCI
    CONFIG_DEVTMPFS
)

fail=0

# --- kernel configs ---------------------------------------------------------
cfg_src=""
if [ -r /proc/config.gz ]; then
    cfg_src="/proc/config.gz"
    cfg_dump() { zcat /proc/config.gz; }
elif [ -r "/boot/config-$(uname -r)" ]; then
    cfg_src="/boot/config-$(uname -r)"
    cfg_dump() { cat "/boot/config-$(uname -r)"; }
else
    echo "[check-kernel][error] no readable kernel config (/proc/config.gz or /boot/config-$(uname -r))" >&2
    exit 1
fi

# dump once into a variable: piping zcat into `grep -q` under pipefail races
# (grep exits on first match, zcat dies on SIGPIPE, pipeline reports failure)
CFG_TEXT="$(cfg_dump)"

echo "[check-kernel] kernel config source: $cfg_src"
for c in "${REQUIRED_CONFIGS[@]}"; do
    if grep -qE "^${c}=[ym]" <<< "$CFG_TEXT"; then
        printf '  [ok]      %s=%s\n' "$c" "$(grep -oE "^${c}=[ym]" <<< "$CFG_TEXT" | cut -d= -f2)"
    else
        printf '  [MISSING] %s\n' "$c"
        fail=1
    fi
done

# --- tools ------------------------------------------------------------------
if [ "$CONFIGS_ONLY" != "1" ]; then
    echo "[check-kernel] tools:"
    for t in qemu-system-x86_64 qemu-img nvme ip rdma dracut lsinitrd sgdisk \
             mkfs.ext4 cryptsetup jq ethtool python3 busybox partclone.ext4 \
             file losetup partprobe; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  [ok]      %s\n' "$t"
        else
            printf '  [MISSING] %s (run ./bootstrap.sh)\n' "$t"
            fail=1
        fi
    done
    if [ ! -w /dev/kvm ] || [ ! -r /dev/kvm ]; then
        echo "  [MISSING] /dev/kvm access for $(id -un)"
        fail=1
    else
        echo "  [ok]      /dev/kvm accessible"
    fi
fi

if [ "$fail" != "0" ]; then
    echo "[check-kernel][error] prerequisites missing" >&2
    exit 1
fi
echo "[check-kernel] all good"
