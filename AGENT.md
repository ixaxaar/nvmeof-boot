# Two-Stage RDMA Diskless Boot POC

## What this project is

A proof-of-concept for booting Linux in two stages:

- **Stage 1**: netboot `vmlinuz` + `initramfs` (PXE/HTTP).
- **Stage 2**: from inside the initramfs, attach a remote rootfs over **NVMe-oF/RDMA**, copy it to a **local NVMe**, then `switch_root` into the local disk.

The novel, load-bearing part is stage 2: **connect remote NVMe namespace → copy to local → pivot.** Everything else is stock plumbing. Do not gold-plate the plumbing.

The end goal is a working pipeline **and a phase-by-phase timeline** proving where the boot time goes.

---

## Ground rules for the implementing agent (read before writing code)

1. **Build in stages, gated.** The build order below has explicit Definition-of-Done gates. Do not start stage N+1 until stage N's gate passes empirically (not "should work" — actually run it). Commit at each gate.
2. **No RDMA hardware required.** Develop the entire software path on **soft-RoCE (`rdma_rxe`)** over virtio NICs in QEMU. Real ConnectX is a swap-in at the very end, for perf numbers only. Never block progress on hardware.
3. **Measure before optimizing.** The deliverable includes a timeline. Instrument first; tune second. Do not add PFC/ECN/jumbo-frame tuning during the functional stages — it's noise until stage 4.
4. **Identify NVMe devices by ID, never by index.** After `nvme connect`, the remote namespace and the local disk *both* appear as `/dev/nvme*`. Enumeration order is **not stable**. Always resolve devices via `/dev/disk/by-id/`, `nvme list -o json` + model/serial, or subsystem NQN. Hardcoding `/dev/nvme0n1` vs `/dev/nvme1n1` is a bug, not a shortcut. This is the single most common way this POC breaks.
5. **Keep the two copy strategies separable.** Block-level (`dd`) and fs-level (`partclone`/`rsync`) are both wanted. Put the copy behind one function with a `COPY_MODE` switch so we can A/B them in the timeline.
6. **Everything scripted and idempotent.** Setup scripts must be re-runnable (teardown + setup). No manual configfs poking that isn't captured in a script.
7. **When something fails, capture the evidence.** `dmesg`, `rdma link show`, `nvme list-subsys`, and the phase log go into `measure/artifacts/` on every run.

---

## Topology

```
┌─────────────────────┐         soft-RoCE / RDMA          ┌─────────────────────┐
│      TARGET VM      │◄─────────  over virtio  ─────────►│      CLIENT VM      │
│  (remote storage)   │        (later: ConnectX)          │  (diskless boot)    │
│                     │                                   │                     │
│  nvmet + nvmet-rdma │                                   │  initramfs:         │
│  backing: rootfs.img│                                   │   nvme-rdma connect │
│  port 4420          │                                   │   → copy → switch_  │
│                     │                                   │      root to local  │
│                     │                                   │  local: nvme0 (2nd  │
│                     │                                   │   qemu -drive)      │
└─────────────────────┘                                   └─────────────────────┘
```

Both VMs on one host, connected by a QEMU tap/bridge. The client gets **two** disks: none needed for root (it netboots), plus one empty local NVMe as the copy target.

For fast iteration, boot the client with `qemu -kernel/-initrd/-append` directly. Real PXE is **stage 3**, added last.

---

## Repo layout (as built; supersedes earlier drafts)

