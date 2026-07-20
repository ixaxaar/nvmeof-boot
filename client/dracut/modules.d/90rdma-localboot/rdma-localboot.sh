#!/bin/bash
# rdma-localboot.sh — dracut pre-mount hook. THE stage-2 payload:
#   net up → soft-roce (unless real RNIC) → nvme connect → copy remote→local
#   → (stage 2.5: luks open) → disconnect → partition-scan → hand dracut a
#   ready local root= and let dracut do the mount + switch_root.
#
# Every step emits a phase mark: appended to $PHASE_LOG (tmpfs, survives the
# pivot via dracut's /run move) AND echoed to /dev/console as
#   BOOTPHASE <phase> <monotonic-seconds>
# so the host can reconstruct the whole timeline from the serial log.

. /etc/rdmaboot/env.sh
[ -f /tmp/rdb-localboot.env ] && . /tmp/rdb-localboot.env

# cmdline overrides (RDB_*) over env.sh defaults
DEV="${RDB_DEV:-$CLIENT_NETDEV}"
TGT="${RDB_TARGET:-$TARGET_IP}"
SUBNQN="${RDB_NQN:-$NQN}"
MODE="${RDB_COPYMODE:-$COPY_MODE}"
IPARG="${RDB_IP:-static}"
CR="${RDB_CRYPT:-$CRYPT}"
PLOG="${RDB_PHASELOG:-$PHASE_LOG}"
SOFF="${RDB_SAFE_OFFLOADS:-$SAFE_OFFLOADS}"

mark() {
    local ts
    ts="$(cut -d' ' -f1 /proc/uptime)"
    echo "$1 $ts" >> "$PLOG"
    echo "BOOTPHASE $1 $ts" > /dev/console
    info "rdma-localboot: phase $1 at ${ts}s"
}

rdb_die() {
    echo "rdma-localboot FATAL: $1" > /dev/console
    die "rdma-localboot: $1"
}

mark initramfs_entry

# ---------------------------------------------------------- 1. network up
ip link set lo up 2>/dev/null
ip link set "$DEV" up
ip addr flush dev "$DEV" 2>/dev/null
case "$IPARG" in
    dhcp)
        if command -v udhcpc >/dev/null 2>&1; then
            udhcpc -i "$DEV" -q -n
        elif command -v dhclient >/dev/null 2>&1; then
            dhclient "$DEV"
        else
            rdb_die "ip=dhcp but no dhcp client in initramfs (pre-stage-3); use rd.rdmalocalboot.ip=<ip>::<gw>:<mask>::<dev>"
        fi
        ;;
    static|"")
        ip addr add "$CLIENT_IP/$NETMASK" dev "$DEV"
        ;;
    *:*)
        # <ip>::<gw>:<mask>::<dev>   (gw may be empty)
        IFS=':' read -r _ip _ _gw _mask _ _dev <<< "$IPARG"
        ip addr add "${_ip}/${_mask:-24}" dev "${_dev:-$DEV}"
        [ -n "$_gw" ] && ip route add default via "$_gw" dev "${_dev:-$DEV}"
        ;;
    *)
        # bare CIDR, e.g. 10.210.0.2/24
        ip addr add "$IPARG" dev "$DEV"
        ;;
esac
info "rdma-localboot: $DEV has $(ip -4 -o addr show dev "$DEV" | awk '{print $4}')"
mark net_up

# --------------------------------------------- 2. soft-roce (POC) or real RNIC
if [ "$SOFF" = "1" ]; then
    # soft-roce over virtio can choke on GSO/checksum offload (AGENT.md gotchas)
    ethtool -K "$DEV" tso off gso off gro off >/dev/null 2>&1 || true
fi

modprobe ib_core 2>/dev/null
modprobe rdma_cm 2>/dev/null
if rdma link show | grep -v "link rxe" | grep -q .; then
    info "rdma-localboot: real RNIC present, skipping soft-roce"
else
    modprobe rdma_rxe
    rdma link add "$RXE_NAME" type rxe netdev "$DEV" \
        || rdb_die "rdma link add $RXE_NAME failed"
fi

i=0
until rdma link show | grep -q "link "; do
    sleep 0.1; i=$((i + 1))
    [ "$i" -ge 50 ] && rdb_die "no RDMA device appeared after 5s"
done
rdma link show > /dev/console
mark rdma_up

# -------------------------------------- 3. host NQN + connect remote namespace
modprobe nvme nvme_fabrics nvme_rdma
mkdir -p /etc/nvme
[ -s /etc/nvme/hostnqn ] || nvme gen-hostnqn > /etc/nvme/hostnqn

nvme connect -t rdma -a "$TGT" -s "$NVME_PORT" -n "$SUBNQN" \
    || rdb_die "nvme connect -t rdma -a $TGT -s $NVME_PORT -n $SUBNQN failed"

REMOTE=""
for i in $(seq 1 100); do
    REMOTE="$(resolve_remote_ns "$SUBNQN")" && break
    sleep 0.1
