#!/usr/bin/env bash
# bootstrap.sh — the ONLY script that changes anything on this host, and the
# only thing it does is install missing distro packages. Run it yourself:
#
#   ./bootstrap.sh            # show what would be installed, ask, then install
#   ./bootstrap.sh -y         # install without asking
#   ./bootstrap.sh --check    # verify deps only, change nothing (exit 1 if missing)
#
# What it does NOT do (by design, so your desktop stays intact):
#   - no modprobe / kernel module loading        (runtime scripts do that, inside VMs or via gates)
#   - no network configuration                   (make net creates rdb-br0/taps at runtime only)
#   - no writes under /etc, no systemctl, no sysctl, no udev rules
#   - no AUR, no makepkg, no pip, nothing outside pacman
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ./env.sh

ASSUME_YES=0
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)   ASSUME_YES=1 ;;
        --check)    CHECK_ONLY=1 ;;
        -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown argument: $arg (try --help)" ;;
    esac
done

# Packages this POC needs that are installable via pacman, mapped to the
# command that proves their presence.
declare -A PKG_FOR_CMD=(
    [dracut]=dracut            # builds both initramfs images
    [partclone.ext4]=partclone # fs-level copy mode (COPY_MODE=partclone)
    [busybox]=busybox          # payload rootfs userspace
)

# Commands that must already exist (we verify, but do not install, these —
# they were present on the reference host; if yours lacks one, install the
# named package yourself).
REQUIRED_CMDS=(
    qemu-system-x86_64   # qemu-base / qemu-full
    qemu-img
    nvme                 # nvme-cli
    ip rdma              # iproute2
    sgdisk               # gptfdisk
    mkfs.ext4            # e2fsprogs
    cryptsetup
    jq
    ethtool
    python3
    file
    losetup partprobe    # util-linux
)

main() {
    local missing_pkgs=() missing_cmds=() cmd

    log "checking required commands..."
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf '  [ok]      %s\n' "$cmd"
        else
            printf '  [MISSING] %s\n' "$cmd"
            missing_cmds+=("$cmd")
        fi
    done

    log "checking installable packages..."
    for cmd in "${!PKG_FOR_CMD[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf '  [ok]      %s (package %s)\n' "$cmd" "${PKG_FOR_CMD[$cmd]}"
        else
            printf '  [MISSING] %s -> package %s\n' "$cmd" "${PKG_FOR_CMD[$cmd]}"
            missing_pkgs+=("${PKG_FOR_CMD[$cmd]}")
        fi
    done

    if [ "${#missing_cmds[@]}" -gt 0 ]; then
        warn "these required tools are missing and are NOT auto-installed:"
        printf '       %s\n' "${missing_cmds[@]}"
        warn "install the matching packages, then re-run ./bootstrap.sh"
        exit 1
    fi

    # kernel config gate (pure read, no changes)
    ./check-kernel.sh --configs-only

    if [ "$CHECK_ONLY" = "1" ]; then
        if [ "${#missing_pkgs[@]}" -gt 0 ]; then
            log "would install: ${missing_pkgs[*]}"
            exit 1
        fi
        log "all dependencies satisfied"
        exit 0
    fi

    if [ "${#missing_pkgs[@]}" -eq 0 ]; then
        log "nothing to install — all dependencies satisfied"
        exit 0
    fi

    echo
    log "the following packages will be installed via pacman (additive only,"
    log "no configuration changes, no services enabled):"
    printf '       %s\n' "${missing_pkgs[@]}"
    echo
    if [ "$ASSUME_YES" != "1" ]; then
        read -r -p "proceed? [y/N] " reply
        case "$reply" in
            y|Y|yes) ;;
            *) log "aborted; nothing was changed"; exit 0 ;;
        esac
    fi

    sudo pacman -S --needed "${missing_pkgs[@]}"

    log "done. next steps:"
    cat <<'EOF'
  make check                          # re-verify kernel configs + tools
  make rootfs rootfs-crypt initramfs  # build payload + boot images
  make net target-up                  # bridge/taps + target VM
  make gate-0                         # nvme discover/connect from host
  make gate-2                         # full client pivot (plaintext)
  make gate-2.5                       # full client pivot (LUKS, stage 2.5)
  make measure                        # timeline from the latest run
EOF
}

main