```
nvme-boot/
├── AGENT.md                      # this file
├── README.md                     # human quickstart
├── Makefile                      # top-level orchestration (targets below)
├── bootstrap.sh                  # THE ONLY host-changing script: pacman-installs
│                                 #   dracut/partclone/busybox (prompts; --check = read-only)
├── check-kernel.sh               # grep kernel configs + tools, fail loud
├── env.sh                        # shared vars: NQN, IPs, ports, device selectors, helpers
├── .gitignore
├── target/
│   ├── build-rootfs.sh           # payload rootfs.img (plain ext4) / rootfs-crypt.img (LUKS, CRYPT=1)
│   ├── build-initramfs.sh        # target VM's initramfs OS — HAND-ROLLED cpio (see decisions log)
│   ├── setup-target.sh           # nvmet configfs bring-up (idempotent; runs inside target VM)
│   ├── teardown-target.sh
│   └── target-init.sh            # /init of the target VM: net up → setup-target.sh → TARGET-READY → idle
├── client/
│   ├── build-initramfs.sh        # dracut invocation (CRYPT=1 bakes in the LUKS key)
│   ├── kernel-cmdline.txt        # canonical cmdline (documented per-arg, @VARS@ rendered)
│   └── dracut/modules.d/90rdma-localboot/
│       ├── module-setup.sh       # dracut: declare deps, install hook + bins (+cryptsetup/dm_crypt)
│       ├── rdma-localboot.sh     # THE HOOK: net → rdma → connect → copy → (luks) → mark root
│       └── parse-rdma-localboot.sh# parse rd.rdmalocalboot.* cmdline args → state file
├── qemu/
│   ├── net-setup.sh              # rdb-br0 + rdb-tap0/1 (runtime-only, idempotent)
│   ├── net-teardown.sh
│   ├── run-target.sh             # boot target VM (--daemon | foreground stdio)
│   ├── run-client.sh             # boot client VM; renders cmdline; artifacts per run
│   └── serial-expect.py          # stdlib serial-socket expect helper for gates
├── gates/
│   ├── gate-0.sh                 # discover/connect/list/disconnect from the host
│   ├── gate-1.sh                 # initramfs contents sanity (lsinitrd)
│   ├── gate-2.sh                 # full client pivot; BOOT-PROOF; fabric gone; phases complete
│   ├── gate-2.5.sh               # gate-2 with CRYPT=1 (+ root on LUKS mapper)
│   └── gate-3.sh                 # stub, exit 77 (stage 3 deferred)
├── measure/
│   ├── phases.md                 # canonical list of phases + what marks each
│   ├── parse-timeline.sh         # BOOTPHASE log → table + total + run metadata
│   └── artifacts/                # per-run serial logs, env, timelines (gitignored)
└── netboot/                      # STAGE 3 — deliberately NOT created yet
```

`env.sh` is the single source of truth for: subsystem NQN, host NQN, target IP, port (4420), soft-roce netdev name, and — critically — the **device-selector strings** (qemu nvme serial `NVMELOCAL0` for "local disk"; subsystem-NQN sysfs match for "remote namespace").

---

## Component specs

### 1. Target — remote NVMe-oF/RDMA storage

**Modules:** `nvmet nvmet-rdma rdma_rxe ib_core rdma_cm`.

**`build-rootfs.sh`** must produce a genuinely bootable rootfs image (`rootfs.img`):
- A partition table with an ext4 (or xfs) root partition.
- A minimal but *complete* userspace with an init (`systemd` or busybox init — busybox is faster to prove the pivot).
- Distinguishable content so we can verify the pivot actually landed here (e.g. a `/etc/BOOT-PROOF` file with a UUID we grep for post-boot).
- Keep it small (≤ 2 GB) so copy times are fast to iterate on. Note the size in the timeline output.

**`setup-target.sh`** (configfs, idempotent — teardown first if already present):
```sh
modprobe nvmet nvmet-rdma rdma_rxe
# soft-roce link (skip / no-op if a real RNIC is present)
rdma link add rxe0 type rxe netdev "$TARGET_NETDEV" 2>/dev/null || true

CFG=/sys/kernel/config/nvmet
mkdir -p "$CFG/subsystems/$NQN"
echo 1 > "$CFG/subsystems/$NQN/attr_allow_any_host"
mkdir -p "$CFG/subsystems/$NQN/namespaces/1"
echo -n "$BACKING_DEV" > "$CFG/subsystems/$NQN/namespaces/1/device_path"
echo 1 > "$CFG/subsystems/$NQN/namespaces/1/enable"

mkdir -p "$CFG/ports/1"
echo "$TARGET_IP" > "$CFG/ports/1/addr_traddr"
echo rdma       > "$CFG/ports/1/addr_trtype"
echo 4420       > "$CFG/ports/1/addr_trsvcid"
echo ipv4       > "$CFG/ports/1/addr_adrfam"
ln -s "$CFG/subsystems/$NQN" "$CFG/ports/1/subsystems/$NQN"
```
`$BACKING_DEV` = a loop device over `rootfs.img` or a raw partition/LV. Prefer a raw LV/partition for realistic block behavior; loop is fine for first light.

