# Canonical boot phases

Every phase is marked with a monotonic timestamp (`/proc/uptime` field 1 —
cheap and available in the initramfs). The hook writes marks to two sinks:

1. the phase log file (`rd.rdmalocalboot.mark`, default `/run/boot-phases` —
   tmpfs; survives `switch_root` via dracut's `/run` move, the payload keeps
   appending to it), and
2. the serial console as `BOOTPHASE <phase> <seconds>` — captured host-side
   in `measure/artifacts/<run>/serial-*.log`, which is what
   `parse-timeline.sh` consumes.

## Phases in order

| phase              | marked by          | what just completed                                              |
|--------------------|--------------------|------------------------------------------------------------------|
| `initramfs_entry`  | pre-mount hook     | hook started (kernel + initramfs load done, dracut up)           |
| `net_up`           | pre-mount hook     | client netdev configured (static or dhcp)                        |
| `rdma_up`          | pre-mount hook     | rxe link (or real RNIC) present and visible via `rdma link show` |
| `nvme_connected`   | pre-mount hook     | `nvme connect` ok, remote namespace resolved by NQN              |
| `copy_start`       | pre-mount hook     | local disk resolved by-id, size asserted, copy begins            |
| `crypt_open`       | pre-mount hook     | stage 2.5 only: local LUKS mapper available. NOTE: position depends on copy mode — pre-copy for `partclone` (part of copy prep), post-copy for `dd` |
| `copy_end`         | pre-mount hook     | copy finished; `nvme disconnect` happens right after             |
| `root_ready`       | pre-mount hook     | local root partition exists + fsck-clean; dracut mounts root= next |
| `switch_root_done` | payload `/sbin/init` | first userspace instruction after the pivot                    |
| `userspace_ready`  | payload `/sbin/init` | minimal payload up; BOOT-PROOF printed to console              |

## Notes

- POST/firmware/pxe-rom time is **not** in any of these numbers — it is
  pre-boot. Measure it separately (hand/BMC); on real servers it dominates
  everything else. See README.
- Ballpark sanity (soft-roce in a VM is *slower* than real hardware):
  initramfs_entry→nvme_connected ≈ 1–3 s; copy = image size ÷ local write BW;
  copy_end→userspace_ready ≈ 1–2 s. A phase 10× off means something is wrong.
- The timeline header records: image size, `COPY_MODE`, `CRYPT`, transport
  (soft-roce vs real), MTU. Jumbo/PFC/ECN tuning is stage 4 — do not touch
  during functional stages.
