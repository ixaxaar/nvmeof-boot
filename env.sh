#!/usr/bin/env bash
# env.sh — single source of truth for the two-stage RDMA diskless boot POC.
#
# Every script sources this file. It is ALSO baked into the initramfs images
# at /etc/rdmaboot/env.sh, therefore:
#   - no side effects at source time (no commands run, nothing probed)
#   - boot hooks must only rely on the non-path variables below
# Override anything by exporting the var before running a script, e.g.
#   CRYPT=1 COPY_MODE=partclone make run-client

# ---------------------------------------------------------------- identity
NQN="${NQN:-nqn.2026-07.io.rdmaboot:rootfs}"  # nvmet subsystem NQN on the target
NVME_PORT="${NVME_PORT:-4420}"                # nvme-of/rdma service port

# ----------------------------------------------------------------- network
# Dedicated, namespaced netdevs (rdb-*). No NAT, no forwarding, no host
# routes, nothing outside this subnet is touched.
BRIDGE="${BRIDGE:-rdb-br0}"
TAP_TARGET="${TAP_TARGET:-rdb-tap0}"
TAP_CLIENT="${TAP_CLIENT:-rdb-tap1}"
SUBNET_PREFIX="${SUBNET_PREFIX:-10.210.0}"    # /24
NETMASK="${NETMASK:-24}"
HOST_IP="${HOST_IP:-${SUBNET_PREFIX}.254}"    # host end of the bridge (gate-0 rxe)
TARGET_IP="${TARGET_IP:-${SUBNET_PREFIX}.1}"
CLIENT_IP="${CLIENT_IP:-${SUBNET_PREFIX}.2}"
TARGET_MAC="${TARGET_MAC:-52:54:00:bd:00:01}"
CLIENT_MAC="${CLIENT_MAC:-52:54:00:bd:00:02}"
RXE_NAME="${RXE_NAME:-rxe0}"                  # soft-roce link name inside the VMs
GATE_RXE_NAME="${GATE_RXE_NAME:-rxe_gate0}"   # temporary host rxe link (gate-0 only)
TARGET_NETDEV="${TARGET_NETDEV:-eth0}"        # netdev name inside the target VM
CLIENT_NETDEV="${CLIENT_NETDEV:-eth0}"        # netdev name inside the client VM
MTU="${MTU:-1500}"                            # recorded in the timeline; jumbo = stage 4

# ------------------------------------------------------------- guest kernel
# Guests boot the HOST kernel so host-built initramfs modules always match.
KVER="${KVER:-$(uname -r)}"
KMODDIR="${KMODDIR:-/usr/lib/modules/$KVER}"
GUEST_KERNEL="${GUEST_KERNEL:-}"              # explicit override wins; else auto-detect

# ------------------------------------------------------------------- paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$ROOT_DIR/target"
CLIENT_DIR="$ROOT_DIR/client"
QEMU_DIR="$ROOT_DIR/qemu"
MEASURE_DIR="$ROOT_DIR/measure"
ARTIFACTS_DIR="$MEASURE_DIR/artifacts"
GATES_DIR="$ROOT_DIR/gates"
STATE_DIR="$ROOT_DIR/run"                     # pidfiles/sockets (gitignored)
BUILD_DIR="$ROOT_DIR/build"                   # scratch (dracut base dirs; gitignored)

ROOTFS_SIZE="${ROOTFS_SIZE:-1G}"              # sparse image apparent size
ROOTFS_LABEL="${ROOTFS_LABEL:-rdbroot}"
ROOTFS_IMG_PLAIN="$TARGET_DIR/rootfs.img"
ROOTFS_IMG_CRYPT="$TARGET_DIR/rootfs-crypt.img"
BOOT_PROOF_FILE="$TARGET_DIR/boot-proof.uuid"

LOCAL_IMG="$CLIENT_DIR/local.img"             # client's empty local NVMe (raw file)
LOCAL_IMG_SIZE="${LOCAL_IMG_SIZE:-2G}"        # must be >= remote namespace size

CLIENT_INITRAMFS="$CLIENT_DIR/initramfs-rdmaboot.img"
TARGET_INITRAMFS="$TARGET_DIR/initramfs-target.img"

# ------------------------------------------------------- crypto (stage 2.5)
CRYPT="${CRYPT:-0}"                           # 1 = LUKS2 image, unlocked on the client
LUKS_KEYFILE="${LUKS_KEYFILE:-$TARGET_DIR/luks.key}"   # POC key, 0600, gitignored
LUKS_KEYFILE_INITRD="/etc/rdb/luks.key"       # path inside the client initramfs
LUKS_MAPPER="${LUKS_MAPPER:-rdbroot}"         # unlocked local root mapper name
LUKS_REMOTE_MAPPER="${LUKS_REMOTE_MAPPER:-rdbremote}"  # read-only remote (partclone)

if [ "$CRYPT" = "1" ]; then
    ROOTFS_IMG="$ROOTFS_IMG_CRYPT"
    ROOT_ARG="/dev/mapper/$LUKS_MAPPER"
else
    ROOTFS_IMG="$ROOTFS_IMG_PLAIN"
    ROOT_ARG=""                               # filled below (needs LOCAL_BYID)
fi

