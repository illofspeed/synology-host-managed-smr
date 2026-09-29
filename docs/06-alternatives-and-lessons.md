# 06 — Alternatives and lessons

This page covers what was tried before the current stack, why each option was
dropped, and what comparing guest kernels showed. Every number here comes from
the author's own logs from September 2026. Anything that was not measured or
not tried is marked as such.

> [!IMPORTANT]
> **Everything on this page was tried on one machine:** a DS3622xs+ with the
> zoned drives in a DX1222 expansion unit, behind the Marvell 88SE9235
> expansion controller. DSM uses that controller for none of its own disks.
> **None of the alternatives below removes that requirement.** The nested-DSM
> route in [section 4](#4-dsm-on-the-drives-through-a-nested-dsm-vm-tested-works)
> needs the same controller passthrough as the main guide. Nothing on this
> page applies to a model where the zoned drives would share the controller
> DSM runs from. The author's example of such a model is a **DS1821+ in this
> layout**. See [01 — Requirements and risks](01-requirements-and-risks.md).

## 1. At a glance

| Option | Tried? | Outcome | Why it is not used |
|---|---|---|---|
| Zoned btrfs per drive + mergerfs + SnapRAID | Yes, in production, 2026-09-17 to 09-23 | Stored 11 TiB without errors, then lost data silently | Writes that were reported as successful were discarded. Four filesystem failures in three days ([section 3](#3-zoned-btrfs--mergerfs--snapraid-abandoned)) |
| DSM on the drives, in a nested DSM VM on dm-zoned mappers | Yes, as a test pool on 2026-09-25 | Works: DSM RAID5 pool, 49.1 TiB (DSM shows "49.1 TB") | Extra virtualisation layers, 2 vCPUs saturated, DSM sees only virtual disks, and it was not faster ([section 4](#4-dsm-on-the-drives-through-a-nested-dsm-vm-tested-works)) |
| md RAID directly on the drives | Yes, in a lab | The array is created, then the first write fails | Parity writes land out of zone order ([section 5](#5-zfs-lvm-md-and-caches-directly-on-host-managed-drives)) |
| ZFS or LVM directly on the drives | No | Unsupported | No host-managed SMR support ([section 5](#5-zfs-lvm-md-and-caches-directly-on-host-managed-drives)) |
| Block caches (dm-cache, dm-writecache, bcache) on the drives | Yes, in a lab | Refused, or accepted and then broken | [Section 5](#5-zfs-lvm-md-and-caches-directly-on-host-managed-drives). Caches that work: dm-zoned's own cache device and dm-cache above the RAID, [08](08-caching.md) |
| Another OS on the Synology hardware | Researched, not tried | Not viable | No mainline Linux driver for the 88SE1475 that runs the internal bays ([section 6](#6-another-os-on-the-synology-hardware-not-viable)) |
| Passing disks, not the controller | No | Not tried: `scsi-block` is unavailable because DSM creates no block device on the DX1222/AHCI path; `scsi-generic` via `/dev/sgX` is unverified on DSM/VMM | Whole-controller passthrough is the validated method ([section 7](#7-passing-drives-instead-of-the-controller)) |
| **dm-zoned → md RAID5 → LUKS2 → XFS in an OpenMediaVault guest** | **In use** | | [03](03-guest-storage-stack.md), [04](04-openmediavault-and-synology-integration.md) |

## 2. Timeline

| Date (2026) | What happened |
|---|---|
| 09-17 to 09-19 | Zoned btrfs + mergerfs + SnapRAID pool, then hosted in a Proxmox VE guest in VMM, seeded with an 11 TiB Hyper Backup. The integrity check and a restore test both passed |
| 09-20 | Pool moved to an OpenMediaVault 8 guest in VMM |
| 09-21 to 09-23 | Four btrfs failures. Two backup seeds destroyed |
| 09-24 | Drives wiped and the pool rebuilt as dm-zoned → md RAID5 → XFS. The NAS kernel panic in `mv14xx` happened the same day ([01, 7.1](01-requirements-and-risks.md#71-nas-kernel-panic-in-dsms-own-storage-driver)) |
| 09-24 to 09-25 | Nested-DSM tests: first a stock DS3622xs+ image, then SA6400 with RR's custom kernel, then a DSM pool on the dm-zoned mappers |
| 09-25 evening | Decision: return the drives to the OpenMediaVault guest |
| 09-26 | LUKS2 added, guest kernels compared, stress test run |

## 3. Zoned btrfs + mergerfs + SnapRAID (abandoned)

This was the first production design. The author published its tooling
earlier as a project called `zonedpool` and has since withdrawn it. This
section is its postmortem in short. Read it before you build that design.

### The design

- Each zoned drive had its own **btrfs in zoned mode**, with metadata DUP and
  data single.
- **mergerfs ≥ 2.42** joined the three drives into one tree, using FUSE
  passthrough. Each new file went to the drive with the most free space.
- **SnapRAID** kept single parity on a plain, non-zoned drive. In this
  deployment the parity was a VMM virtual disk on the NAS's own RAID.
- **systemd timers** ran the maintenance a zoned pool needs. That included a
  periodic **metadata balance**, because zoned btrfs only reclaims zones
  automatically when the device is nearly full, and on a 27 TB drive it
  never is.
- Kernel ≥ 7.2.6 was needed for a zoned-btrfs writeback fix.

Usable space was about 73.7 TiB, because all three drives held data. The current
RAID5 gives about 49.1 TiB.

### It worked first

On 2026-09-17 a Synology Hyper Backup repository was seeded onto the freshly
formatted pool: **11 TiB, 463,851 files, one continuous 30-hour run at
105–107 MiB/s, zero errors**. The backup then passed DSM's integrity check and
a restore test. That verified success is why the design was trusted with a
backup target.

### What went wrong

Between 2026-09-21 and 2026-09-23 there were four failures. The hardware was
healthy throughout: SMART was clean, there were no ATA or SCSI errors, and
`btrfs device stats` stayed at zero. There were two distinct signatures, both
from btrfs's zoned allocation path.

**1. ENOSPC at writeback. This is the dangerous one.**

```text
BTRFS error (device sdX): cow_file_range failed, root=5 inode=N ... : -28
BTRFS error (device sdX): failed to run delalloc range, root=5 ino=N ... : -28
```

The filesystem stays mounted **read-write**. The application is told its
write **succeeded**. The data is discarded and the file is left with a hole.

- One occurrence ran for **32 minutes** and hit 1,567 files before the
  filesystem finally aborted.
- Another destroyed 7 Hyper Backup index files and left holes in 9 more. The
  result was four files that could not be restored, and an 11.5 TB backup task
  forced into "Restore Only". It was found two days later by Hyper Backup's own
  integrity check, not by any monitoring.

**2. EAGAIN at transaction commit.**

```text
BTRFS error (device sdX): error while writing out transaction: -11
BTRFS error (device sdX state A): Transaction NNNN aborted (error -11)
BTRFS info  (device sdX state EA): forced readonly
```

`do_zone_finish()` was on the stack under `btrfs_balance()`, and the
filesystem was forced read-only. Sustained heavy writing alone also triggered
it, with no balance running.

**Free space was never the constraint.** One drive failed with 25 TB free,
after 62 GB had been written.

### A filesystem that aborts once keeps getting worse

The amount written before a failure was not a constant. It shrank with each
failure of the same filesystem:

| Filesystem | State | Written before it failed |
|---|---|---|
| d3 | freshly made | 11.5 TB |
| d2 | freshly made | 410 GB |
| d1 | freshly made | 410 GB |
| d2 | after one abort, "recovered" | 62 GB |
| d2 | after further aborts | 0: it aborted with no writers at all |

Only `mkfs` reset this. A drive "recovered" with `skip_balance` and
`balance cancel` was the next one to fail. A freshly re-made drive took 251 GB
under the same load without an error.

### Beliefs that turned out to be wrong

Each of these cost a day and each looked plausible.

- **"Kernel 7.2.7 fixes it."** The commit *"btrfs: zoned: finish active block
  group cleanup if call_zone_finish() fails"* looked like an exact match. A
  7.2.7 kernel built from kernel.org source **reproduced the abort within
  minutes on two drives.** The commit keeps the accounting consistent after a
  zone finish fails. It does not stop the failure.
- **"It is open-zone exhaustion."** A failing drive did sit at exactly 128 of
  128 open zones. After its open zones were cleared to 0, the same filesystem
  **still aborted 64 seconds after every mount, with 0 open zones
  throughout.**
- **"The lab will reproduce it."** It never did. 16 parallel writers plus
  continuous balances, with `max_open_zones=128`, ran clean on zoned loop
  devices on both 7.2.6 and 7.2.7. The trigger needs the real drives, or the
  path to them.

### The recovery trap, if you still run zoned btrfs

btrfs saves a paused balance and **resumes it on mount**. A plain remount
therefore aborts the filesystem again within seconds, and each attempt looks
like a new failure. The author broke the loop like this:

> [!WARNING]
> Run this only on a zoned btrfs that has already aborted. Stop the mergerfs
> union and every writer first. Replace `<dev>` and `<mnt>` with that one
> branch's device and mount point. Given the decay table above, the author's
> rule was to re-make an aborted filesystem with `mkfs` afterwards, not to
> keep using it.

```sh
umount <mnt>                  # stop the union first; mergerfs pins the branch
mount -o skip_balance <dev> <mnt>
btrfs balance cancel <mnt>
umount <mnt> && mount <mnt>
```

Then check **every** branch, including branches that stayed read-write. A
healthy-looking branch can still carry a paused balance that will abort it at
its next mount.

### Why tuning cannot fix it

The design needs the periodic metadata balance. Without it, `zone_unusable`
space builds up and nothing reclaims it. But the balance is also one of the
loads that aborts filesystems. No setting resolves that, and no kernel the
author tested changed it.

### Why dm-zoned replaced it

dm-zoned makes each host-managed drive look like an ordinary, randomly
writable block device. **No filesystem above it ever sees a zone**, so this
whole class of failure cannot occur. The trade-offs, as recorded when the
switch was made:

| Lost | Gained |
|---|---|
| About 24.6 TiB of usable space (73.7 TiB → 49.1 TiB) | Continuous redundancy. SnapRAID only protected data up to its last sync |
| btrfs data checksums | A drive failure keeps the array running, instead of a per-file restore |
| | No ~26 TiB parity virtual disk (shown as 26 TB in VMM) on the NAS's own RAID |

That last point mattered. While DSM ran a 32-hour RAID6 repair and SnapRAID
streamed parity to the virtual disk at about 245 MB/s, an OpenMediaVault
upgrade in the guest crawled for 40 minutes. VMM also cannot move a virtual
disk between guests, so moving the pool to a new guest meant a new parity disk
and a full rebuild: about 15 hours for 12 TiB at 200–250 MB/s.

## 4. DSM on the drives through a nested DSM VM (tested, works)

The original goal was to let DSM own the drives, with its own RAID, Btrfs,
snapshots and a local Hyper Backup target. DSM cannot use host-managed drives
directly ([01, section 3](01-requirements-and-risks.md#3-why-dsm-cannot-use-these-drives-itself)).
Storage Manager also adopts only disks that the kernel's `sd` driver probed on
known ports, so a `/dev/mapper` device never qualifies. So the drives have to
be turned into ordinary disks on a Linux host, and DSM has to run above that
host as a VM.

### Topology

```text
DS3622xs+  DSM 7.4, Linux 4.4 KVM                         outer hypervisor
 └─ VMM guest: Proxmox VE, 6 vCPU                          layer 1
     ├─ 88SE9235 via VFIO → 3 × HC680 → dm-zoned dz1..dz3
     └─ VM: DSM 7.4 SA6400, RR loader, "Kernel: custom",   layer 2
        2 vCPU (host), 16 GiB, Q35 + OVMF
         └─ dz1..dz3 as virtio-scsi disks → DSM RAID5 + Btrfs
```

*Why a Proxmox VE guest in between:* the controller can only go to a VMM
guest, and a VMM guest cannot pass it on. VMM guests have no IOMMU groups
([01, section 6](01-requirements-and-risks.md#6-not-supported)). So the DSM VM
has to get the dm-zoned devices as virtual disks from a Linux host that owns
the controller.

The DSM VM ran from **RR**, a community ("Xpenology") loader that boots
Synology's DSM on non-Synology hardware. This is not supported by Synology.
Check Synology's licence terms for your situation before you do the same.

### Step 1 — a stock DSM kernel, nested: 20-minute boots

The first test VM used RR with the **DS3622xs+** model, the same as the
physical NAS: platform `broadwellnk`, kernel 4.4.302, DSM 7.4-90080. Nested
under the Proxmox VE guest, it took **about 20 minutes to boot**, and its
vCPUs saturated under any load.

**The cause was the clock.** A 5-second trace taken at idle on the Proxmox VE
guest showed:

- **18,817 of 25,297 VM exits were port reads at `0x608`**, the ACPI PM
  timer. The remaining exits were APIC writes (3,676), HLT (1,284), preemption
  timer (866) and external interrupts (561).
- Over the VM's lifetime, I/O exits were **183.6 M of 250 M exits (73 %)**.
- At idle this was about 3,700 reads per second, which cost almost no CPU.
  During boot or under load it rose to tens of thousands per second.

The chain behind it:

1. **Synology builds the kernels of its physical models without guest
   support.** The toolkit kernel configs (7.2 and 7.4 toolkits agree) say
   `# CONFIG_HYPERVISOR_GUEST is not set` for `broadwellnk` (4.4.302),
   `epyc7002` (5.10.55) and `geminilakenk` (5.10.55). Only `kvmx64`, the kernel
   of Synology's own Virtual DSM, has `HYPERVISOR_GUEST=y`, `KVM_GUEST=y` and
   `PARAVIRT=y`. **So no stock DSM kernel for a physical model can use
   kvm-clock, the Hyper-V clock or the VMware clock.**
2. **TSC calibration fails when nested.** The DS3622xs+ kernel logged
   `Fast TSC calibration failed` and `Marking TSC unstable due to could not
   calculate TSC khz`. Kernel 4.4 has no command-line option to supply the TSC
   frequency.
3. **Proxmox VE sets `hpet=off`**, so the clocksource falls back to `acpi_pm`.
   Every clock read is then a port read that QEMU emulates in user space on
   layer 1, with the nested exits on top. The vDSO cannot read `acpi_pm`, so
   every `gettimeofday` in user space exits too.

What does **not** help:

- **`hpet=on`.** This only swaps port I/O for MMIO, which QEMU also emulates
  in user space.
- **The Hyper-V clock (`hv_time`) or the VMware backdoor.** Both need guest
  code that is not compiled into these kernels.
- **Tuning the outer hypervisor.** On the NAS's 4.4 KVM, the `ple_*`
  parameters are read-only at runtime. Only `halt_poll_ns` can be changed; an
  A/B test of it was proposed but no result was recorded. Several
  nested-virtualisation features that newer kernels use to make nesting
  cheaper are missing from 4.4. That is structural.

For comparison, Synology's Virtual DSM (`kvmx64`, with guest support) was
healthy about 20 seconds after boot in a separate test. That test ran Virtual
DSM in Docker inside a VM on a different, bare-metal Proxmox VE host with a
current kernel, so it is not a like-for-like comparison.

### Step 2 — RR's custom kernel on SA6400: kvm-clock

RR offers a rebuilt DSM kernel, **"Kernel: custom"**. Commit `40826c25` in
`RROrg/dsm_linux` (2024-04-28) turned on `HYPERVISOR_GUEST`, `KVM_GUEST`,
`PARAVIRT_CLOCK` and related options. The rebuilt kernel exists only for the
`epyc7002` and `geminilakenk` platforms (both 5.10.55). So the test model
became **SA6400**, an `epyc7002` model.

*Why an AMD EPYC model runs on an Intel Xeon here:* RR's kernel is built with
`CONFIG_GENERIC_CPU=y`. RR's only CPU check for `epyc7002` with DSM newer than
7.2 is the `movbe` instruction, which the Broadwell-DE Xeon D-1531 has. No
earlier report of SA6400 on Broadwell-DE was found, so this was a first-hand
test.

Build in RR's text menu: Model → SA6400, Version → 7.4, Kernel → custom,
Build, Boot. Then install DSM from `http://<DSM_VM_IP>:5000`.

Results, same host and same nesting depth as step 1:

- The serial console showed `Hypervisor detected: KVM` and
  `clocksource: Switched to clocksource kvm-clock` about 21.6 s into boot.
  The DS3622xs+ kernel never printed either line.
- In the same 5-second window, the stock image made 15,005 reads of port
  `0x608`. The SA6400 VM with the custom kernel made 0.

| Boot | DSM serving after (kernel uptime) |
|---|---|
| Stock DS3622xs+ image (step 1) | about 20 min |
| SA6400 + custom kernel, installer | 254 s |
| SA6400, first boot after installing DSM | 915 s, partly spent in ATA error handling (see step 3) |
| SA6400, steady state, with `libata.force=noncq` | 364 s |
| SA6400 with the three data disks attached | 242–286 s |

RR's own loader stage adds about 1–2 minutes before any of these, when nested.

The generic nested cost remains. At idle, with nobody logged in, the VM used
**about 96 % of one core**, at about 3,300 exits per second from timer and
interrupt traffic. There was no clock storm.

### Step 3 — disk bus: SATA at queue depth 1 versus virtio-scsi

1. **Emulated SATA needs `libata.force=noncq`.** On the first boot after
   installing DSM, a disk on QEMU's AHCI controller returned
   `READ FPDMA QUEUED … error: { ABRT }` five times. This is RR issue #897.
   The fix was to add `libata.force=noncq` in RR's **Cmdline** menu (on the
   main menu, item `x`, not under Advanced), then Build and Boot. After that
   there were 0 ATA errors.
2. **With `noncq`, each emulated SATA disk runs at queue depth 1.** The mappers
   were first attached as SATA disks. During DSM's initial parity sync, each one
   did about 213 reads/s and 82 writes/s of 127 KiB, which is **about 27 MB/s
   read and 10 MB/s write per disk**. The drives were only 6–10 % busy. Each
   request took about 4.7 ms for the round trip through two hypervisors, and
   only one was in flight at a time. The owner estimated about 10 days for the
   sync. Setting DSM's RAID resync speed to priority changed nothing, which
   confirms that queue depth was the limit, not DSM's throttle.
3. **virtio-scsi removes that limit.** RR's SA6400 custom kernel has
   `CONFIG_SYNO_VIRTIO_SCSI_DEVICE=y`, `SCSI_VIRTIO=m` and `VIRTIO_PCI=m`. The
   stock kernel has none of them. The author moved the three mappers to
   `virtio-scsi-single` with one I/O thread each. DSM found the disks and
   reassembled its arrays from them. The sync went to **177 MB/s per mapper,
   about 6× faster**, with the DSM VM at about 200 % vCPU.

### Step 4 — vCPUs: fewer was faster

| DSM VM vCPUs | Resync rate per mapper | vCPU use |
|---|---|---|
| 1 | not tested | – |
| 2 | 177–197 MB/s | about 194–200 % (saturated) |
| 4 | 111–117 MB/s | about 387–389 % |

*Why more vCPUs were slower:* the md rebuild is one thread and gains nothing
from more CPUs. The extra vCPUs added interrupt and timer exits, and they
saturated the Proxmox VE guest's own 6 vCPUs. Layer 1 fell to 16 % idle with
9.1 % steal.

The Proxmox VE guest itself had already been cut from 12 to 6 vCPUs. The
Xeon D-1531 has 12 threads, and at 12 vCPUs plus the other guest's 4, layer 1
measured 12.8 % steal under load. Every nested VM pays for that first.

### Result

DSM's Storage Manager showed the three drives as 24.6 TB HDDs, Healthy, in
**Storage Pool 1, RAID 5, 49.1 TB**, with **Volume 1 (Btrfs), 47.1 TB free**.
So DSM *can* own these drives, as long as there is a translation layer below
it.

### Why the author stayed with OpenMediaVault

The test showed that it works. The author still decided on the evening of
2026-09-25 to stay with the OpenMediaVault guest. The reasons:

- OpenMediaVault is more flexible, and the Proxmox VE guest was wanted for
  other work.
- The one DSM feature that nested DSM added on this pool, Snapshot
  Replication, was not wanted. Hyper Backup to an rsync target on the
  OpenMediaVault guest restores the same data.
- It was not faster. OpenMediaVault's own md resync ran at about 195 MB/s on
  one layer of virtualisation. DSM managed 177–197 MB/s on two, with its
  2 vCPUs saturated.
- DSM sees QEMU disks. Its SMART and health view tells you nothing about the
  real drives.
- The recovery chain is longer. After every restart of the Proxmox VE guest:
  the NAS watcher re-attaches the controller, the drives enumerate, dm-zoned
  assembles, then the DSM VM may start, and DSM takes about 4–6 minutes to
  serve. The DSM VM must not start before all three mappers exist. Otherwise
  DSM boots with missing disks and degrades its pool. The author used a unit
  that refuses to start the VM unless all three mappers exist.

### Read these numbers with care

- **The throughput figures come from md resyncs over mostly unwritten
  space.** dm-zoned answers reads of never-written zones from its metadata.
  The physical drives were almost idle during these samples. The numbers
  measure the virtual path and CPU cost, not the drives.
- **The DSM pool existed for about 90 minutes** on 2026-09-25 before the
  author decided to stay with OpenMediaVault. Its initial parity sync never finished, and it never held
  production data. The boot ordering was wired up, but a full restart of the
  whole chain was not tested.
- **A nested DSM looks like the real NAS.** The test VM built as a DS3622xs+
  presented itself with the same model name and the same UI as the physical
  NAS. The owner shut down the **physical** NAS from its DSM UI by mistake.
  Give any nested DSM a clearly different name.
- **Switching back destroys the pool.** DSM writes its own partitions to its
  disks. When the mappers went back to the OpenMediaVault guest, DSM's
  partition tables had overwritten the md superblocks. The drives had to be
  formatted again with `dmzadm --format`, which resets every zone and destroys
  all data on the drive. Plan every move between DSM and a Linux guest as a
  full wipe and a re-seed.

### If you want to try it anyway

**Untested beyond the one afternoon described above.** These are the settings
the author ended with:

| Item | Value |
|---|---|
| Loader | RR 26.9.0, model SA6400, DSM 7.4-90080, Kernel: custom |
| DSM command line | `libata.force=noncq` (for the loader disk, which stays on AHCI) |
| DSM VM | Q35 + OVMF, CPU type `host`, **2 vCPU**, 16 GiB RAM |
| Data disks | `dz1..dz3` as `virtio-scsi-single`, `iothread=1`, `cache=none`, `aio=native`, `discard=ignore`, `backup=0`, a fixed serial per disk |
| Start order | DSM VM not started at host boot. A unit starts it only when all three mappers exist. The mapper-assembly unit waits up to 300 s per drive, because the drives take about 2.5 minutes to appear after the controller is attached |
| Stop | `qm shutdown <VMID> --timeout 240`, falling back to `qm stop <VMID>`, **before** the mappers are removed |

The disk settings as Proxmox VE commands are below. They are reconstructed
from the recorded VM configuration, because the exact command lines were not
recorded.

```sh
qm set <VMID> --scsihw virtio-scsi-single
qm set <VMID> --scsi2 /dev/mapper/dz1,iothread=1,backup=0,cache=none,aio=native,discard=ignore,serial=HC680-<SERIAL>
qm set <VMID> --scsi3 /dev/mapper/dz2,iothread=1,backup=0,cache=none,aio=native,discard=ignore,serial=HC680-<SERIAL>
qm set <VMID> --scsi4 /dev/mapper/dz3,iothread=1,backup=0,cache=none,aio=native,discard=ignore,serial=HC680-<SERIAL>
```

To see whether a nested DSM is using the PM timer, the author sampled the
VM's `io_exits` counter twice, 10 s apart, on the host that runs it:

```sh
cat /sys/kernel/debug/kvm/<QEMU_PID>-*/io_exits
```

A high, steady rate with the VM idle points at `acpi_pm`. A DSM kernel with
guest support logs `Switched to clocksource kvm-clock` early in boot.

## 5. ZFS, LVM, md and caches directly on host-managed drives

A host-managed drive accepts writes only at each zone's write pointer. Any
layer that writes in place or out of order will fail on it.

| Layer on the raw drive | Tried? | Result |
|---|---|---|
| **md RAID5** | Yes, in a lab | `mdadm --create` succeeds and the array even reports `zoned=host-managed`. Then `mkfs.ext4` fails with `Input/output error` and the kernel logs write errors on all three members. Parity lands at arbitrary sectors. **A successful create proves nothing.** |
| **ZFS** | No | No host-managed SMR support. TrueNAS documents the incompatibility |
| **LVM** | No | The author treated host-managed SMR as unsupported there and never tried it |
| **dm-writecache** | Yes, in a lab | Refused: `device-mapper: table: zoned model is not consistent across all devices` |
| **dm-cache** | Yes, in a lab | Refused with the same message |
| **dm-linear** (control) | Yes, in a lab | Loads, and the result stays `host-managed`. The refusals above come from the cache targets, not from device-mapper |
| **bcache** | Yes, in a lab | **A trap.** `make-bcache -B` accepts the drive and `/dev/bcache0` appears as `zoned=none`, hiding the zone model. A sequential write from offset 0 works. A write at a 2 GiB offset returns `Input/output error`. Nothing warns you |
| **btrfs with an added non-zoned device** | Yes, in a lab | Accepted, but zone sizes must match, upstream documents mixing as test-only, and there is no cache role. The SSD becomes plain capacity |

The cache tests used a RAM-backed `null_blk` host-managed device, not the
HC680s.

**Above dm-zoned, the picture changes.** dm-zoned presents an ordinary block
device, so in principle anything can run on top of it. Only two things were
tried on this hardware:

- **md RAID5 + XFS** is the current stack ([03](03-guest-storage-stack.md)).
- **ext4** worked in a lab, but it was dropped. With ext4's default inode
  ratio, the inode tables alone would have used about 380 GB per drive, and
  formatting crawled through dm-zoned. XFS allocates inodes dynamically and
  formats instantly.

ZFS, LVM or a cache on top of dm-zoned mappers is **untested**.

## 6. Another OS on the Synology hardware (not viable)

Could DSM be replaced on the DS3622xs+ with a current Linux that supports zoned
drives natively? The author researched this and did not try it, because the
NAS is in production. What was verified:

- **The internal bays have no mainline driver.** The 12 bays sit behind the
  Marvell 88SE1475, PCI ID `1b4b:1475`, PCI class `0x010000` (SCSI storage,
  **not** AHCI). Mainline 7.3-rc4's `ahci`, `mvsas`, `mvumi` and `sata_mv`
  drivers do not list device `0x1475`, and AHCI's generic class match cannot
  apply. **No stock distribution sees those 12 drives.**
- **The only driver found outside DSM** is Marvell's GPL driver packaged at
  <https://github.com/nagi1999a/QXP-1600eS-driver>, for kernel 5.15. It was
  pushed once, in 2022. Its author wrote in 2024 that they "cannot guarantee
  stability".
- **Community reports are mostly failures.** A TrueNAS SCALE user built the
  `mv14xx` module and got kernel panics. An Unraid user saw the controller but
  no drives. An Ubuntu 24.04 report had no driver bound. The one success was on
  Ubuntu 20.04 with kernel 5.4 and QNAP's driver under DKMS, on one motherboard
  but not another. No report was found of any non-DSM OS, Xpenology loader or
  rebuilt kernel running on a DS3622xs+, or on another 88SE1475 Synology, with
  the internal bays working.
- **The existing DSM volume would be unreadable outside DSM anyway.** On this
  NAS the production volume has a read-write SSD cache (Synology's
  `flashcache`), which is not in mainline Linux. Synology's own "recover data
  with a PC" instructions say they do not apply to volumes with a read-write
  SSD cache.
- **Open questions, not verified:** where the NAS's serial and MAC identity
  are stored, whether the firmware falls back to the Synology boot module
  after booting something else, and whether the bays get power without DSM.

The conclusion was that the DS3622xs+ stays on DSM. An Xpenology loader on the
NAS itself would not help either. Synology's kernels (all 45 configs checked)
and RR's custom kernel lack zoned support
([01, section 3](01-requirements-and-risks.md#3-why-dsm-cannot-use-these-drives-itself)).

## 7. Passing drives instead of the controller

- **Per-disk passthrough:** `scsi-block` needs block devices DSM does not
  expose here. `scsi-generic` through `/dev/sgX` is unverified on DSM/VMM;
  whole-controller passthrough is the validated method in this guide
  ([01, section 3](01-requirements-and-risks.md#3-why-dsm-cannot-use-these-drives-itself)).
- **Passing the controller on from a VMM guest** is not possible, because VMM
  guests have no IOMMU groups
  ([01, section 6](01-requirements-and-risks.md#6-not-supported)).
- **Handing zoned drives from a Proxmox VE host to a VM as virtual disks**
  works only through a bare QEMU block node. On QEMU 11.0.3
  (`pve-qemu-kvm 11.0.3-3`), with a RAM-backed `null_blk` zoned device:

  | QEMU block graph | Zone report in the guest |
  |---|---|
  | `host_device`, direct I/O | works |
  | `raw` → `host_device` | `Operation not supported` |
  | `throttle` → `raw` → `host_device` | `Operation not supported` |

  Proxmox VE's normal disk configuration wraps the device in `raw` and
  `throttle` nodes. That path loses zoned support. The working path was a
  `host_device` with `cache.direct=true` on a `virtio-blk-pci` device,
  hot-plugged through QMP without touching the saved VM configuration. Zoned
  btrfs passed a short test on it. **This was tested on synthetic media only,
  never with the HC680s**, and no design in this project ended up using it.

## 8. Kernel lessons

The guest kernel changed throughput more than anything else. Same stack, same
guest, same two 60-second tests on the encrypted pool (details and caveats in
[03, step 2](03-guest-storage-stack.md#step-2---choose-and-pin-the-kernel)):

| Guest kernel | 1 writer, O_DIRECT 1 MiB | 4 writers, buffered |
|---|---:|---:|
| Debian 13 `6.12.107` | 24.6 MiB/s | not measured |
| Debian backports `7.1.8` | 24.7 MiB/s | 34.4 MiB/s |
| Ubuntu mainline `7.2.6-070206-generic` | **165.4 MiB/s** | **261.4 MiB/s** |
| Zabbly `7.2.7` | 58–69 MiB/s | 210.7 MiB/s |

What this taught:

1. **Measure on your own stack.** On 6.12, during a backup re-seed, the
   encrypted volume took about 25 MB/s. Below md, each mapper received about
   3,000 writes/s of 3–4 KiB, and the drives were 93–100 % busy with 4 KiB
   writes. The mappers' queues held thousands of requests while the drives had
   0–12 in flight. In the O_DIRECT test on 7.2.6, one member received about
   21,000 writes/s instead of about 3,200/s, with the same 4.0 KiB write
   size.
2. **Do not guess the cause.** md RAID5 sends dm-zoned 4 KiB writes on every
   kernel, and `block/blk-zoned.c` is byte-identical in 7.1.8 and 7.2.x. **Why
   7.2 is faster is unknown.** It is not zoned write plugging. The gap between
   Ubuntu's and Zabbly's 7.2 builds is not explained by code changes either:
   7.2.7 and 7.2.8 changed nothing in dm-zoned, md/raid5, dm-crypt, dm core,
   blk-zoned, mq-deadline, libata/AHCI/port multipliers or sd/sd_zbc. It is
   probably build configuration or compiler (full vs lazy preemption, gcc 14.2
   vs 15.2, `max_sectors_kb` 4096 vs 1280). This is unproven.
3. **A "safe" fallback kernel can cost you 85 % of your throughput.** After a
   dm-zoned reclaim worker had got stuck on 7.2.6, the author moved the guest
   to Debian's 6.12 for stability. The re-seed that followed ran at 25 MB/s. The
   guest went back to 7.2.6, with monitoring for the stuck worker
   ([05](05-operations-monitoring-performance.md)).
4. **A commit that matches your stack trace may not fix your bug.** The btrfs
   fix in 7.2.7 ([section 3](#beliefs-that-turned-out-to-be-wrong)) matched the
   symptoms exactly and did not stop the aborts. Test on the real drives. The
   lab did not reproduce the failure at all.
5. **Kernel configuration changes what your timers do.** Debian enables
   `xfs_scrub_all.timer`. On kernels built with XFS online scrub (Debian
   7.1.8, Zabbly 7.2.7) it runs a real full-media scan every month. On Ubuntu's
   7.2.6, which lacks online scrub, it does nothing.
6. **In a nested VM, one config option decides whether it is usable.**
   `CONFIG_HYPERVISOR_GUEST` made the difference between a 20-minute and a
   4–6-minute DSM boot ([section 4](#step-1--a-stock-dsm-kernel-nested-20-minute-boots)).
7. **Mainline kernels cost you updates.** The fast kernel is a hand-installed
   Ubuntu mainline build, with no automatic security updates. Kernels 7.2.0 to
   7.2.6 have a SLUB freelist race that 7.2.7 fixes. Keep a packaged kernel
   installed as a boot fallback ([03](03-guest-storage-stack.md)).

## 9. Lessons that apply to any design

- **"Created successfully" is not a test.** md RAID5 on raw host-managed drives
  and bcache on a host-managed drive both set up without complaint and failed
  at the first out-of-order write. Always test with real writes before you
  trust a layer.
- **Silent failures need alerts on the kernel log.** During the btrfs ENOSPC
  failures, device error counters, SMART and mount flags all stayed clean. Only
  the kernel's `BTRFS error` lines showed the problem. Whatever your stack,
  alert on its kernel error messages, not only on device health.
- **After `mdadm --create --assume-clean`, run a full `repair`.** The
  reasoning was that unmapped dm-zoned regions read as zeros, so parity would
  be consistent from the start. The first repair of that build found **752
  mismatches** ([03](03-guest-storage-stack.md), step 6).
- **Boot scripts must wait for slow drives, with a limit.** The HC680s take
  roughly 100 s to 3 minutes to appear after the controller is attached. The
  first dm-zoned assembly unit gave up the moment a drive was missing, so the
  pool would have come up unassembled after every boot. The assembly units now
  wait per drive, with a bound ([03](03-guest-storage-stack.md)).
- **Restart the NAS watcher after you edit its config.** It reads the config
  only at start. Forgetting this cost two cutovers
  ([02](02-synology-controller-passthrough.md)).
- **A busy dm-zoned reclaim worker sits in D state for long periods, and that
  is normal.** It is a hang only when the worker is in D **and** the drives
  complete no commands. The sysfs counter `iodone_cnt` is hexadecimal. An ad
  hoc check that summed it with `awk` read every value as 0 and raised a false
  alarm. The metrics script uses shell arithmetic, which reads hex correctly
  ([05](05-operations-monitoring-performance.md)).
- **Do not close every zone on a large drive blindly.** A bare `blkzone close`
  walks all 100,584 zones. On the btrfs pool it ran about 25 minutes in
  uninterruptible I/O that `kill -9` could not stop. Closing only the open
  zones took seconds.
- **Fewer layers win.** The nested DSM matched the OpenMediaVault guest on
  throughput only by saturating two extra vCPUs, and it added a longer chain
  that must come up in the right order after every restart.

## Other pages

[01 — Requirements and risks](01-requirements-and-risks.md) ·
[02 — Synology controller passthrough](02-synology-controller-passthrough.md) ·
[03 — Guest storage stack](03-guest-storage-stack.md) ·
[04 — OpenMediaVault and Synology integration](04-openmediavault-and-synology-integration.md) ·
[05 — Operations, monitoring, performance](05-operations-monitoring-performance.md) ·
[07 — Prior art](07-prior-art.md) ·
[08 — Caching](08-caching.md)
