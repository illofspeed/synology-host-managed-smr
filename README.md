# Host-managed SMR drives with a Synology NAS

Synology DSM cannot use host-managed SMR (zoned) drives at all: every DSM
kernel for Synology's own hardware is built without `CONFIG_BLK_DEV_ZONED`.
This repository documents how the author runs three such drives with a
Synology anyway. The drives sit in an expansion unit behind a SATA controller
that DSM does not use for its own disks. A watcher on the NAS hands that
**whole controller** to a Debian 13 / OpenMediaVault 8 guest in DSM's Virtual
Machine Manager (VMM). The guest builds **dm-zoned → md RAID5 → LUKS2 → XFS**
on the drives and serves the pool back to DSM over the network, as a Hyper
Backup rsync target and an NFS remote folder. It is an as-built report of one
system with the scripts, units, configs and monitoring it uses, the
measurements taken on it, and the failures found on the way.

> [!IMPORTANT]
> **Tested hardware: exactly one setup.**
>
> - **NAS:** Synology **DS3622xs+** (Intel Xeon D-1531, DSM 7.4, Linux 4.4.302)
> - **Expansion unit:** Synology **DX1222**, holding only the zoned drives
> - **Drives:** 3 × **WD Ultrastar DC HC680** 27 TB host-managed SMR
>   (`WSH722870AL…`, 24.6 TiB, 256 MiB zones)
>
> Every other Synology model, expansion unit, controller, drive and DSM version
> is **untested**.
>
> **Hard requirement: the zoned drives must be on a controller that DSM does
> not use for any of its own disks, and that controller must be alone in its
> own IOMMU group.** Passthrough works per controller: whatever sits behind it
> leaves DSM at the moment it is unbound. On the DS3622xs+ this is the Marvell
> 88SE9235 behind the expansion connector the DX1222 is plugged into. DSM's 12
> internal bays run on a different controller (Marvell 88SE1475, Synology's
> `mv14xx` driver), which is never touched. You also need an x86 Synology with
> VMM and working VT-d/IOMMU (`/sys/kernel/iommu_groups` must not be empty).
>
> **Counter-example: a DS1821+ in this layout will not work.** There the zoned
> drives would share the controller DSM boots and runs from, and passing it to
> a guest would take DSM's own disks with it. The same applies to any model or
> layout where the zoned drives would sit on one of DSM's controllers. Check
> your NAS with the read-only steps in
> [01, section 5](docs/01-requirements-and-risks.md#5-check-your-nas-before-you-build-anything-read-only)
> before you buy drives.

> [!WARNING]
> **Known, unresolved risk.** On 2026-09-24 the NAS kernel panicked inside
> Synology's `mv14xx` driver, the driver of DSM's **own** controller, a few
> minutes after the passed-through 88SE9235 had been attached to a freshly
> started guest, while heavy writes went through it. Both known crashes of this
> NAS fit that pattern (2 of 2), but the mechanism is **not proven**. Since
> then the setup has carried many hours of heavy I/O without a recurrence. If
> you build this, you accept that risk on your own hardware. **Back up the
> NAS's own data first.** Details:
> [01, section 7.1](docs/01-requirements-and-risks.md#71-nas-kernel-panic-in-dsms-own-storage-driver).

## Architecture

```text
Synology DS3622xs+  (DSM 7.4, Linux 4.4.302)
│
├── Marvell 88SE1475 (mv14xx) ── 12 internal bays ── DSM's own volumes     NEVER TOUCHED
│
├── Marvell 88SE9235 (own IOMMU group) ── DX1222 (88SM9705 port multipliers) ── 3 × HC680
│        │
│        │  watcher: synology-zoned-attach.sh, started by an rc.d boot hook, polls every 15 s
│        │   - model census: exactly 3 zoned drives and no DSM drive behind the controller
│        │   - refuses DSM's controller address; binds by PCI address, never by ID
│        │   - unbind from ahci -> bind to vfio-pci -> virsh attach-device --live
│        │   - repeats after every guest start (VMM regenerates the domain on power-on)
│        ▼
└── VMM guest: Debian 13 / OpenMediaVault 8, Q35, 4 vCPU, kernel 7.2.6-070206-generic
         │
         │  HC680      HC680      HC680      host-managed; appear 1-3 min after the attach
         │    │          │          │
         │   dz1        dz2        dz3       dm-zoned per drive (dmzadm --format),
         │    │          │          │        ~250 GiB conventional-zone buffer each
         │    └──────────┼──────────┘
         │             md127                 md RAID5, 3 members, 512K chunk, 49.1 TiB
         │               │
         │          hc680crypt               LUKS2 aes-xts-plain64, 512-bit key, 4096-byte
         │               │                   sectors, argon2id; keyfile unlock at boot
         │           /srv/hc680              XFS -d su=512k,sw=2
         │               │
         │   late boot chain: zonedpool-dmzassemble -> zonedpool-mdassemble
         │                    -> zonedpool-cryptopen -> srv-hc680.mount (nofail)
         │
         ├── rsync daemon :873 ── module hc680-backup ◄── DSM Hyper Backup task
         ├── rsync daemon :873 ── module hc680-media  ◄── rsync push from the DSM shell
         ├── NFS v4 /media (bind of /srv/hc680/media) ◄── DSM File Station remote folder
         │                                                 └── media server (Plex) reads it
         └── SMB [media]                              ◄── other clients

DSM never sees the drives. It reaches the pool only over the network.
```

## Measured results

All numbers are from the one tested system, on the finished encrypted pool
unless noted. Details and caveats are in
[05](docs/05-operations-monitoring-performance.md).

**The guest kernel matters most.** Same stack, same guest, same two 60-second
tests: one `O_DIRECT` writer with 1 MiB blocks, and four buffered writers
including the final sync.

| Guest kernel | 1 writer, O_DIRECT 1 MiB | 4 writers, buffered |
|---|---:|---:|
| Debian 13 `6.12.107` | 24.6 MiB/s | not measured |
| Debian backports `7.1.8` | 24.7 MiB/s | 34.4 MiB/s |
| Ubuntu mainline `7.2.6-070206-generic` | **165.4 MiB/s** | **261.4 MiB/s** |
| Zabbly `7.2.7` | 58–69 MiB/s (3 runs) | 210.7 MiB/s |

md RAID5 hands dm-zoned 4 KiB writes on every one of these kernels. **Why 7.2
is faster is unknown.** `block/blk-zoned.c` is byte-identical in 7.1.8 and 7.2,
so it is not zone write plugging. The author runs Ubuntu mainline 7.2.6, pinned
in GRUB.

**Behaviour under sustained load** (kernel 7.2.6, stress test on 2026-09-26: a
Hyper Backup seed, a ~3 TB rsync push and an md parity repair at the same time):

| Phase | Writes into the pool | dm-zoned buffer | Drives |
|---|---|---|---|
| Buffer filling | 116–143 MB/s (the NAS side was the limit) | fills at ~13–17 zones/min per drive | 81–97 % busy once reclaim started copying, ~3 min in |
| Buffer full, from ~45 min in | **38–69 MB/s** | 998/998 on one drive, 986–992 on the others | 86–99 % busy; reclaim reading 28–44 MB/s per drive |

The saturated state held for more than an hour with no hang and no errors. The
md repair backed off to its 10 MB/s floor with 0 mismatches. The buffer drains
only while the pool is idle, and on 7.2.6 the idle drain may need a kick
([05, 1.2.1](docs/05-operations-monitoring-performance.md#121-the-idle-drain-can-stall-kernel-726-install-the-reclaim-kick)).

**Result of the first real load (2026-09-26 to 09-28):** 3.19 TB of media (667
files) copied in over about 20 hours at 45–55 MB/s, byte- and file-exact
against the source, while a Hyper Backup seed and the mandatory md repair ran
at the same time. The repair finished after 40.5 hours with **0
mismatches**. No kernel errors on the pool, no stuck reclaim worker, SMART clean
on all three drives.

**Independent reproduction (2026-09-28):** another agent rebuilt the guest side from
nothing, following only these docs, on three emulated host-managed drives (file-backed
ZBC with conventional and sequential zones, 32 GiB each). The whole chain came up
unattended after reboots, the repair ended at 0 mismatches, the buffer filled and
drained after a reclaim kick, and NFS and rsync worked from another host. Its findings
(a missing OMV install step, a duplicate fstab entry, two recovery commands that did
nothing, a watcher fallback that could skip the census, metric names failing
`promtool` lint) are fixed in this version. The emulation does not cover the NAS side,
real SATA drives or their timing.

**Drive replacement and caching (2026-09-28/29).** One healthy member was pulled hot while
reads ran, put back into another bay, re-formatted and rebuilt
([05, 3.7](docs/05-operations-monitoring-performance.md#37-replacing-a-drive-tested-2026-09-28)).
- Degraded reads stayed byte-identical.
- The hot-plug froze every drive on that port multiplier for 12 s (pull) and 25 s (insert),
  with 0 errors on the others.
- **The rebuild is the weak spot:** every rebuilt chunk goes through the new member's own
  buffer and reclaim, so it ran at 26-30 MB/s, **about 10 days**.
- A cache device for that member (a NAS virtual disk behind DSM's NVMe cache) brought it to
  73-178 MB/s, **2-3 days**.
- A dm-cache volume cache between the RAID and LUKS made random I/O 20-40 times faster
  (4 KiB random read 303 → 9,804-12,859 IOPS) and stays warm across reboots.

Both caches make the pool depend on the cache device. Everything is in
[08 — Caching](docs/08-caching.md).

**Cache devices without a rebuild, and all members cached (October 2026).**
- New tools attach or detach a member's dm-zoned cache device in **~3 minutes**, without reformatting
  and without a rebuild; md takes the member back with a **5-second** bitmap resync. Eight conversions
  on the real 27 TB members.
- 1.5 TiB of fresh writes: plain members **201 MB/s for ~500 GiB, then 45 MB/s (~7 h)**; every member
  cached, NAS SSD-cache threshold at DSM's default: **155 MB/s, then 75–117 MB/s (5.1 h)**, drives writing
  each byte about once instead of almost three times.
- Three bugs found and patched (dm-zoned reclaim, `dmzadm --check`, libahci FBS), plus a drill in which
  `dmzadm --repair` destroyed a member's data — and how to recover instead.
- Everything is in [09 — Cache devices without a rebuild, fixes, results](docs/09-cache-devices-fixes-results.md).

| Other measurements | Result |
|---|---|
| Hyper Backup alone, kernel 7.2.6 | ~68 MB/s into the pool, drives ~22 % busy |
| Buffer drain while idle (measured before LUKS was added) | ~7 zones/min per drive, ~2 h from full to empty |
| Buffer drain after a reclaim kick, with LUKS | ~8 zones/min per drive, ~1.5 h |
| md repair or resync on an idle pool | 173–205 MB/s; a full pass takes ~33–40 h |
| LUKS2 aes-xts 512-bit, `cryptsetup benchmark`, one thread | ~950 MiB/s encrypt, ~1020 MiB/s decrypt |
| Pool mounted after a reboot inside the guest | ~90–100 s into boot (with cache layers: shutdown ~5 min, mount ~2.5 min after kernel start) |
| Member rebuild (24.6 TiB) | ~26–30 MB/s, ~10 days; with a cache device 73–178 MB/s, 2–3 days |
| After a VMM power cycle of the guest | add ~2.5 min for re-attach and drive enumeration |
| DSM itself on the drives: DSM 7.4 (SA6400, RR loader, "Kernel: custom") in a VM with **2 vCPU**, inside a Proxmox VE guest that owns the controller | Tested, and it works: a normal DSM RAID5 pool on the three drives. md resync 177–197 MB/s per disk with 2 vCPU, 111–117 MB/s with 4. The author decided to stay with OpenMediaVault. Recipe and caveats in [06, section 4](docs/06-alternatives-and-lessons.md#4-dsm-on-the-drives-through-a-nested-dsm-vm-tested-works) |

## Known risks, in brief

1. **NAS kernel panic** in DSM's own storage driver, correlated 2 of 2 with
   passthrough activity, cause unproven (see the warning above). A panic takes
   down all of DSM, not just the pool.
2. **Not supported by Synology.** VMM has no PCI passthrough; the controller is
   attached with `virsh` as root, outside VMM. Any DSM update may change what
   this depends on.
3. **A dm-zoned reclaim worker got stuck in D state twice** on 7.2.6, both
   times right after the array was reassembled following a power event on the
   NAS. Once it needed a guest reboot; once it cleared by itself. No upstream
   report or fix exists. The mitigation is monitoring that tells a hang from
   busy reclaim, automatic evidence capture, and a reboot. Separately, 7.2.6's
   idle buffer drain can stall; a 15-minute reclaim-kick timer works around it.
4. **It goes against published advice.** Western Digital's zoned storage
   documentation does not recommend dm-zoned, and nobody else was found
   running md RAID on top of it ([07](docs/07-prior-art.md)).
5. **Throughput is uneven.** It drops to roughly 40–70 MB/s once the dm-zoned
   buffer is full, and it depends heavily on the guest kernel.
6. **The fast kernel is a hand-installed mainline build**, with no automatic
   security updates. Kernels 7.2.0–7.2.6 have a SLUB freelist race that 7.2.7
   fixes (rated low risk: the only known trigger is a deliberate exploit).
7. **Ways to lose data:** detaching the wrong controller; a NAS crash during
   writes; two failed members (RAID5 survives one); skipping the full `repair`
   after `mdadm --create --assume-clean` (an earlier build had 752 parity
   mismatches); losing the LUKS keyfile and every passphrase. RAID5 is not a
   backup.
8. **DSM loses the expansion unit.** With the controller passed through, DSM
   no longer sees the DX1222, so its fan-speed setting no longer applies to it
   and nothing reports the unit's own fans or sensors. Only the drives' SMART
   temperatures remain, and the monitoring alerts on those
   ([01, 7.6](docs/01-requirements-and-risks.md#76-dsm-loses-the-expansion-unit-fans-included)).
9. **A member rebuild takes about 10 days** without a cache device, with no redundancy
   meanwhile. The array has no write-intent bitmap (mdadm skips it with `--run`), and
   `mdadm-last-resort` can start it without a slow member at boot. Either turns a short
   hiccup into a full rebuild; both are covered in
   [03, Step 5](docs/03-guest-storage-stack.md#step-5---create-the-raid5)
   ([01, 7.7](docs/01-requirements-and-risks.md#77-a-member-rebuild-takes-about-10-days)).
10. **Optional cache layers tie the pool to the cache device.** With cache devices on the
    NAS's own volume, losing that volume loses the pool too
    ([01, 7.9](docs/01-requirements-and-risks.md#79-cache-devices-make-the-pool-depend-on-them)).
11. **The published scripts are adapted, not the exact as-built files.** The
   NAS watcher, its boot hook and the metrics script were made configurable
   and gained extra checks. The watcher and hook were exercised against a
   simulated sysfs tree, not on a Synology, and the published metrics script
   was not run on the reference system. Each file lists its differences from
   the as-built version.

The full list, with what to do about each, is in
[01, section 7](docs/01-requirements-and-risks.md#7-risks).

## Start here

Read in this order:

1. [01 — Requirements and risks](docs/01-requirements-and-risks.md): what was
   tested, why DSM cannot use the drives, the hard requirements, a read-only
   go/no-go check for your NAS, and the risks.
2. [02 — Synology controller passthrough](docs/02-synology-controller-passthrough.md):
   finding the controller, creating the VMM guest, installing the watcher and
   its boot hook, verifying the attach, moving the controller between guests.
3. [03 — Guest storage stack](docs/03-guest-storage-stack.md): kernel choice,
   dm-zoned, md RAID5, LUKS2, XFS, and the late boot chain (with the reboot
   test that must pass before you store data).
4. [04 — OpenMediaVault and Synology integration](docs/04-openmediavault-and-synology-integration.md):
   the OMV mount entry, shares, NFS, SMB, rsync modules, the Hyper Backup task,
   the NFS remote folder in DSM, and bulk copies from DSM.
5. [05 — Operations, monitoring, performance](docs/05-operations-monitoring-performance.md):
   what normal looks like, metrics and alerts, maintenance, drive replacement
   (tested once, 2026-09-28) and a recovery playbook.
6. [06 — Alternatives and lessons](docs/06-alternatives-and-lessons.md): zoned
   btrfs + mergerfs + SnapRAID (abandoned after silent data loss), DSM on the
   drives through a nested DSM VM on a Proxmox VE guest with 2 vCPU (tested, it
   works, but the author stayed with OpenMediaVault), layers that fail directly on
   host-managed drives, and the kernel comparison.
7. [07 — Prior art](docs/07-prior-art.md): what already exists, the published
   advice against this design, and what this repository adds.
8. [08 — Caching](docs/08-caching.md) (optional): why a rebuild takes 10 days, a cache
   device per dm-zoned member, a dm-cache volume cache between the RAID and LUKS, and how to
   make DSM's SSD cache take their I/O.
9. [09 — Cache devices without a rebuild, fixes, results](docs/09-cache-devices-fixes-results.md)
   (optional): attach/detach tools, plain vs cached benchmarks, three patches, the
   `dmzadm --repair` trap, `mdadm --replace`, crash test.

## Repository layout

```text
.
├── README.md
├── LICENSE                                GNU GPL v3
├── docs/                                  01-09, see "Start here"
├── scripts/
│   ├── nas/                               runs on DSM, as root
│   │   ├── synology-zoned-attach.sh       watcher: model census, vfio-pci bind, live attach;
│   │   │                                  modes census | status | once | watch
│   │   ├── attach.conf.example            its config (read once, at start: restart after edits)
│   │   ├── S99zoned-attach.sh             /usr/local/etc/rc.d boot hook: start|stop|restart|status
│   │   └── flashcache-seq-skip.sh         optional: set DSM's SSD-cache sequential threshold (08, 09)
│   └── guest/                             runs in the Linux guest, as root
│       ├── zonedpool-dmzassemble          creates the dm-zoned mappers from by-id at boot
│       │                                  (optionally with a cache device per member, 08)
│       ├── zonedpool-volcache             optional dm-cache volume cache between md and LUKS (08)
│       ├── zonedpool-reclaim-kick         keeps dm-zoned's idle buffer drain going (7.2.6)
│       ├── zonedpool-encache-member       attach a cache device to a live member, no rebuild (09)
│       ├── zonedpool-uncache-member       detach it again (09)
│       └── zoned-pool-metrics             node_exporter textfile metrics + hang evidence capture
├── tools/                                 offline dm-zoned metadata tools (09)
│   ├── dmz-encache.py                     single-device → cache-device layout, data stays in place
│   ├── dmz-uncache.py                     cache-device → single-device layout
│   ├── dmz-metaset.py                     inspect / copy dm-zoned metadata sets (instead of dmzadm --repair)
│   └── dmz-cache-layout-SPEC.md           on-disk layout and the source references behind the tools
├── patches/                               kernel 7.2 / dm-zoned-tools 2.2.2 (09, section 4)
│   ├── dm-zoned-reclaim.patch             no random→random loop, reclaim worker keeps polling
│   ├── dmzadm-check-conv-zones.patch      no segfault checking two-device sets
│   └── libahci-fbs-reenable.patch         FBS back on after port-multiplier error handling
├── systemd/                               the late boot chain in the guest, plus the kick timer
│   ├── zonedpool-dmzassemble.service
│   ├── zonedpool-mdassemble.service
│   ├── zonedpool-cryptopen.service
│   ├── zonedpool-cryptopen.service.d/volcache.conf   with the volume cache: LUKS only on it (08)
│   ├── zonedpool-volcache.service         optional volume cache (08)
│   └── zonedpool-reclaim-kick.{service,timer}
├── examples/                              guest config files, with placeholders
│   ├── dmzoned.conf.example               /etc/zonedpool/dmzoned.conf
│   ├── mdadm.conf.example                 /etc/mdadm/mdadm.conf
│   ├── crypttab.example                   /etc/crypttab (the entry must be noauto)
│   └── fstab.example                      /etc/fstab, as OMV generates it
└── monitoring/
    └── prometheus-rules.yml               ten Hc680* alert rules for Prometheus
```

Placeholders such as `<GUEST_IP>`, `<GUEST_DOMAIN_UUID>`, `<SERIAL>` and
`<XFS_UUID>` stand for values from your own system. PCI addresses shown in the
docs are the author's and are specific to one machine: never copy them.

## License

This repository is licensed under the GNU General Public License v3.0. See
[LICENSE](LICENSE).

**No warranty.** As the license states, the scripts and instructions are
provided "as is", without warranty of any kind. Several steps destroy data, and
passing a controller away from DSM can take a NAS's own volumes offline if you
get it wrong. You run all of it at your own risk, on your own hardware, with
your own backups.

**Not affiliated.** This project is not affiliated with, endorsed by or
supported by Synology Inc. or Western Digital Corporation. Synology, DSM,
Virtual Machine Manager and Hyper Backup are trademarks of Synology Inc.;
Western Digital and Ultrastar are trademarks of Western Digital Corporation or
its affiliates. Other names are trademarks of their respective owners.
