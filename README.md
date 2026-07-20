# Two-Stage RDMA Diskless Boot POC

Boot Linux in two stages:

- **Stage 1** — netboot `vmlinuz` + `initramfs` (direct `-kernel/-initrd` for
  now; real PXE is stage 3, deferred).
- **Stage 2** — from inside the initramfs: attach a remote rootfs over
  **NVMe-oF/RDMA** (soft-RoCE), copy it to a local NVMe, `switch_root`.
- **Stage 2.5** — same, but the image is a **LUKS2** container: ciphertext on
  the wire and at rest, decrypted only on the client.

The full spec, ground rules, and gotchas are in [AGENT.md](AGENT.md). The
load-bearing part is stage 2; everything else is stock plumbing.

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

## What changes on your machine (and what doesn't)

**The only persistent change** is `bootstrap.sh` installing three distro
packages — additive, nothing removed, no configs edited, no services enabled.
It asks before doing anything; `--check` is a pure read-only audit.

**Everything else is runtime-only and namespaced:**

- network: `rdb-br0` + `rdb-tap0/1` — created by `make net`, removed by
  `make net-down`. No NAT, no forwarding, no sysctls, no `/etc` writes.
  Existing interfaces (incl. docker bridges, VPNs) are never touched; setup
  refuses to run if `10.210.0.0/24` collides with anything you have.
- kernel modules: loaded only inside the throwaway VMs, except gate-0 which
  `modprobe`s `rdma_rxe nvme_rdma nvme_fabrics` on the host and adds a
  temporary `rxe_gate0` link it always removes (trap on exit).
- all state (images, pidfiles, sockets, serial logs) lives inside this repo.
- nothing survives a reboot even if you skip every teardown.

Undo a session completely: `make target-down net-down clean`.

## Stage 2.5 — encrypted images

`rootfs-crypt.img` is a GPT whose single partition is a **LUKS2** container
holding the same ext4 payload. The client copies ciphertext (dd), or — in
partclone mode — unlocks both sides locally and clones mapper→mapper. The
key never leaves the client.

**Security note (POC-grade):** the LUKS key (`target/luks.key`, mode 600,
gitignored) is baked into the client initramfs. Anyone with that initramfs
has the key. Fine for a lab POC; a real deployment wants TPM2 or
clevis/tang (NBDE) key delivery — see "Next steps". Also,
`attr_allow_any_host=1` on the target means any client can connect.

## Measurement

Every boot writes `BOOTPHASE <name> <monotonic-s>` marks to the serial log;
`make measure` renders the delta table (see `measure/phases.md` for the
canonical phase list). Runs land in `measure/artifacts/<run>/` with the
serial log, rendered cmdline, env, and timeline.

**POST/firmware time is not in these numbers.** It is pre-boot and, on real
servers, dominates everything else — measure it separately (hand/BMC) before
drawing conclusions from the kernel-onward timeline.

**Open design question** (answered here once we have runs): *copy-then-boot
vs boot-read-only-off-fabric-then-background-copy.* This repo builds the
former; the matrix to fill is {dd, partclone} × {plain, crypt} × {soft-roce}.
Run gates 2/2.5 with both `COPY_MODE`s, collect `measure/artifacts/*/timeline.txt`,
compare `copy_start→copy_end` against `initramfs_entry→userspace_ready` totals —
if copy time dominates, hiding it behind a background pivot wins.

## Troubleshooting

- serial logs are ground truth: `measure/artifacts/*/serial-*.log`; attach
  live with `make serial-target` / `make serial-client`.
- `rdma-localboot FATAL: ...` on the client console tells you which phase died.
- device mix-ups are ruled out by construction: remote namespace is resolved
  by subsystem NQN via sysfs, local disk by qemu serial via
  `/dev/disk/by-id/` — never by `/dev/nvmeN` index (AGENT.md rule #4).
- soft-roce weirdness over virtio: the hook already does
  `ethtool -K <dev> tso off gso off gro off` (disable with
  `rd.rdmalocalboot.safeoffloads=0`).
- if dracut's mount of the copied root ever fights us, the documented
  fallback is a manual `mount /sysroot; exec switch_root` inside the hook —
  not needed so far (AGENT.md §2, pivot integration).

## Out of scope (per AGENT.md) / next steps

- **Stage 3: real PXE** (dnsmasq TFTP/HTTP + iPXE chainload) — `netboot/`
  deliberately not built until gates 0–2 pass.
- Real ConnectX swap-in for perf numbers; PFC/ECN/jumbo (stage 4 only).
- TPM2 / clevis-tang (NBDE) key delivery; NVMe-TLS on the fabric.
- Multi-client fan-out, image versioning, NQN allow-listing, A/B slots.