**Gate (stage 0):** from a *third* host (or the target itself), `nvme discover -t rdma -a $TARGET_IP -s 4420` lists the subsystem, and `nvme connect …` then `nvme list` shows the namespace with the right size. Disconnect cleanly. **No boot involved yet.** If this doesn't pass, nothing downstream will.

### 2. Client — the initramfs (the actual work)

**Kernel modules that must be in the initramfs:**
`rdma_rxe` (soft-roce POC), NIC driver (real hw), `ib_core rdma_cm`, `nvme nvme_core nvme_fabrics nvme_rdma`.

**Userspace tools in the initramfs:** `ip` + `rdma` (iproute2), `nvme` (nvme-cli), `dd`, and `partclone.ext4` (if fs-mode). dracut's `module-setup.sh` `inst`/`inst_multiple` these.

**Approach: a custom dracut module `90rdma-localboot`.** We deliberately do **not** rely on dracut's built-in `nvmf` autoconnect — its RDMA path is less battle-tested than TCP/FC, and the copy+pivot is custom anyway. We own the logic end to end.

`rdma-localboot.sh` runs as a **`pre-mount` hook** and does, in strict order, emitting a phase timestamp before each step (see Measurement):

```sh
# 0. entry marker
mark initramfs_entry

# 1. network up (dhcp or static from cmdline)
ip link set "$DEV" up
configure_ip "$DEV"            # dhclient or static per rd.rdmalocalboot.ip
mark net_up

# 2. soft-roce (POC only; detect real RNIC and skip)
if ! has_real_rnic; then
    rdma link add rxe0 type rxe netdev "$DEV"
fi
wait_for_rdma_device
mark rdma_up

# 3. set host NQN, connect remote namespace
[ -s /etc/nvme/hostnqn ] || nvme gen-hostnqn > /etc/nvme/hostnqn
nvme connect -t rdma -a "$TARGET_IP" -s 4420 -n "$NQN"
REMOTE=$(resolve_remote_ns)    # by model/serial/subsysnqn — NEVER by index
mark nvme_connected

# 4. copy remote → local
LOCAL=$(resolve_local_disk)    # by-id, the empty local nvme
mark copy_start
copy "$REMOTE" "$LOCAL"        # dispatches on COPY_MODE (dd | partclone)
mark copy_end

# 5. hand the local root to dracut and let it mount+pivot
#    (partition-scan the freshly-written local disk first)
partprobe "$LOCAL"; udevadm settle
echo "$(local_root_partition "$LOCAL")" > /tmp/rdmalocalboot.root
mark root_ready
```

**Pivot integration:** simplest robust path — set `root=/dev/disk/by-id/…local…-part2` (resolved) on the cmdline, and make the hook **block in `pre-mount` until the local root partition exists and fsck-clean**. dracut then performs the mount + `switch_root` itself. Do **not** hand-roll `switch_root` unless the dracut integration fights you; if it does, fall back to a fully manual `mount /sysroot; exec switch_root /sysroot /sbin/init` inside the hook and document why.

Before disconnecting: `nvme disconnect -n "$NQN"` after the copy (the remote NS is no longer needed once local is populated). Do this or the fabric session leaks into the booted system.

**`kernel-cmdline.txt`** — canonical, one arg per line with a comment. At minimum:
```
rd.neednet=1
rd.rdmalocalboot.target=<TARGET_IP>
rd.rdmalocalboot.nqn=<NQN>
rd.rdmalocalboot.dev=eth0
rd.rdmalocalboot.copymode=dd          # or partclone
rd.rdmalocalboot.ip=dhcp              # or static: <ip>::<gw>:<mask>::eth0
root=<resolved-local-by-id>-part2
rd.rdmalocalboot.mark=/run/boot-phases # phase log path (tmpfs)
```

**Gate (stage 2):** client VM boots kernel+initramfs (direct `-kernel/-initrd`), connects, copies, pivots, and lands in the target's rootfs — verified by grepping `/etc/BOOT-PROOF` for the known UUID. `nvme list-subsys` in the booted system shows the fabric **disconnected**. Phase log is written and parseable.

### 3. Netboot chain — STAGE 3, LAST

iPXE or UEFI HTTP boot serving `vmlinuz` + `initramfs` + the cmdline. `netboot/setup-tftp-http.sh` stands up dnsmasq (DHCP+TFTP) + a static HTTP dir; `ipxe.cfg` chainloads kernel/initrd. Only build this once stage 2 is rock solid — it adds a whole failure surface (DHCP, TFTP MTU, chainloading) orthogonal to the RDMA path.

