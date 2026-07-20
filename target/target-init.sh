#!/bin/bash
# target-init.sh — /init of the target VM. This initramfs IS the target OS:
# bring up the network, bring up nvmet/RDMA via setup-target.sh, then stay
# alive with a shell on the serial console.
#
# No udev runs here: interfaces keep kernel names (eth0), block devices are
# devtmpfs nodes (/dev/vda). That is exactly what env.sh assumes.
export PATH=/usr/bin:/bin:/sbin

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
# devtmpfs already mounted by the kernel (CONFIG_DEVTMPFS_MOUNT=y)
mkdir -p /sys/kernel/config
mount -t configfs configfs /sys/kernel/config

. /etc/rdmaboot/env.sh

echo "[target-init] loading modules"
modprobe virtio_net

echo "[target-init] network: $TARGET_IP/$NETMASK on $TARGET_NETDEV"
ip link set lo up
ip link set "$TARGET_NETDEV" up
ip addr add "$TARGET_IP/$NETMASK" dev "$TARGET_NETDEV"

# soft-roce over virtio can choke on offloads (see AGENT.md gotchas)
if [ "$SAFE_OFFLOADS" = "1" ]; then
    ethtool -K "$TARGET_NETDEV" tso off gso off gro off 2>/dev/null
fi

if /sbin/setup-target.sh; then
    # gates wait for this exact marker
    echo "TARGET-READY nqn=$NQN ip=$TARGET_IP port=$NVME_PORT backing=$TARGET_BACKING_DEV"
else
    echo "TARGET-FAILED reason=setup-target"
fi

echo "[target-init] serving; shell on console (try: ls /sys/kernel/config/nvmet)"
while :; do
    setsid sh </dev/console >/dev/console 2>&1
    sleep 1
done
