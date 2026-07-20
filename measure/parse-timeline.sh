#!/usr/bin/env bash
# measure/parse-timeline.sh — turn a serial log's BOOTPHASE marks into a
# per-phase delta table + total, with the run's metadata as header.
#
#   measure/parse-timeline.sh [serial-client.log]   # default: newest run
#
# Writes timeline.txt next to the log and prints it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./env.sh

LOG="${1:-}"
if [ -z "$LOG" ]; then
    LOG="$(ls -t "$ARTIFACTS_DIR"/*/serial-client.log 2>/dev/null | head -1 || true)"
fi
[ -n "$LOG" ] && [ -f "$LOG" ] || die "no serial-client.log found — boot the client first (make run-client / gate-2)"

DIR="$(dirname "$LOG")"
OUT="$DIR/timeline.txt"

meta() { grep "^$1=" "$DIR/env.txt" 2>/dev/null | cut -d= -f2- || echo "?"; }

{
    echo "# rdma-localboot timeline"
    echo "# date:        $(meta date)"
    echo "# log:         $LOG"
    echo "# copy_mode:   $(meta copy_mode)"
    echo "# crypt:       $(meta crypt)"
    echo "# transport:   soft-roce (rdma_rxe over virtio)"
    echo "# mtu:         $(meta mtu)"
    echo "# rootfs_img:  $(meta rootfs_img) ($(meta rootfs_size) bytes)"
    echo "# local_img:   $(meta local_img) ($(meta local_img_size) bytes)"
    echo "# note: POST/firmware time is NOT included (pre-boot; measure by hand/BMC)"
    echo
    awk '
        /^BOOTPHASE / {
            name=$2; t=$3+0
            if (!(name in seen)) { order[++n]=name; ts[name]=t; seen[name]=1 }
        }
        END {
            if (n==0) { print "no BOOTPHASE marks in log"; exit 1 }
            printf "%-18s %12s %12s\n", "phase", "t(s)", "delta(s)"
            printf "%-18s %12s %12s\n", "-----", "----", "--------"
            prev=ts[order[1]]
            for (i=1;i<=n;i++) {
                nm=order[i]
                if (i==1) printf "%-18s %12.3f %12s\n", nm, ts[nm], "-"
                else      printf "%-18s %12.3f %+12.3f\n", nm, ts[nm], ts[nm]-prev
                prev=ts[nm]
            }
            print  "------------------------------------------"
            printf "%-18s %12.3f s  (initramfs_entry -> %s)\n", "TOTAL", ts[order[n]]-ts[order[1]], order[n]
        }
    ' "$LOG"
} | tee "$OUT"