# ------------------------------------------- device selectors (rule #4: by ID)
LOCAL_NVME_SERIAL="${LOCAL_NVME_SERIAL:-NVMELOCAL0}"
# qemu -device nvme,serial=... gives by-id: nvme-<model_with_underscores>_<serial>
LOCAL_BYID="${LOCAL_BYID:-/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_${LOCAL_NVME_SERIAL}}"
TARGET_BACKING_DEV="${TARGET_BACKING_DEV:-/dev/vda}"  # rootfs.img inside target VM
[ -n "$ROOT_ARG" ] || ROOT_ARG="${LOCAL_BYID}-part1"

# ------------------------------------------------------------- boot behaviour
COPY_MODE="${COPY_MODE:-dd}"                  # dd | partclone
PHASE_LOG="${PHASE_LOG:-/run/boot-phases}"    # tmpfs; survives switch_root via dracut
SAFE_OFFLOADS="${SAFE_OFFLOADS:-1}"           # ethtool -K tso/gso/gro off before rxe
VM_MEM="${VM_MEM:-2048}"
VM_SMP="${VM_SMP:-2}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"           # gate-2: full client boot budget (s)
TARGET_READY_TIMEOUT="${TARGET_READY_TIMEOUT:-120}"   # gate-0/target-up budget (s)

# ----------------------------------------------------------------- helpers
log()  { printf '[rdmaboot] %s\n' "$*" >&2; }
warn() { printf '[rdmaboot][warn] %s\n' "$*" >&2; }
die()  { printf '[rdmaboot][error] %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: '$1' — run ./bootstrap.sh --check"
}

# Find a host kernel image matching the running kernel (guests boot it).
detect_guest_kernel() {
    if [ -n "$GUEST_KERNEL" ]; then
        [ -r "$GUEST_KERNEL" ] || die "GUEST_KERNEL not readable: $GUEST_KERNEL"
        echo "$GUEST_KERNEL"; return 0
    fi
    local k
    for k in "/boot/vmlinuz-$KVER" /boot/vmlinuz-*; do
        [ -r "$k" ] || continue
        if file -b "$k" 2>/dev/null | grep -q "version $KVER "; then
            echo "$k"; return 0
        fi
    done
    die "no kernel image in /boot matching running kernel '$KVER'; set GUEST_KERNEL in env.sh"
}

# Copy a dynamically-linked binary + its shared-library closure into a rootfs
# tree, preserving absolute paths. Static binaries (e.g. Manjaro's busybox)
# are just copied. Used by build-rootfs.sh (payload userspace).
inst_prog() {
    local bin="$1" dest="$2" lib libs
    [ -x "$bin" ] || die "inst_prog: not executable: $bin"
    cp --parents -L "$bin" "$dest"
    # NB: ldd exits 1 for static binaries — keep this set -e/pipefail safe
    libs="$(ldd "$bin" 2>/dev/null | awk '/=> \//{print $3} /^\//{print $1}' | sort -u || true)"
    [ -n "$libs" ] || return 0
    while IFS= read -r lib; do
        if [ -f "$lib" ]; then
            cp --parents -L "$lib" "$dest"
        fi
    done <<< "$libs"
}

# dracut 111 has no --modules-dir: modules resolve only from
# $dracutbasedir/modules.d — but dracutbasedir itself is honored from the
# environment. Build a private base dir of symlinks (system dracut + our
# module(s) overlaid). Nothing outside the repo is touched.
make_dracut_base() {  # make_dracut_base <destdir> <extra-module-dir>...
    local dest="$1"; shift
    local sys=/usr/lib/dracut f
    [ -d "$sys/modules.d" ] || die "system dracut not found at $sys"
    rm -rf "$dest"
    mkdir -p "$dest/modules.d"
    for f in "$sys"/*; do
        [ "${f##*/}" = "modules.d" ] || ln -sfn "$f" "$dest/${f##*/}"
    done
    for f in "$sys"/modules.d/*; do
        ln -sfn "$f" "$dest/modules.d/${f##*/}"
    done
    for f in "$@"; do
        ln -sfn "$(realpath "$f")" "$dest/modules.d/${f##*/}"
    done
}

# Resolve the remote namespace block device by subsystem NQN via sysfs.
# NEVER by enumeration index (ground rule #4). Works on host and in initramfs.
resolve_remote_ns() {
    local nqn="${1:-$NQN}" ctl name ns
    for ctl in /sys/class/nvme-fabrics/ctl/*; do
        [ -f "$ctl/subsysnqn" ] || continue
        [ "$(cat "$ctl/subsysnqn")" = "$nqn" ] || continue
        name="${ctl##*/}"                     # fabrics controller name, e.g. nvme1
        for ns in /sys/block/"${name}"n*; do
            [ -e "$ns" ] || continue
            echo "/dev/${ns##*/}"; return 0
        done
    done
    return 1
}

# Resolve the client's local NVMe by its qemu serial, via /dev/disk/by-id.
resolve_local_disk() {
    local p
    for p in /dev/disk/by-id/nvme-*"${LOCAL_NVME_SERIAL}"*; do
        case "$p" in *-part*) continue ;; esac
        [ -b "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Map a whole-disk path to its first-partition path.
part_path() {
    case "$1" in
        /dev/disk/by-id/*)      echo "$1-part1" ;;
        /dev/nvme*n[0-9])       echo "${1}p1" ;;
        /dev/mapper/*)          echo "${1}p1" ;;
        *)                      echo "${1}1" ;;
    esac
}

# Wait (up to ~$2 deciseconds, default 10s) for a block device node to appear.
wait_for_block() {
    local dev="$1" tries="${2:-100}" i
    for i in $(seq 1 "$tries"); do
        [ -b "$dev" ] && return 0
        sleep 0.1
    done
    return 1
}