**Gate (stage 3):** client boots with an empty `-kernel`/`-initrd` (i.e. real PXE via `-boot n` + the netboot services) and completes the same pivot.

---

## Stage 2.5 — dm-crypt encrypted images

Same pipeline as stage 2, but the payload is a **LUKS2** container. Design:

- **Layout** (`CRYPT=1`): `target/rootfs-crypt.img` = GPT with one partition holding a LUKS2 container; inside it the *same* ext4 payload (same BOOT-PROOF UUID). `build-rootfs.sh` stages the rootfs once and emits plain or wrapped per `CRYPT`, keeping the A/B bit-comparable.
- **Ciphertext on the wire and at rest; the key never leaves the client.** Rejected alternatives: dm-crypt under the nvmet backing device on the target (sends plaintext over the fabric), NVMe-TLS (out of scope below).
- **Key handling is POC-grade and documented as such**: `target/luks.key` (32 random bytes, mode 600, gitignored, generated once) is baked into the client initramfs at `/etc/rdb/luks.key` when `CRYPT=1`. Anyone with the initramfs has the key. Real deployments want TPM2 or clevis/tang (NBDE) — next steps, not built.
- **Copy paths** (both dispatch on `COPY_MODE`):
  - `dd`: ciphertext copied verbatim → `cryptsetup open` on the local partition → `root=/dev/mapper/rdbroot`.
  - `partclone`: `luksFormat` local partition (same key) → open as `rdbroot`; open remote partition read-only as `rdbremote`; `partclone.ext4 -b` mapper→mapper; close remote. Measures decrypt-read + encrypt-write CPU vs dd's dumb-full-copy.
- **Hook**: all inside `90rdma-localboot` behind `rd.rdmalocalboot.crypt=1`. New phase mark `crypt_open` = "local decrypted root mapper available" — its position depends on copy mode (pre-copy for partclone, post-copy for dd; see `measure/phases.md`). `module-setup.sh` adds `dm_crypt dm_mod` + `cryptsetup` when `RDB_CRYPT=1`.
- **Gate (stage 2.5):** `make gate-2.5` = gate-2 with `CRYPT=1`, additionally asserting root is on `/dev/mapper/rdbroot`. Timeline matrix becomes {dd, partclone} × {plain, crypt} × {soft-roce}.

---

## Kernel config to verify (both nodes, or confirm as modules)

`CONFIG_RDMA_RXE`, `CONFIG_INFINIBAND`, `CONFIG_INFINIBAND_USER_ACCESS`, `CONFIG_NVME_CORE`, `CONFIG_NVME_FABRICS`, `CONFIG_NVME_RDMA`, `CONFIG_NVME_TARGET`, `CONFIG_NVME_TARGET_RDMA`, `CONFIG_DM_CRYPT` (stage 2.5), `CONFIG_CONFIGFS_FS`, `CONFIG_EXT4_FS`, `CONFIG_VIRTIO_NET`, `CONFIG_VIRTIO_PCI`, `CONFIG_DEVTMPFS`, plus the NIC driver. Distro kernels ship these as modules — `check-kernel.sh` greps `/proc/config.gz` (fallback `/boot/config-$(uname -r)`) and fails loud if any are missing.

---

## Measurement (this is a deliverable, not an afterthought)

`measure/phases.md` defines the canonical phases; the hook's `mark <phase>` writes `<phase> <monotonic-seconds>` to the phase log. Use `/proc/uptime` field 1 (monotonic, cheap, available in initramfs) rather than wall clock.

Phases: `initramfs_entry → net_up → rdma_up → nvme_connected → copy_start → copy_end → root_ready`, then the booted system appends `switch_root_done` / `userspace_ready` (from `systemd-analyze` or a first-boot marker). Stage 2.5 adds `crypt_open` (position depends on copy mode — see `measure/phases.md`).

`parse-timeline.sh` emits a table of per-phase deltas + total, and records: image size, `COPY_MODE`, transport (soft-roce vs real), MTU. Save to `measure/artifacts/<timestamp>/`.

