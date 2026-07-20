# Two-Stage RDMA Diskless Boot POC

Boot Linux in two stages:

- **Stage 1** — netboot `vmlinuz` + `initramfs` (direct `-kernel/-initrd` for
  now; real PXE is stage 3, deferred).
- **Stage 2** — from inside the initramfs: attach a remote rootfs over
  **NVMe-oF/RDMA** (soft-RoCE), copy it to a local NVMe, `switch_root`.
- **Stage 2.5** — same, but the image is a **LUKS2** container: ciphertext on
  the wire and at rest, decrypted only on the client.

The full spec, ground rules, and gotchas are in [AGENT.md](AGENT.md). The
actual work is in stage 2; everything else is stock kernel (at least on arch).

Refer: https://wiki.archlinux.org/title/NVMe_over_Fabrics

```
┌─────────────────────┐         soft-RoCE / RDMA          ┌─────────────────────┐
│      TARGET VM      │◄─────────  over virtio  ─────────►│      CLIENT VM      │
│ initramfs OS:       │        (later: ConnectX)          │ diskless:           │
│  nvmet + nvmet-rdma │   rdb-br0 / 10.210.0.0/24         │  kernel+initramfs   │
│  backing rootfs.img │                                   │  hook: connect→copy │
│  10.210.0.1:4420    │                                   │   →(luks)→switch_   │
└─────────────────────┘                                   │   root, 10.210.0.2  │
                                                          │ local NVMe (empty)  │
                                                          └─────────────────────┘
```

## Quickstart

```sh
sudo ./bootstrap.sh        # 1. ONE-TIME: installs dracut, partclone, busybox (asks first)
make check                 # 2. verify kernel configs + tools (read-only)
make rootfs rootfs-crypt   # 3. build payload images (plain + LUKS)
make initramfs             # 4. build target + client initramfs
make net                   # 5. rdb-br0 + taps (runtime-only)
make target-up             # 6. boot target VM, wait for TARGET-READY
make gate-0                # 7. host: nvme discover/connect/list/disconnect
make gate-2                # 8. full client pivot, plaintext, dd
make gate-2.5              # 9. full client pivot, LUKS image
make measure               # 10. phase-by-phase timeline of the latest run
```

A/B the copy strategy on any client run:

```sh
make gate-2 COPY_MODE=partclone
make run-client COPY_MODE=partclone CRYPT=1
```