done
[ -n "$REMOTE" ] || rdb_die "remote namespace for $SUBNQN never appeared"
udevadm settle 2>/dev/null || true

# evidence capture (AGENT.md rule 7) — lands in the serial log artifact
{
    echo "--- nvme list-subsys ---"; nvme list-subsys
    echo "--- nvme list ---";        nvme list
} > /dev/console 2>&1
info "rdma-localboot: remote namespace is $REMOTE"
mark nvme_connected

# ------------------------------------------------------- 4. copy remote→local
LOCAL=""
for i in $(seq 1 100); do
    LOCAL="$(resolve_local_disk)" && break
    sleep 0.1
done
[ -n "$LOCAL" ] || rdb_die "local disk (serial '$LOCAL_NVME_SERIAL') not found in /dev/disk/by-id"

REMOTE_PART="$(part_path "$REMOTE")"
LOCAL_PART="$(part_path "$LOCAL")"

rsz="$(blockdev --getsz "$REMOTE")"
lsz="$(blockdev --getsz "$LOCAL")"
info "rdma-localboot: remote $REMOTE = $rsz sectors, local $LOCAL = $lsz sectors, mode=$MODE crypt=$CR"
[ "$lsz" -ge "$rsz" ] || rdb_die "local disk too small: $lsz < $rsz sectors"

mark copy_start
case "$MODE" in
    dd)
        echo "rdma-localboot: dd $REMOTE -> $LOCAL ($rsz sectors, block copy)" > /dev/console
        dd if="$REMOTE" of="$LOCAL" bs=16M oflag=direct conv=fsync status=none \
            || rdb_die "dd failed"
        ;;
    partclone)
        # fs-level: recreate the partition table locally, then clone only the
        # used blocks of the filesystem (mapper→mapper when crypt=1)
        sgdisk -Z "$LOCAL" >/dev/null 2>&1
        sgdisk -n 1:0:0 -t 1:8300 -c 1:"$ROOTFS_LABEL" "$LOCAL" >/dev/null \
            || rdb_die "sgdisk on $LOCAL failed"
        partprobe "$LOCAL"; udevadm settle 2>/dev/null || true
        wait_for_block "$LOCAL_PART" || rdb_die "$LOCAL_PART missing after partitioning"
        if [ "$CR" = "1" ]; then
            cryptsetup luksFormat --type luks2 --batch-mode \
                --key-file "$LUKS_KEYFILE_INITRD" "$LOCAL_PART" \
                || rdb_die "luksFormat on $LOCAL_PART failed"
            cryptsetup open --key-file "$LUKS_KEYFILE_INITRD" \
                "$LOCAL_PART" "$LUKS_MAPPER" \
                || rdb_die "luks open (local) failed"
            mark crypt_open
            cryptsetup open --read-only --key-file "$LUKS_KEYFILE_INITRD" \
                "$REMOTE_PART" "$LUKS_REMOTE_MAPPER" \
                || rdb_die "luks open (remote) failed"
            partclone.ext4 -b -L /var/log/partclone.log \
                -s "/dev/mapper/$LUKS_REMOTE_MAPPER" -d "/dev/mapper/$LUKS_MAPPER" \
                || rdb_die "partclone mapper→mapper failed"
            cryptsetup close "$LUKS_REMOTE_MAPPER"
        else
            partclone.ext4 -b -L /var/log/partclone.log \
                -s "$REMOTE_PART" -d "$LOCAL_PART" \
                || rdb_die "partclone failed"
        fi
        ;;
    *)
        rdb_die "unknown rd.rdmalocalboot.copymode: $MODE (want dd|partclone)"
        ;;
esac
mark copy_end

# the remote namespace is no longer needed — disconnect before the pivot,
# or the booted system inherits a live fabric session (AGENT.md gotchas)
nvme disconnect -n "$SUBNQN" || warn "rdma-localboot: nvme disconnect failed"

# ---------------------------------- 5. hand a ready local root to dracut
# partition-scan the freshly written disk, then block until the node exists
partprobe "$LOCAL" 2>/dev/null || true
udevadm settle 2>/dev/null || true
wait_for_block "$LOCAL_PART" 100 || rdb_die "$LOCAL_PART missing after copy"

if [ "$CR" = "1" ]; then
    if [ ! -b "/dev/mapper/$LUKS_MAPPER" ]; then
        cryptsetup open --key-file "$LUKS_KEYFILE_INITRD" \
            "$LOCAL_PART" "$LUKS_MAPPER" \
            || rdb_die "luks open of copied partition failed"
        mark crypt_open
    fi
    ROOTDEV="/dev/mapper/$LUKS_MAPPER"
else
    ROOTDEV="$LOCAL_PART"
fi

echo "$ROOTDEV" > /tmp/rdmalocalboot.root
echo "rdma-localboot: local root ready at $ROOTDEV (dracut mounts root= next)" > /dev/console
mark root_ready

# hook returns → dracut mounts root= (cmdline) and switch_roots for us