**POST/firmware is NOT captured by the kernel** — it's pre-boot. Note it separately (measured by hand / BMC) in the README; on real servers it dominates everything else, so flag it explicitly rather than pretending the kernel-onward number is the whole boot.

Expected ballpark to sanity-check against (soft-roce in a VM will be *slower* than these — real-hardware targets): kernel init + rdma up + connect ≈ 1–3 s; copy of a 2 GB image ÷ local write BW; switch_root + minimal init 1–2 s. If a phase is 10× off, something's wrong — investigate, don't just report it.

---

## Makefile targets (orchestration surface)

```
make bootstrap     # install missing distro packages (ONLY host change; prompts)
make check         # check-kernel.sh: configs + tools
make rootfs        # build target/rootfs.img (plaintext)
make rootfs-crypt  # build target/rootfs-crypt.img (LUKS, stage 2.5)
make target-up     # boot target VM (setup-target.sh runs inside) + wait TARGET-READY
make target-down   # stop the target VM
make initramfs     # build client + target initramfs
make net           # qemu bridge + taps (rdb-*, runtime-only)
make net-down      # remove bridge + taps
make run-target    # boot target VM (foreground)
make run-client    # boot client VM (direct kernel), runs a full pivot
make measure       # parse latest phase log → timeline table
make gate-0 .. gate-3   # run the DoD check for each stage, exit nonzero on fail
                        # (gate-2.5 = LUKS pivot; gate-3 = stub exit 77 until stage 3)
make clean
```

---

## Gotchas (each of these has bitten this exact setup)

- **Device index instability** — see ground rule #4. Resolve by ID. Non-negotiable.
- **Host NQN** — client needs a hostnqn (`/etc/nvme/hostnqn`); generate once and keep it stable, or the target's allow-list logic gets confusing. POC uses `attr_allow_any_host=1` so any host connects — fine for POC, note it's insecure for real use.
- **soft-roce + virtio offloads** — `rdma_rxe` over virtio can choke on GSO/checksum offload. If RDMA link-up or connect hangs, try `ethtool -K <dev> tso off gso off gro off` before `rdma link add`. Bake this into the hook behind a `--safe-offloads` flag.
- **dd copies free space** — block copy transfers the whole device including empties; on a sparse/small-fs image, fs-level (`partclone.ext4`, which skips unused blocks) is dramatically faster. That's exactly the A/B we want in the timeline. Don't assume dd is the fast path.
- **Local disk must be ≥ remote namespace** for block copy. Assert this in the hook and fail with a clear message, not a truncated write.
- **partprobe/udev races** — after writing the local disk you must `partprobe` + `udevadm settle` before the partition node exists. Skipping this → "root device not found" pivots. Add explicit waits, not sleeps.
- **Leftover fabric session** — `nvme disconnect` before pivot, or the booted rootfs inherits a live RDMA connection to storage it no longer needs.
- **RoCEv2 lossless (PFC/ECN)** — real-hardware concern for the perf stage only. **Do not** configure it during functional stages; it's irrelevant on soft-roce and a rabbit hole. Stage 4 only.

---

## Definition of Done (whole POC)

1. `make gate-0` … `make gate-3` all pass from a clean checkout on a fresh host (documented deps only; `make bootstrap` installs them). gate-3 stays a stub until stage 3 is built.
2. A booted client provably running the *remote* rootfs (BOOT-PROOF UUID matches) off its *local* NVMe, fabric disconnected — in both plaintext (`gate-2`) and LUKS (`gate-2.5`, root on `/dev/mapper/rdbroot`) variants.
3. `measure/` produces a timeline table for at least: {dd, partclone} × {plain, crypt} × {soft-roce}. Real-hardware row optional but stubbed.
4. README quickstart reproduces a full run in ≤ N documented commands.
5. Open design question answered empirically in the README: **copy-then-boot vs boot-RO-off-fabric-then-background-copy** — is the copy latency worth paying up front, or should it be hidden behind a background pivot? Include the numbers that justify the answer.

---

## Host environment (verified 2026-07-20)

Reference host this repo was built on:

