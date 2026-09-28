# 01 — Requirements and risks

Read this page before you buy drives or change anything on your NAS. It covers
what was tested, what your Synology must have, how to check that without
changing anything, what does not work, and what can go wrong.

> [!WARNING]
> **Tested on one setup only:** a Synology **DS3622xs+** with a **DX1222**
> expansion unit and three **WD Ultrastar DC HC680** host-managed SMR drives.
> No other model, expansion unit, controller or drive has been tried.
>
> **Known, unresolved risk:** on 2026-09-24 the NAS kernel panicked inside
> Synology's own driver for the *internal* drive bays. This happened a few minutes after
> the passed-through controller had been attached to a freshly started guest,
> while heavy writes were going through it. There have been two known crashes
> and both fit this pattern, but the cause is not proven. See
> [7.1](#71-nas-kernel-panic-in-dsms-own-storage-driver). If you build this,
> you accept that risk on your own hardware. Back up everything on the NAS
> first.

## 1. The short version

- DSM cannot use host-managed SMR drives at all, because every Synology kernel
  is built without `CONFIG_BLK_DEV_ZONED` ([section 3](#3-why-dsm-cannot-use-these-drives-itself)).
- The workaround gives **the whole SATA controller** the zoned drives sit
  behind to a Linux guest in DSM's Virtual Machine Manager (VMM). A current
  Linux kernel in that guest then owns the controller and the drives.
- This works only if **DSM uses that controller for none of its own disks**
  and the controller is **alone in its own IOMMU group**.
- On the tested DS3622xs+, that controller is the Marvell 88SE9235 behind the
  expansion connector the DX1222 is plugged into. DSM's 12 internal bays are on
  a different controller, which is never touched.
- It will **not** work if the zoned drives would share the controller that DSM
  boots and runs from. The author's example is a **DS1821+ in this layout**.
- DSM never sees the drives. It uses the pool over the network through Hyper
  Backup to an rsync module and an NFS remote folder
  ([04](04-openmediavault-and-synology-integration.md)).

## 2. What was tested

| Part | As tested | Notes |
|---|---|---|
| NAS | Synology DS3622xs+ | Intel Xeon D-1531 (6 cores / 12 threads), DSM 7.4, Linux 4.4.302 |
| Expansion unit | Synology DX1222 | Holds only the zoned drives |
| Controller given to the guest | Marvell 88SE9235, PCI ID `1b4b:9235`, AHCI | Sits on the DS3622xs+ itself, one per expansion connector. Has its own IOMMU group. Reaches the DX1222 drives through Marvell 88SM9705 port multipliers |
| DSM's own controller | Marvell 88SE1475, PCI ID `1b4b:1475`, Synology's `mv14xx` driver | Runs all 12 internal bays. **Never** unbound, reset or passed through |
| Drives | 3 × WD Ultrastar DC HC680 27 TB (`WSH722870AL…`) | 24.6 TiB each, 256 MiB zones, 1,006 conventional + 99,578 sequential-write-required zones, `max_open_zones` 128 |
| Hypervisor | DSM Virtual Machine Manager | Controller hot-plugged into the running guest with `virsh attach-device --live` |
| Guest | Debian 13 / OpenMediaVault 8, 4 vCPU, Q35 machine | Kernel: Ubuntu mainline `7.2.6-070206-generic` |
| Storage stack | dm-zoned per drive → md RAID5 → LUKS2 → XFS | 49.1 TiB usable ([03](03-guest-storage-stack.md)) |

```text
DS3622xs+ (DSM 7.4, Linux 4.4.302)
 ├─ 88SE1475 (1b4b:1475, mv14xx) ── 12 internal bays ── DSM's own disks    NEVER TOUCH
 ├─ 88SE9235 (1b4b:9235, ahci)   ── expansion connector ── DX1222 ── 3 × HC680
 │                                    └─> vfio-pci ─> VMM guest (Debian 13 / OMV 8)
 └─ 88SE9235 (1b4b:9235, ahci)   ── second expansion connector ── (empty)
```

> [!NOTE]
> The 88SE9235 is **not** in the DX1222. It is part of the DS3622xs+. With the
> DX1222 unplugged, DSM still lists both 9235s. When the DX1222 cable was moved
> to the other expansion connector, the drives moved to the other 9235. So
> "which controller holds the zoned drives" depends on which socket the cable
> is in. Check this again before any change. Do not rely on an address you
> wrote down earlier.

**Untested: everything not in the table above.** In particular:

- any other Synology model, including other models with expansion ports;
- AMD-based Synology models;
- other expansion units, or a DX1222 on a different NAS;
- other host-managed drives (other capacities or vendors), other drive counts,
  and any layout other than RAID5 over three drives;
- DSM versions other than 7.4, and DSM updates installed after this setup was
  built;
- guests other than Debian 13 / OpenMediaVault 8, and kernels other than the
  ones compared in [05](05-operations-monitoring-performance.md).

## 3. Why DSM cannot use these drives itself

A host-managed SMR drive accepts writes in its sequential zones only at each
zone's write pointer. It rejects writes anywhere else. Linux can use such a
drive only if the kernel is built with `CONFIG_BLK_DEV_ZONED` (zoned block
device support). Without that option, no part of Linux's zoned storage support
is built in.

What the research found:

- **No Synology kernel has it.** `CONFIG_BLK_DEV_ZONED` is off in all 45
  Synology toolkit kernel configs that were checked. The newest Synology kernel
  on any model is 5.10.55, unchanged since DSM 7.1.1. The DS3622xs+ platform
  (`broadwellnk`) and Virtual DSM (`kvmx64`) both run 4.4.302.
- **The zoned parts of the kernel are missing.** A DS923+ on DSM 7.4.1 was
  checked for zoned block support. The kernel had none of `blkdev_report_zones`,
  `blkdev_reset_zones`, `blk_queue_zoned` or `blk_revalidate_disk_zones`.
  There was no `sd_zbc.ko` and no `dm-zoned.ko`.
- **What you see in DSM:** on an AHCI path (the DX1222 on the DS3622xs+, and a
  DS923+), the HC680 appears only as a SCSI generic node `/dev/sgX` of type
  `Direct-Access-ZBC`. DSM creates no `/dev/sdX` for it, so Storage Manager
  cannot use it. SMART still works, for example
  `smartctl -i -d sat /dev/sgX`.
- **The drive cannot be converted.** `sg_rep_zones --domain` and `--realm`
  return *Illegal Request*. The HC680 does not support Zone Domains or Zone
  Realms, so it cannot be switched to conventional recording.
- **Xpenology kernels do not help.** The RR loader's "custom" kernel exists
  only for two platforms (`epyc7002`, `geminilakenk`, both 5.10) and also
  lacks zoned support.

One observation you should not rely on: in the DS3622xs+'s *internal*
(`mv14xx`) bays, the same drive model was once listed as an ordinary disk.
This project never used it that way. DSM would issue random writes that a
host-managed drive rejects, and those bays belong to DSM's production
controller.

**Why this guide passes the whole controller.** DSM creates no block device
for these drives, so the `scsi-block` route is unavailable. QEMU also supports
[`scsi-generic` through `/dev/sgX`](https://zonedstorage.io/docs/tools/qemu#qemu-virtio-scsi);
whether that works on DSM/VMM was not verified. Whole-controller passthrough
is the validated method here: the guest owns the controller and its kernel
exposes the drives as zoned block devices. Replacing DSM on the DS3622xs+ is
not practical either, because
mainline Linux has no driver for its internal 88SE1475 controller (see
[06](06-alternatives-and-lessons.md)).

## 4. Hard requirements

1. **An x86 Synology that runs Virtual Machine Manager, plus a root shell on
   DSM.** VMM has no PCI passthrough in its UI. The controller is attached with
   `virsh` as root (see [02](02-synology-controller-passthrough.md)).

2. **Working IOMMU (VT-d on Intel) in DSM.** `/sys/kernel/iommu_groups` must
   contain groups. On the tested NAS, VMM had already loaded `vfio`,
   `vfio_pci`, `vfio_iommu_type1`, `kvm_intel` and `kvm`, so nothing had to be
   built or loaded.

3. **A controller that DSM uses for none of its own disks, with only the
   zoned drives behind it.**
   *Why:* passthrough works per controller. When the controller is unbound
   from DSM, everything behind it disappears from DSM at once. DSM also mirrors
   its system partition across all of its disks. On the tested NAS, `md0` was a
   RAID1 over all 12 disks. So any controller that carries even one DSM disk is
   a controller DSM runs from. The expansion unit (or whatever else is behind
   the controller) must hold zoned drives only. Do not mix in DSM disks.

4. **That controller alone in its IOMMU group.**
   *Why:* VFIO hands over a whole IOMMU group. If the group also contains
   something DSM needs, such as another controller or a network card, you
   cannot pass the controller through without taking that device away from
   DSM.

5. **A guest that can take a hot-plugged PCIe device and has zoned support.**
   The guest needs a Q35 machine type and a kernel with
   `CONFIG_BLK_DEV_ZONED=y` and `CONFIG_HOTPLUG_PCI_PCIE=y`.
   *Why:* VMM builds each guest from its own generated definition every time
   the guest powers on, and it ignores a persistent libvirt definition. A
   hostdev entry therefore cannot be added permanently. Instead, a watcher on
   DSM hot-plugs the controller into the running guest after every guest start.

6. **Zoned drive models that differ from DSM's drive models.**
   *Why:* PCI addresses, `ata`/`host` numbers and `sgX` numbers are not stable
   identities. The cable move described above swapped which 9235 held the
   DX1222, and a VFIO rebind renumbered the `ata` ports. The watcher therefore
   finds the controller by the drive models behind it. It refuses any
   controller that has a DSM drive model behind it.

Recommended, not required:

- **One zoned drive per port-multiplier link.** In the DX1222, two drives that
  shared one 88SM9705 link reached 149 and 148 MiB/s under concurrent load. A
  drive with a link to itself reached 228 MiB/s. md RAID5 writes all members in
  lockstep, so the slowest link sets the pace. The author moved a drive to a
  different bay to fix this.

## 5. Check your NAS before you build anything (read-only)

**Every command in this section only reads.** Nothing here binds, unbinds or
resets a device. Run the commands as root on DSM. Do not start
[02](02-synology-controller-passthrough.md) until every check passes.

1. **CPU architecture and kernel.**

   ```sh
   uname -m      # must print x86_64
   uname -r      # the tested DS3622xs+ printed 4.4.302+
   ```

2. **VMM and virsh.**

   ```sh
   ls -l /usr/local/bin/virsh
   /usr/local/bin/virsh list --all --uuid --name
   ```

   If `virsh` is missing, VMM is not installed.
   *Why the list may be empty:* VMM defines its guests transiently, so
   `virsh list --all` shows a VMM guest only while it is running.

3. **IOMMU groups and VFIO modules.**

   ```sh
   ls /sys/kernel/iommu_groups | wc -l      # must be greater than 0
   grep -E '^(vfio|kvm)' /proc/modules
   ```

   *Why sysfs and not dmesg:* on the tested NAS, `dmesg` no longer had any
   useful DMAR/IOMMU lines, yet `/sys/kernel/iommu_groups` was fully populated.
   The sysfs directory is what counts. If it is empty, this guide cannot help
   you.

4. **List the storage controllers.**

   ```sh
   lspci -nnk
   ```

   The same information straight from sysfs, with the IOMMU group of each mass
   storage device (PCI class `0x01…`):

   ```sh
   for d in /sys/bus/pci/devices/*; do
     c=$(cat "$d/class")
     case "$c" in 0x01*)
       drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
       grp=$(basename "$(readlink "$d/iommu_group" 2>/dev/null)" 2>/dev/null)
       echo "${d##*/} $(cat "$d/vendor"):$(cat "$d/device") class=$c driver=$drv group=$grp"
     ;; esac
   done
   ```

5. **Find the controllers DSM uses for its own disks.**

   ```sh
   ls -l /sys/block/
   cat /proc/scsi/scsi
   ```

   The link target of each DSM disk contains the PCI address of its
   controller. On the tested NAS, all twelve internal disks resolved through
   `…/0000:07:00.0/host8/…`. Write down **every** address that shows up here.
   Those are DSM's controllers, and none of them may ever be passed through.
   Host-managed drives behind an AHCI controller do not show up in
   `/sys/block` on DSM at all. They are listed in `/proc/scsi/scsi` as
   `Direct-Access-ZBC`.

6. **See what is behind the candidate controller.** Replace `<CANDIDATE>`
   with its full PCI address, for example `0000:xx:yy.z`.

   ```sh
   cat /sys/bus/pci/devices/<CANDIDATE>/ata*/host*/target*/*/model
   ```

   This is the same path the watcher uses for its model census. It passes if
   the output lists only your zoned drive model. On the tested unit that was
   `WDC WSH722870ALE604`, three times. It fails if any disk from step 5 or any
   DSM drive model appears. Behind the 9235, `/proc/scsi/scsi` also listed
   Synology `Virtual Device` entries that come and go with the expansion
   unit. Those are not disks.

7. **Check the candidate's IOMMU group.**

   ```sh
   basename "$(readlink /sys/bus/pci/devices/<CANDIDATE>/iommu_group)"
   ls /sys/kernel/iommu_groups/<GROUP>/devices/
   ```

   This passes if the second command lists only `<CANDIDATE>`. Run the first
   command for each of DSM's controllers from step 5 as well. Each one must be
   in a different group from the candidate.

8. **After you create the guest** (see [02](02-synology-controller-passthrough.md)),
   check its machine type on DSM and its kernel inside the guest:

   ```sh
   # on DSM, while the guest is running
   /usr/local/bin/virsh dumpxml <GUEST_DOMAIN_UUID> | grep -o "machine='[^']*'"
   # expect machine='pc-q35-…'

   # inside the guest
   grep -E 'CONFIG_BLK_DEV_ZONED=|CONFIG_HOTPLUG_PCI_PCIE=' /boot/config-$(uname -r)
   # expect both =y
   ```

What this looked like on the tested DS3622xs+. These are **the author's
addresses. Do not copy them.** PCI addresses are specific to each machine.

| Address | PCI ID | Class | Driver | IOMMU group | Behind it |
|---|---|---|---|---:|---|
| `0000:07:00.0` | `1b4b:1475` | `0x010000` (SCSI storage) | `mv14xx` | 20 | 12 DSM disks — **protected** |
| `0000:10:00.0` | `1b4b:9235` | `0x010601` (SATA AHCI) | `ahci`, `vfio-pci` once attached | 28 | DX1222 + 3 × HC680 |
| `0000:13:00.0` | `1b4b:9235` | `0x010601` (SATA AHCI) | `ahci` | 31 | nothing (second expansion connector) |

> [!CAUTION]
> Do not bind by vendor:device ID (for example `vfio-pci.ids=1b4b:9235`). The
> DS3622xs+ has two 9235s with the same ID, and ID-based binding would take
> both. On another model, the same ID could match a controller DSM needs.
> Bind by exact PCI address only, the way
> [02](02-synology-controller-passthrough.md) does.

**Go / no-go:**

| Check | Go | No-go |
|---|---|---|
| `uname -m` | `x86_64` | anything else |
| VMM / `virsh` | present | missing |
| `/sys/kernel/iommu_groups` | has groups | empty |
| Candidate controller | only zoned drives behind it | any DSM disk behind it |
| Candidate's IOMMU group | contains only the candidate | shares a group with anything else |
| DSM's controllers | all in groups other than the candidate's | any in the candidate's group |

## 6. Not supported

- **DS1821+ in this layout.** This is the author's example of a model where the
  setup will not work: there, the zoned drives would share the controller DSM
  itself runs from. The author did not try it.
- **Any model or layout where the zoned drives sit on a controller that DSM
  uses for its own disks.** Passing that controller to a guest takes DSM's own
  disks with it. See requirement 3.
- **The DS3622xs+'s internal bays.** They are on the 88SE1475 (`mv14xx`), which
  is DSM's production controller.
- **An expansion unit that mixes DSM disks and zoned drives.** The whole
  controller goes to the guest, so every drive in that unit goes with it.
- **Empty `/sys/kernel/iommu_groups`**, or a controller that shares its IOMMU
  group with a device DSM needs.
- **Synology models that cannot install Virtual Machine Manager.**
- **Nested passthrough.** This means handing the controller on from a
  hypervisor that itself runs as a VMM guest, for example a Proxmox VM on the
  NAS, to a VM inside it. The author tried this and it was not possible. The
  VMM guest had no IOMMU groups and no DMAR table. VMM also ignores persistent
  libvirt definitions, so a virtual IOMMU could not be added to the guest
  permanently.
- **Per-disk passthrough.** `scsi-block` requires a block device DSM does not
  expose here. `scsi-generic` using `/dev/sgX` is unverified on DSM/VMM and is
  outside this guide ([section 3](#3-why-dsm-cannot-use-these-drives-itself)).
- **VMM live migration or VMM High Availability for the guest** while the
  controller is attached.

## 7. Risks

### 7.1 NAS kernel panic in DSM's own storage driver

**What happened on 2026-09-24:**

- The watcher attached the 9235 to a guest that had just been started. Over
  the next few minutes, a RAID5 was created over the three dm-zoned devices,
  formatted with XFS and mounted. This sent sustained writes through the
  passed-through controller.
- The NAS kernel then hit an internal assertion in `mv14xx`, in the function
  `sg_iter_walk`, while it was preparing a 56 KiB request. `mv14xx` is
  Synology's driver for the **internal** 88SE1475, not for the passed-through
  controller. The scatter-gather pointer it followed looked like a
  physical/DMA address, not a kernel address. The driver's retry timer went
  back to the same request, faulted on the same address, and the kernel
  panicked with `Fatal exception in interrupt`. The NAS reset and was back
  about three minutes later.
- DSM, every VMM guest and all iSCSI sessions from other hosts went down with
  it. DSM's own arrays came back clean: not degraded, with 0 parity
  mismatches. The DSM disk on the port the driver reset was healthy: SMART
  passed and it logged no CRC or ATA errors.
- In the guest, one dm-zoned reclaim worker was stuck after the restart.
  Edits made to `/etc/fstab` and `/etc/mdadm/mdadm.conf` shortly before the
  panic were gone.
- An earlier unclean reset on 2026-09-19 happened in the same second as a
  watchdog reset of another VMM guest. That guest was carrying the
  passed-through 9235 at the time. That reset's kernel output was not
  captured.

**What is known and what is not:**

- **Both known crashes fit the same pattern.** Each time, a VMM guest carrying
  the passed-through 9235 had been started, with I/O going through the
  controller. That is a correlation, not a cause.
- **The mechanism is not proven.** The fault is inside Synology's closed
  driver. Other VMM activity was also going on in the same minutes. This NAS
  had also had unexplained resets earlier in 2026, before the controller was
  ever passed through.
- **Since then** (up to 2026-09-26), the controller has been attached to
  freshly started guests several more times. The NAS also carried hours of
  sustained writes through it: a 491 GiB Hyper Backup run over about 3.5 hours,
  a pool build with a parity sync, and a stress test with more than an hour of
  saturation. No NAS kernel fault or panic was recorded in that time.
- The issue has not been reported to Synology. The author has chosen to keep
  running the setup and accept the risk.

**What this means for you:**

- A panic takes down all of DSM, not just the pool. **Back up the NAS's own
  data** before you start.
- This panic could be analysed only because the NAS sent its kernel log over
  the network (netconsole) to another machine. DSM's own logs keep nothing
  from before the reset, so a panic looks like a power cut. If you can, set up
  remote kernel logging before you start.
- The author's working rule since then: avoid unnecessary restarts of the
  guest that carries the controller. After a problem, try to remount in place
  before restarting the guest.
- After any NAS crash, re-check recent configuration changes in the guest.

### 7.2 Not supported by Synology

- VMM has no PCI passthrough option. You change a running guest with `virsh`,
  outside VMM. VMM rebuilds the guest's definition at every power cycle, so
  the attach lasts only while the guest runs. The watcher redoes it after
  every guest start ([02](02-synology-controller-passthrough.md)). A NAS
  reboot also drops the VFIO binding.
- If you unbind the wrong controller, DSM's volumes go offline. The watcher
  refuses DSM's controller address, any wrong vendor or device ID, and any
  controller with a DSM drive model behind it. Those checks protect only what
  you configure correctly.
- A DSM update can change any part this depends on: the kernel, VMM, where
  `virsh` lives, and the boot hook. Nothing here has been tested against DSM
  releases after 7.4.
- If the guest or the controller is missing, the pool is simply offline. DSM
  itself is not affected.

### 7.3 Ways to lose data

1. **Detaching the wrong controller.** DSM loses its disks. Prevent this with
   the protected address and the model census ([02](02-synology-controller-passthrough.md)).
2. **A NAS crash while the pool is writing.** The guest stops uncleanly. Recent
   writes and configuration edits can be lost, as happened in
   [7.1](#71-nas-kernel-panic-in-dsms-own-storage-driver), and md may have to
   resync.
3. **Two failed members.** RAID5 survives one lost member and no more. Each
   member is a dm-zoned device on one drive, so losing two drives, or two
   dm-zoned mappings, loses the whole array. RAID5 is redundancy, not a backup.
4. **Wrong parity after `--assume-clean`.** In an earlier build,
   `mdadm --create --assume-clean` over freshly formatted dm-zoned devices left
   **752 parity mismatches**. Until a full `repair` pass has run, a drive
   failure would rebuild wrong data for those stripes. Always run the repair
   ([03](03-guest-storage-stack.md)).
5. **md RAID directly on host-managed drives.** Creating the array succeeds and
   it even reports `zoned=host-managed`. Then the first filesystem write fails
   with I/O errors on every member. Always put dm-zoned underneath md.
6. **A zoned filesystem instead of dm-zoned.** The earlier design (zoned btrfs
   + mergerfs + SnapRAID) lost data silently on these drives. On an ENOSPC
   error during writeback, the filesystem stayed read-write, the application
   was told its write had succeeded, and files were left with holes
   ([06](06-alternatives-and-lessons.md)).
7. **Lost LUKS keys.** If you lose both the keyfile and every passphrase, or
   the LUKS header is damaged and you have no header backup, the data is gone.
   The drives alone are unreadable ([03](03-guest-storage-stack.md)).

### 7.4 SMR throughput drops

- **The dm-zoned buffer.** dm-zoned stages random writes in the drive's
  conventional zones. On the HC680 that is 998 usable zones per drive, about
  250 GiB. Writes are fast while the buffer has room. It drains only when the
  pool is idle.
- **Stress test on 2026-09-26.** Load: a Hyper Backup seed, a media rsync of
  about 3 TB and an md repair, all at once. The pool took 116–143 MB/s while
  the buffer filled at about 13–17 zones per minute. The buffer was about
  40 % full at the first sample and full about 45 minutes after the test
  started. From then on, writes settled
  at **38–69 MB/s**. The drives were 86–99 % busy, with reclaim reading
  28–44 MB/s per drive. There was no hang and no error through more than an
  hour of saturation. md repair slowed itself to its 10 MB/s minimum.
- **Earlier single-stream measurement** (before LUKS was added): 186–204 MiB/s
  with an empty buffer, 56–83 MiB/s once the buffer was more than 85 % full.
  When idle, the buffer drained at about 7 zones per minute, about 2 hours
  from full to empty.
- **The kernel matters most.** These results use the same stack and the same
  60-second tests: one O_DIRECT writer with 1 MiB writes, and four buffered
  writers.

  | Guest kernel | O_DIRECT, 1 writer | Buffered, 4 writers |
  |---|---:|---:|
  | Debian 6.12.107 | 24.6 MiB/s | – |
  | Debian backports 7.1.8 | 24.7 MiB/s | 34.4 MiB/s |
  | Ubuntu mainline 7.2.6 | 165.4 MiB/s | 261.4 MiB/s |
  | Zabbly 7.2.7 | 58–69 MiB/s | 210.7 MiB/s |

  Why 7.2 is faster is **unknown**. On every kernel, md RAID5 passes dm-zoned
  4 KiB writes, and `block/blk-zoned.c` is byte-identical in 7.1.8 and 7.2.
  Details are in [05](05-operations-monitoring-performance.md).
- **Port multipliers.** Two drives on one 88SM9705 link share its bandwidth
  (see [section 4](#4-hard-requirements)).

The author uses the pool as a backup target and a media store. With these
numbers, plan big initial copies to take longer than the network speed
suggests.

### 7.5 Kernel and software maturity

- The fast kernel is a manually installed Ubuntu mainline build. It gets no
  automatic security updates and has no production support. Keep a packaged
  kernel installed as a boot fallback.
- Versions 7.2.0–7.2.6 have a SLUB freelist race that 7.2.7 fixes. It was
  judged low risk because the only known trigger is a deliberate exploit.
- On 7.2.6, a dm-zoned reclaim worker got stuck in D state twice, both times
  right after the array was reassembled following a host power event. Once it
  needed a guest reboot. The other time it cleared by itself. No upstream
  report or fix exists. The mitigation is monitoring, automatic evidence
  capture, and a reboot ([05](05-operations-monitoring-performance.md)).
  Watch out for a false alarm here: a busy reclaim worker also sits in D state
  for long periods. It is a hang only if the worker is in D **and** the drives
  complete no commands.

## 8. What you need

- **Backups.** Back up the NAS's own data, because of
  [7.1](#71-nas-kernel-panic-in-dsms-own-storage-driver). Also plan how to
  refill the pool: the author rebuilt it from scratch several times during
  this project and re-seeded it from DSM each time.
- **Drives you can wipe.** `dmzadm --format` resets every zone on the drive.
- **A root shell on DSM**, and a willingness to run a watcher script from a
  boot hook that Synology does not support ([02](02-synology-controller-passthrough.md)).
- **A Linux guest you can administer.** You will install a mainline kernel by
  hand, write systemd units, and use `mdadm`, `cryptsetup` and `dmsetup`.
  You will also read `dmesg`. OpenMediaVault does not know about dm-zoned, so
  the assembly chain runs from your own scripts and units
  ([03](03-guest-storage-stack.md)).
- **CPU headroom.** The author's guest has 4 vCPUs on a 6-core / 12-thread Xeon
  D-1531, shared with DSM and its other guests.
- **Monitoring.** Use the metrics script and Prometheus rules in
  [05](05-operations-monitoring-performance.md). If possible, also send the
  NAS kernel log to another machine.
- **Time.**
  - After each attach, the drives take roughly 1.5–3 minutes to appear in the
    guest. Most of that is libata retrying a phantom port-multiplier port.
  - After a reboot inside the guest, the encrypted pool was mounted about
    90–100 seconds into boot. A VMM power cycle adds the re-attach on top.
  - A full md `repair` pass is estimated at 33–40 hours, at about
    175–205 MB/s on an otherwise idle pool. The reference repair took 40.5
    hours, with heavy writes running at the same time, and found 0
    mismatches.
  - Large initial copies slow to about 40–70 MB/s once the dm-zoned buffer is
    full ([7.4](#74-smr-throughput-drops)).

## Next

If every check in [section 5](#5-check-your-nas-before-you-build-anything-read-only)
passed, continue with
[02 — Synology controller passthrough](02-synology-controller-passthrough.md).

Other pages:
[03 — Guest storage stack](03-guest-storage-stack.md) ·
[04 — OpenMediaVault and Synology integration](04-openmediavault-and-synology-integration.md) ·
[05 — Operations, monitoring, performance](05-operations-monitoring-performance.md) ·
[06 — Alternatives and lessons](06-alternatives-and-lessons.md) ·
[07 — Prior art](07-prior-art.md)