- Manjaro Linux, kernel `7.0.10-1-MANJARO`; 24 cores, 186 GB RAM; `/dev/kvm` world-accessible.
- All required kernel configs present (as modules): `NVME_TARGET_RDMA`, `NVME_RDMA`, `RDMA_RXE`, `INFINIBAND(_USER_ACCESS)`, `DM_CRYPT`, `CONFIGFS_FS=y`, `VIRTIO_NET`, `EXT4_FS=y`, … — verified via `/proc/config.gz`. No kernel rebuild needed. AES-XTS + AES-NI available for dm-crypt.
- Present: qemu, nvme-cli, iproute2 (`rdma`), dnsmasq, jq, socat, expect, ethtool, cryptsetup 2.8.6, qemu-img, sgdisk, python3.
- Installed via `bootstrap.sh` (only host change): `dracut`, `partclone`, `busybox` — official Manjaro repos.
- Guests boot the **host kernel** (`/boot/vmlinuz-7.0-x86_64`, auto-detected by matching `file` output to `uname -r`), so host-built initramfs modules always match the guest kernel.
- `sudo` requires a password on this host: scripts call `sudo` for privileged steps; run them as the user, not as root.

## Decisions log (implementation)

Recorded so the next agent doesn't re-derive them:

1. **Target VM is an initramfs OS**, not a disk image. ORIGINAL plan was a dracut module replacing `/init` — that lost against dracut 111's systemd initramfs (module ordering gives 98dracut-systemd/99base the final word on `/init`), so the documented fallback was exercised: `target/build-initramfs.sh` hand-rolls a cpio (bash + busybox + ip/rdma/nvme/ethtool with ldd closures + dep-closure of nvmet_rdma/rdma_rxe/virtio_net decompressed to plain .ko + our scripts). Runs unprivileged; gate-1 verifies contents. `setup-target.sh`/`teardown-target.sh` remain generic and host-runnable. No udev in the target VM: kernel names (eth0, /dev/vda) hold. Lessons baked in: initramfs boots must mount devtmpfs themselves; busybox/kmod modprobe takes ONE module per call; ldd output is tab-indented and the ELF interpreter line has no `=>`.
2. **Payload layout**: single GPT partition (p1), not p2 — the hook resolves partitions dynamically, so the doc's `-part2` example became `-part1`. Payload userspace = busybox + ldd closure, `/sbin/init` shell script; no kernel modules needed in the payload (all drivers it needs were loaded by the initramfs and persist across `switch_root`).
3. **Networking**: dedicated `rdb-br0` (host 10.210.0.254/24) + `rdb-tap0/1`, static IPs (target .1, client .2). No NAT/forwarding/sysctls//etc writes; subnet-collision check before creating anything. Client cmdline `ip=` supports `static`, `dhcp` (dies with a clear message pre-stage-3), and explicit `<ip>::<gw>:<mask>::<dev>`.
4. **Device selectors**: local disk via qemu `-device nvme,serial=NVMELOCAL0` → `/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_NVMELOCAL0` (resolved by glob, partitions excluded); remote namespace via `/sys/class/nvme-fabrics/ctl/*/subsysnqn` match → `/dev/nvmeXn1`. Never by index (rule #4).
5. **Pivot integration**: dracut does mount+`switch_root` of the cmdline `root=`; the hook blocks in pre-mount until the device exists. State from cmdline hook → pre-mount hook travels via a file (`/tmp/rdb-localboot.env`), not exported vars — under systemd initramfs each hook is a separate process. Manual-`switch_root` fallback documented in README.
6. **Serial handling**: qemu chardev socket/stdio with `logfile=` — full console transcript always captured per run; `qemu/serial-expect.py` (stdlib) pre-scans the logfile then waits on the live stream. Payload prints BOOT-PROOF; gates never rely on timing.
7. **Stage 2.5**: LUKS2-in-image (see its section). Key baked into initramfs = documented POC tradeoff.
8. **gate-1** is a build-sanity gate (lsinitrd contents) between target bring-up and full boot; **gate-3** is a stub exiting 77 until stage 3 exists.
9. **Git**: repo initialized on branch `master`; commit at each gate per ground rule #1.
10. **Safety model**: the implementing agent changed nothing on the host. `bootstrap.sh` (user-run) is the only host-changing script and only installs packages. Everything else is runtime-only, `rdb-*`-namespaced, and torn down by `make net-down` / `make target-down` / gate traps.

---

---

## Explicitly out of scope for the POC

Multi-client / boot-server fan-out, image versioning, secure NQN allow-listing, TLS/auth on the fabric, A/B rootfs slots, real production PXE infra. Note them in README as "next steps," build none of them.
