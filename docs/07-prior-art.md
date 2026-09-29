# 07 — Prior art

This page lists what already exists on the topics this repository covers,
where it came from, and what this repository adds on top of it. It is grouped
into:

1. [The same approach](#1-the-same-approach)
2. [Overlapping work](#2-overlapping-work): projects and reports that share
   one part of this setup
3. [Published advice against this design](#3-published-advice-against-this-design),
   and how this repository answers it
4. [Background](#4-background): documentation, kernel work and vendor
   positions this repository relies on or departs from
5. [What this repository adds](#5-what-this-repository-adds)

> [!NOTE]
> **How this list was made.** Web and repository searches were run on
> 2026-09-26 in three independent passes. The searches are listed at the end
> of this page. Summaries and quotes were collected during that research and
> were not all re-read by the author afterwards: **the link is the authority,
> not the summary.** Several sources could not be read at all (Reddit, the
> Xpenology forum, Zhihu, the fnOS forum, Baidu Tieba, lore.kernel.org). There
> may be relevant reports there that this page does not know about.

> [!IMPORTANT]
> Nothing on this page changes what was tested. This repository describes one
> setup: a **DS3622xs+** with a **DX1222** expansion unit and three
> **WD Ultrastar DC HC680** drives, behind a controller DSM does not use for
> its own disks, alone in its own IOMMU group. It will not work where the zoned
> drives would share the controller DSM runs from, for example a **DS1821+ in
> this layout**. See [01 — Requirements and risks](01-requirements-and-risks.md).

## Summary

- **No public source was found that describes this whole setup**: a Synology
  passing a whole disk controller to a Virtual Machine Manager (VMM) guest,
  with dm-zoned under md RAID5, LUKS2 and XFS on host-managed SMR drives.
- The only source close to it is the author's own earlier project `zonedpool`
  (same NAS, same passthrough, different storage stack). The author has
  withdrawn it ([1](#1-the-same-approach)).
- Third-party work covers single parts:
  - **dm-zoned under a normal filesystem** on one host-managed drive (Mitsea,
    catwhiteangel).
  - **Passing the whole SATA controller**, not the disk, to a guest so that a
    host-managed drive works, under Proxmox VE (a PTT post).
  - **Hot-plugging PCIe devices into Synology VMM guests** with `vfio-pci` and
    `virsh attach-device` (a Coral TPU, a NIC, GPUs). None of them passes a
    storage controller.
  - **A Synology Hyper Backup target on a host-managed drive**, served from a
    separate Debian box (白のblog).
- **Nobody was found running md RAID on top of dm-zoned.** The only published
  opinions on it are negative: Western Digital's zoned storage documentation
  does not recommend dm-zoned, and a widely read Level1Techs guide calls an md
  array on such a layer "folly right now"
  ([3](#3-published-advice-against-this-design)).
- **Two of the author's findings have independent support**: zoned btrfs
  failing with `-11` / `-EAGAIN` and going read-only on current kernels
  (reported on HC620 drives, which have a 128-zone limit like the HC680), and
  `--assume-clean` being unsafe for RAID5.
- **The DS1821+ counter-example has no public source.** No public `lspci` or
  IOMMU dump of a DS1821+ was found. The statement rests on the author's
  knowledge of that model.

---

## 1. The same approach

### The author's earlier project `zonedpool`

- **Where:** formerly a public GitHub repository named `zonedpool` on the
  author's account. The author withdrew it in September 2026, so it is not
  linked here. Its lessons are in
  [06, section 3](06-alternatives-and-lessons.md#3-zoned-btrfs--mergerfs--snapraid-abandoned).
- **Date:** version 0.3.0 was released on 2026-09-22.
- **Relevance:** same NAS, same controller passthrough.

It ran the same three HC680s on the same DS3622xs+, in a VMM guest with the
Marvell 88SE9235 passed through. Version 0.3.0 added a Synology section and a
generic attach script with a list of PCI addresses it refused to touch, which
is the ancestor of this repository's watcher. The storage stack was different:
one zoned btrfs per drive, joined with mergerfs (FUSE passthrough) and
protected with SnapRAID, plus OpenMediaVault 8 patches. That stack **lost data
silently** in production and was abandoned on 2026-09-24. The failure and the
lessons are in [06, section 3](06-alternatives-and-lessons.md#3-zoned-btrfs--mergerfs--snapraid-abandoned).
Treat that project as history, not as a current reference.

The author also has a separate public repository,
`synology-ds3622xs-unsupported-drives`, on the same GitHub account. It is about
non-Synology HDDs and an NVMe cache on the same DS3622xs+, not about
host-managed drives.

---

## 2. Overlapping work

### 2.1 Passing PCIe devices to Synology VMM guests

These projects use the same basic mechanism as this repository's watcher:
unbind the device from its DSM driver, bind it to `vfio-pci`, then
`virsh attach-device` it into a running VMM guest. **None of them passes a
disk controller.** They pass add-in devices DSM does not need.

#### sramshaw/pci_coral_on_synology

- **Link:** <https://github.com/sramshaw/pci_coral_on_synology>
- **Date:** created 2024-09-17, last push 2024-09-23

The best-documented case on genuine Synology hardware: a DS1621+ (AMD Ryzen
V1500B) on DSM 7.2.1-69057 Update 4. `virt-host-validate` passes the IOMMU
device-assignment checks, and VMM already loads `vfio_pci`. An M.2 Coral TPU
and an Intel 82599ES 10G NIC are bound to `vfio-pci` and hot-plugged with
`virsh attach-device` from a detached script started by a libvirt `qemu` hook,
because running `virsh` inside the hook deadlocks. It notes that files in
`/etc/libvirt` do not survive a reboot while `/usr/local` does, and injects the
hook through a VMM package script. This is the earliest public evidence found
that live hot-plug through VMM's libvirt works. It shows that the V1500B
platform (the DS1621+/DS1821+ family) exposes IOMMU groups to DSM. It says
nothing about the controllers behind DSM's bays or its expansion port.

#### swaan/Synology-PCI-Passthrough-Script

- **Link:** <https://github.com/swaan/Synology-PCI-Passthrough-Script>
- **Date:** created 2025-03-19, last push 2026-06-02

A boot-time script run from DSM's Task Scheduler. It waits for the VFIO
modules, binds a vendor:device ID to `vfio-pci`, waits until the VM is
running, then runs `virsh attach-device`. Its README calls attaching to a
running VM "the next best option" because the VM definition could not be
changed. This is the same live-attach-after-start pattern as this
repository's watcher, used for a GPU in the PCIe slot. It names no tested
Synology model and has no protection against picking a controller DSM needs.
Note that it binds by vendor:device ID, which this repository forbids for
storage controllers ([01, section 5](01-requirements-and-risks.md#5-check-your-nas-before-you-build-anything-read-only)).

#### jcchen7566/SynoPassthru

- **Link:** <https://github.com/jcchen7566/SynoPassthru>
- **Date:** created 2025-04-01, last push 2025-12-02

Generalises the hook approach to any PCI device (GPUs including an AMD iGPU
with a vBIOS, USB controllers, audio). Its README states that VMM "does not
allow users to edit the config file manually" and that `virsh attach-device`
has to be redone after every VM restart, which matches this repository's
finding. It requires the device to be alone in its IOMMU group. The examples
come from AMD desktop platforms, so they probably describe DSM on
non-Synology hardware. No storage controllers, no tested models.

#### Jimi's blog: VMM iGPU passthrough on an SA6400 (Xpenology)

- **Link:** <https://jimizhou.com/zh/diskstation-vmm-gpu-passthrough>
- **Date:** 2025-01-06

A UHD P630 iGPU unbound from `i915`, bound to `vfio-pci` and added to a
running VMM guest with `virsh attach-device`, on DSM (SA6400 image, RR loader)
running on a Xeon W-1290P. Same mechanism, but not on Synology hardware and
not for storage.

#### Synology: VMM technical specifications and release notes

- **Links:** <https://www.synology.com/en-global/dsm/7.4/software_spec/vmm>,
  <https://www.synology.com/en-global/releaseNote/Virtualization>
- **Date:** read 2026-09-26; newest release 2.8.0-13004, 2026-06-16

Officially, VMM offers USB passthrough (not on Virtual DSM) and SR-IOV on
specific Synology network cards (added in VMM 2.6.1, 2022-09-05). Virtual disk
controllers are IDE, SATA and VirtIO. General PCIe passthrough, GPU
passthrough and storage-controller passthrough are not mentioned in the
specifications or in any release. **Whole-controller passthrough through
`virsh` is outside what Synology supports.**

#### Synology: DX1222 and DX517 product pages

- **Links:** <https://www.synology.com/en-global/products/DX1222>,
  <https://www.synology.com/en-global/products/DX517>
- **Date:** read 2026-09-26

The DX1222's listed host models are the DS3622xs+ and the DS2422+; it connects
through a MiniSAS-HD expansion port. The DX517 lists the DS1821+ among its host
models and connects over eSATA. The pages do not say which controller serves
the expansion port or the internal bays. **The DS2422+ with a DX1222 is
untested here.** Whether a DS1821+'s expansion port sits on a controller of
its own could not be confirmed from public sources; the author's statement is
that in this layout the zoned drives would share the controller DSM runs from.

### 2.2 Host-managed drives inside a VM, or next to a vendor NAS OS

#### PTT Storage_Zone: HC620 with fnOS, and Proxmox VE controller passthrough

- **Link:** <https://www.ptt.cc/bbs/Storage_Zone/M.1781014356.A.5F3.html>
- **Date:** 2026-06-09 (edited up to 2026-06-14)

Cheap HC620s on J3160/J4125 boards running fnOS. The drive could not be used
through adapter cards or USB enclosures. **Under Proxmox VE, passing the whole
SATA controller to the fnOS guest worked, while passing only the disk
failed.** OpenMediaVault also recognised the drive. Synology, RAID and ZFS are
listed as not working. This is the only third-party report found where a
hypervisor had to pass the controller, not the disk. It matches
[01, section 3](01-requirements-and-risks.md#3-why-dsm-cannot-use-these-drives-itself),
but it is not Synology VMM.

#### SMZDM: an HC620 on a QNAP through dm-zoned in a container or VM

- **Link:** <https://post.smzdm.com/p/awm4nxd4/>
- **Date:** 2026-01-23

A QNAP owner proposes running dm-zoned in Container Station or a QNAP VM, so
that the HC620 becomes an ordinary block device with ext4 on it, as an archive
disk outside QNAP's storage pools. **A proposal only**: no commands, no
benchmarks, no confirmation that it was built, no controller passthrough and
no RAID. The closest idea found to "vendor NAS plus Linux guest plus
dm-zoned".

#### 白のblog: an HC620 on Debian as a Synology Hyper Backup target

- **Link:** <https://blog.mashiro.pro/2650.html>
- **Date:** 2026-05-04 (updated 2026-08-31)

One HC620 on Debian 13 with `mkfs.btrfs -O zoned`, mounted with
`noatime,compress=zstd:3`, exported over Samba and as an **rsync server target
for Synology Hyper Backup**. Reported speeds: rsync 30–60 MB/s, SMB about
111 MB/s on gigabit and about 150 MB/s on 2.5 GbE. dm-zoned is mentioned as an
alternative but not used. It shares this repository's "Hyper Backup to an
rsync module on a zoned-drive Linux system" idea
([04](04-openmediavault-and-synology-integration.md)), but the drive sits in a
separate Debian box, not in a guest on the Synology, and there is no RAID.

### 2.3 dm-zoned under a normal filesystem

#### Mitsea Blog: HC620 HM-SMR hands-on (dm-zoned + ext4)

- **Link:** <https://blog.mitsea.com/33c779ab646880199b07f46af06b1d1f/>
- **Date:** 2026-04-08

One 14 TB HC620 on a Celeron J1900 running an Ubuntu 26.04 development
release with kernel 7.0.0-12. Zoned btrfs aborted a transaction under
sustained writes (`error while writing out transaction: -11`) and went
read-only, with a UDMA CRC count of 0. The author switched to dm-zoned + ext4
(`/dev/mapper/dmz-<serial>`, activated at boot) and saw 5 hours of continuous
writes without errors, giving up copy-on-write and snapshots. Single drive, no
RAID, no VM. This is the closest third-party use of dm-zoned under a normal
filesystem, and it left zoned btrfs for the same reason this repository's
author did.

#### catwhiteangel: HC620 on a Raspberry Pi 5, dm-zoned vs btrfs vs f2fs vs zonefs

- **Link:** <https://www.catwhiteangel.com/hc620-hm-smr-raspberry-pi-5/>
- **Date:** 2026-07-16

A Pi 5 with an ASM1061/1062 SATA HAT, Ubuntu 26.04 kernel
`7.0.0-1009-raspi`. dm-zoned + ext4: 98 MB/s sequential write, 148 MB/s
read, 4K random write 1.9 MB/s (about 456 IOPS) with second-long tail
latencies. Zoned btrfs: 104/154 MB/s, 4K random write 7.4 MB/s. f2fs in
`mode=lfs`: 242/244 MB/s. The author notes reclaim pressure once dm-zoned's
conventional-zone buffer (131 GiB on the 14 TB drive) fills, which matches the
buffer behaviour in [05, section 1.2](05-operations-monitoring-performance.md#12-the-dm-zoned-write-buffer).
Single drive, no RAID. These are the only third-party dm-zoned throughput
numbers found.

### 2.4 Host-managed drives in home setups (zoned btrfs, mostly single drives)

#### Jade.WTF: Notes on Zoned Storage / Host-Managed SMR

- **Link:** <https://jade.wtf/tech-notes/zoned-storage-notes/>
- **Date:** 2026-01-26 (the page says it is updated as data changes)

Uses the **same drive model** (WD HC680, `WSH722870ALE604`) plus a Seagate
Exos X26z, on Fedora IoT and Debian 13 with single-device zoned btrfs. Its
controller table lists an Asustor AS6602T's onboard SATA (running Fedora or
Debian, not the vendor OS as far as stated) and an LSI SAS3416 as working, and
an ASM1164 (in an Asustor AS6704T) and a Terramaster D8 Hybrid as not working,
without reasons. f2fs was rejected because of its 16 TB volume limit. No RAID,
no dm-zoned, no Synology, and no Marvell 88SE9235 or port multipliers.
Third-party evidence that the controller decides whether a host-managed drive
works at all.

#### Level1Techs: user report on a RockPro64 (thread page 2)

- **Link:** <https://forum.level1techs.com/t/host-managed-zoned-storage-in-2025-quick-intro-wip/232608?page=2>
- **Date:** 2025-12-18

The one hands-on home deployment in that thread: zoned btrfs per drive, with
MinIO providing redundancy across drives because zoned btrfs RAID1 is
experimental. An ASMedia SATA card failed and a Marvell-based card worked.
About 20 MB/s as an offsite backup. The same page mentions SaunaFS erasure
coding over host-managed drives (2025-07-21). The guide on page 1 is in
[section 3](#3-published-advice-against-this-design).

#### 白のblog: btrfs RAID1 on two HC620s

- **Link:** <https://blog.mashiro.pro/4503.html>
- **Date:** 2026-08-29

`mkfs.btrfs -O zoned -d raid1 -m raid1` on two HC620s under Debian 13. It needs
the experimental raid-stripe-tree: a custom kernel with `CONFIG_BTRFS_DEBUG`
and btrfs-progs built with `--enable-experimental`. The author warns against
it for important data. Shows that redundancy across host-managed drives
without dm-zoned is still experimental, and covers RAID1 only.

#### knightli: two zoned-btrfs failures on an HC620

- **Link:** <https://knightli.com/2026/07/24/hc620-btrfs-zoned-deadlock-readonly-troubleshooting/>
- **Date:** 2026-07-24

HC620, zoned btrfs, Ubuntu 26.04, kernel 7.0.0-28. After deleting and copying
about 3 TB, `btrfs-cleaner` hung for more than 368 s under
`btrfs_zone_finish_one_bg` and the filesystem could not be unmounted. Later
came `error while writing out transaction: -11` and a forced read-only mount,
with device error counters at zero. Suggested workarounds: write in batches of
200–500 GiB, avoid balance and `check --repair`, try other kernels. The same
failure signature as the author's `zonedpool` postmortem.

#### Rockstor forum: HM-SMR support

- **Link:** <https://forum.rockstor.com/t/does-rockstor-support-hm-smr-drives/10734>
- **Date:** 2025-10-17 to 2025-10-30

An HC620 with zoned btrfs failed on openSUSE Leap 15.6, whose btrfs-progs
6.5.1 has no zoned support. It worked after moving to Slowroll (btrfs-progs
6.14), and the Rockstor web UI imported the pool. Single drive, no parity.

#### fnOS (飞牛) community threads (unverified)

- **Link:** <https://club.fnnas.com/forum.php?mod=viewthread&tid=49118>
  (also a thread on HC620 "BTRFS forced readonly", `tid=63785`)
- **Date:** not verified

The forum refused connections on 2026-09-26, so only search-result snippets
were seen. According to them, fnOS formats HC620s as single-disk zoned btrfs
(`mkfs.btrfs -O zoned -m single -d single`) and recommends single-disk zoned
btrfs or f2fs over experimental RAID. They suggest a large HC620 home-NAS user
base in China, all on single drives. **Treat as unverified.**

#### Chia Network: Using SMR drives for Chia farming

- **Link:** <https://www.chia.net/2022/02/22/zoned-storage-using-smr-drives-for-chia-farming/>
- **Date:** 2022-02-22

Two WD HC650 20 TB drives with single-drive zoned btrfs
(`mkfs.btrfs -O zoned -d single -m single`), filled once at about 190 MB/s in
29 hours and then used read-only. No RAID, no dm-zoned. An early documented
small-scale use of host-managed drives, and the reason dm-zoned had a wave of
users around 2021–2022 (see Le Moal in [section 3](#3-published-advice-against-this-design)).

---

## 3. Published advice against this design

This repository runs md RAID5 on dm-zoned. The published advice found says
not to. The sources, and how this repository answers them:

#### zonedstorage.io (Western Digital): dm-zoned

- **Link:** <https://zonedstorage.io/docs/device-mapper/dm-zoned>
- **Date:** undated, read 2026-09-26

"The use of the dm-zoned target is not recommended due to its unpredictable
performance characteristics." The page recommends filesystems with native
zoned support (XFS, btrfs) instead. It describes the conventional-zone buffer
and reclaim, multi-device dm-zoned (Linux 5.8 and later) and ext4 on
dm-zoned. It says nothing about md or dm-raid on top of dm-zoned, and no
Western Digital document describing dm-zoned with RAID was found.

#### LKML: Damien Le Moal on dm-zoned vs zoned btrfs

- **Link:** <https://lkml.iu.edu/2209.2/06241.html>
- **Date:** 2022-09-21

The zoned storage maintainer notes that dm-zoned "seemed to be used a lot",
notably by Chia users, and says he recommends btrfs "over dm-zoned+ext4 or
dm-zoned+xfs as performance is much better for write intensive workloads".
Context for why dm-zoned has few recent users and few recent reports.

#### Level1Techs: Host-Managed Zoned Storage in 2025 — Quick Intro [WIP] (Wendell)

- **Link:** <https://forum.level1techs.com/t/host-managed-zoned-storage-in-2025-quick-intro-wip/232608>
- **Date:** 2025-06-27

An introduction to Seagate Exos host-managed drives with single-drive zoned
btrfs (4K random fio about 275 IOPS). It mentions dm-zoned and zonefs, and
says the shim layers that let Linux md and LVM work are, "in practice", "still
unstable in 2025", and that "building an MD or other array on top of this is
imho folly right now". It suggests btrfs RAID1 "might be okay". No logs,
kernel versions or dm-zoned measurements are given. It is the only explicit
public opinion found on md over dm-zoned.

**How this repository answers these:**

- **"Unpredictable performance" is confirmed here, not disputed.** Write
  throughput depends on how full the dm-zoned buffer is (116–143 MB/s while it
  fills, 38–69 MB/s once it is full) and, far more, on the guest kernel
  (24.6 MiB/s on Debian's 6.12, 165.4 MiB/s on Ubuntu mainline 7.2.6, same
  stack). See [05](05-operations-monitoring-performance.md).
- **"Unstable" is bounded, not refuted.** On kernel 7.2.6 the stack held more
  than an hour of full saturation (a Hyper Backup seed, a 3 TB rsync and an md
  repair at once) with no hang and no errors. But a dm-zoned reclaim worker got
  stuck twice, both times right after the array was reassembled following a
  power event on the NAS. The repository's answer is monitoring that tells a
  hang from busy reclaim, automatic evidence capture and a reboot, not a claim
  that the problem is gone ([05, section 1.5](05-operations-monitoring-performance.md#15-reclaim-workers-in-d-state-busy-is-not-hung)).
- **The recommended alternative failed here.** Zoned btrfs is what the
  sources above recommend. On these drives it lost data silently
  ([06, section 3](06-alternatives-and-lessons.md#3-zoned-btrfs--mergerfs--snapraid-abandoned)),
  and the third-party reports in [4.2](#42-zoned-btrfs-failures-on-current-kernels)
  show the same failure signature on other systems.
- **The track record is short.** The current stack was first built on
  2026-09-24 and rebuilt with LUKS2 on 2026-09-26. That is days of operation
  on one system, not years on many.

---

## 4. Background

### 4.1 Vendor NAS systems and host-managed drives

These show why a vendor NAS OS, or a mainstream NAS distribution, is not an
option on its own.

- **SynoForum: "Panic around the hard drive … Part No. 2"** —
  <https://www.synoforum.com/threads/panic-around-the-hard-drive-or-just-well-thought-out-marketing-from-for-whom-part-no-2.2688/page-2>,
  2022-03-07. Community posters state that DSM supports drive-managed SMR only,
  so "running BTRFS on HM-SMR drive/s in Syno NASes is out of possible
  operation". The kernel reason (no `CONFIG_BLK_DEV_ZONED` in any DSM kernel)
  is not given there; it comes from the author's check of Synology's toolkit
  kernel configs ([01, section 3](01-requirements-and-risks.md#3-why-dsm-cannot-use-these-drives-itself)).
- **Unraid forums** — <https://forums.unraid.net/topic/119917-support-for-zoned-storage-devices/>
  (2022-02-11), <https://forums.unraid.net/topic/136443-host-managed-smr/>
  (2023-03-15, 2025-04-14),
  <https://forums.unraid.net/topic/180919-host-managed-smr-wd-dc-hc650-sata-6gbs-20tb-drives-and-unraid/>
  (2024-11-28), <https://forums.unraid.net/topic/196550-support-for-hm-smr-zoned-disks-in-pools/>
  (2026-01-16, moderator reply 2026-02-23). Moderators state that Unraid does
  not support host-managed drives, that support would take "a considerable
  amount of effort … for very few users", that HC650s "won't work, they need
  OS support", and that Unraid requires a partition while host-managed drives
  need the filesystem on the whole disk. No workaround is discussed.
- **TrueNAS** — <https://www.truenas.com/community/threads/smr-host-managed-hard-drive-questions.77601/>
  (2019-07-10: "OpenZFS is definitely not SMR-aware at present"; advice was to
  return the drives) and <https://forums.truenas.com/t/the-future-of-smr-drives-in-truenas-zfs/13451>
  (2024-09-17: "HM (Host Managed) SMR has no dumb mode"; 256 MB zones do not fit
  ZFS allocation).
- **ZimaOS issue #400** — <https://github.com/IceWhaleTech/ZimaOS/issues/400>,
  2026-01-19. A request to enable `CONFIG_BLK_DEV_ZONED` and zoned btrfs,
  which ZimaOS lacks. Open, with no maintainer response recorded. Its claim
  that TrueNAS SCALE and Unraid support zoned storage is contradicted by the
  threads above.
- **Margrop Blog: "Do Not Buy the Btrfs Drive Blind"** —
  <https://blog.margrop.net/en/post/smr-cmr-btrfs-disk-trap/>, 2026-07-09. A
  buyer warning about cheap host-managed drives such as the HC650 sold as
  "btrfs drives": classic RAID stacks, Docker and normal NAS workloads do not
  fit them. A fair summary of who should not attempt this repository either.
- **Buyer experiences** — Geekzone, <https://www.geekzone.co.nz/forums.asp?forumid=77&topicid=318259>
  (2024-12-31: two recertified Exos X18z bought by mistake, visible in the BIOS
  but not in Unraid or Windows, sold again); ServeTheHome,
  <https://forums.servethehome.com/index.php?threads/is-it-possible-to-make-host-managed-smr-work-on-a-standard-desktop-pc.42635/>
  and <https://forums.servethehome.com/index.php?threads/host-managed-smr-compatible-hba.42608/>
  (2023-12 to 2025-05: an HBA without host-managed support, btrfs formatting
  failing with a `BLKREPORTZONE` error, fixed with a newer SAS card and Ubuntu
  23.10); Hacker News, <https://news.ycombinator.com/item?id=26898820>
  (2021-04: host-managed drives were then an enterprise-only product).
- **StorageReview: Seagate Exos X26z review** —
  <https://www.storagereview.com/review/seagate-exos-x26z-review-25tb-host-managed-smr-hdd>,
  2023-12-01. Zoned btrfs on Ubuntu 23.04, about 270 MB/s sequential. The drive
  was invisible behind their SAS HBAs and expanders and only worked on
  motherboard SATA. It advises home users to avoid the drive class.

### 4.2 Zoned btrfs failures on current kernels

Independent support for the failures that ended the author's `zonedpool`
design ([06, section 3](06-alternatives-and-lessons.md#3-zoned-btrfs--mergerfs--snapraid-abandoned)).
None of this affects dm-zoned, which exposes a non-zoned device to the layers
above it.

- **linux-btrfs bug report: `btrfs_commit_transaction` error -11 on a zoned
  device** — <https://ratatoskr.run/linux-btrfs/2026/02/7625096/t>,
  2026-02-08. Writing several TB to a zoned btrfs aborts the transaction with
  -11 and forces the filesystem read-only. Reproduced on 6.18.7 and 6.19-rc8;
  the reporter found 6.16 works and 6.17 and later fail. No fix in the thread.
- **linux-btrfs: "btrfs: zoned: fix active-zone accounting" (Dongjiang Zhu),
  v1 to v3** — <https://ratatoskr.run/linux-btrfs/2026/08/17472778/t> (v3),
  <https://ratatoskr.run/linux-btrfs/2026/08/17451585/t> (v1), 2026-08-24 to
  2026-08-28. After HC620 systems (`max_active_zones` 128) moved to Linux 6.18,
  users saw writeback failing with `-EAGAIN` and forcing the filesystem
  read-only, balance deadlocks and hung tasks. The series fixes active-zone
  accounting. At v3 it was still under review, not merged. The HC680s here
  report `max_open_zones` 128.
- **linux-btrfs: "[RFC 00/15] btrfs: RAID5 with RAID stripe-tree" (Johannes
  Thumshirn)** — <https://ratatoskr.run/linux-btrfs/2026/06/17154227/t>,
  2026-06-19. RAID5 on raid-stripe-tree, aimed mainly at zoned devices.
  Experimental: no RAID6, partial-stripe handling not fully verified. As of
  2026 there is no mainstream native parity RAID for host-managed drives, which
  is why this repository puts md RAID5 on dm-zoned.
- **btrfs documentation: Zoned mode** —
  <https://btrfs.readthedocs.io/en/latest/Zoned-mode.html>, read 2026-09-26.
  Zoned mode since btrfs 5.12; "only single (data, metadata) and DUP
  (metadata) profile is supported". The page may lag behind the experimental
  raid-stripe-tree work.

### 4.3 dm-zoned itself

- **Linux kernel admin guide: dm-zoned** —
  <https://docs.kernel.org/admin-guide/device-mapper/dm-zoned.html>. How
  dm-zoned works: the first superblock occupies the first block of the first
  conventional zone; mapping tables and block-validity bitmaps are stored in
  two metadata-zone sets. Unaligned writes are staged in conventional "buffer"
  zones, and reclaim copies buffered blocks into free sequential zones. Nothing
  about RAID or stacking.
- **`drivers/md/dm-zoned-reclaim.c`** —
  <https://github.com/torvalds/linux/blob/master/drivers/md/dm-zoned-reclaim.c>,
  master as read on 2026-09-26. The code treats the target as idle after 10 s
  without a BIO (`DMZ_IDLE_PERIOD`). For this single-device setup, `p_unmap` is
  the integer percentage of free random zones (zero when at most one remains).
  While busy, reclaim runs only at `p_unmap <= DMZ_RECLAIM_LOW_UNMAP_ZONES`
  (30 %). Above 30 % a busy target does not reclaim; the explicit early exit at
  `p_unmap >= DMZ_RECLAIM_HIGH_UNMAP_ZONES` (50 %) is also covered by that rule.
  Reclaim runs unthrottled when idle **or when `p_unmap < 15`, even with
  foreground activity** (half of the 30 % low threshold). While busy with
  `p_unmap` from 15 through 30, the copy throttle is `min(75, 100 - p_unmap/2)` %,
  which evaluates to 75 % throughout that range. Reclaim activity does
  not necessarily mean the buffer shrinks: concurrent writes may consume space
  faster than reclaim frees it. The observed net buffer drain is described in
  ([05, section 1.2](05-operations-monitoring-performance.md#12-the-dm-zoned-write-buffer)).
  Whether the thresholds match the stress test in detail was **not checked**:
  there, reclaim was already copying under load with the buffer less than half
  full. The inference that md resync or repair I/O keeps dm-zoned from ever
  counting as idle is untested.
- **LWN: original dm-zoned posting** — <https://lwn.net/Articles/714387/>,
  2017-02-09. The target exposes 4096-byte logical sectors regardless of the
  drive's sector size, buffers random writes in conventional zones and reclaims
  in the background. Stated users: filesystems without zoned support and
  raw-block applications. RAID is not discussed.
- **dm-zoned-tools (`dmzadm`)** —
  <https://github.com/westerndigitalcorporation/dm-zoned-tools>, created
  2016-11-30, last push 2024-05-30. The `dmzadm --format` used in
  [03](03-guest-storage-stack.md). Debian packages it as `dm-zoned-tools`.
- **SNIA SDC: "High-performance SMR drives with dm-zoned Caching" (Hannes
  Reinecke)** — <https://www.snia.org/educational-library/high-performance-smr-drives-dm-zoned-caching-2020>,
  2020-09-23. Multi-device dm-zoned with a fast cache device to saturate SMR
  drives. This repository uses only the drives' own conventional zones as the
  buffer; a cache device was not tried.
- **Upstream status of dm-zoned, 2024–2026.** Recent changes are mostly
  cleanups. Related items:
  - "dm: Fix dm-zoned-reclaim zone write pointer alignment" (Damien Le Moal),
    <https://www.mail-archive.com/dm-devel@lists.linux.dev/msg05214.html>,
    2024-12-05: a reclaim regression caused by zone write plugging, fixed.
  - "block: fix handling of dead zone write plugs",
    <https://ratatoskr.run/linux-block/2026/05/9003225/t>, 2026-05-13.
  - A double free in `dmz_load_sb()` on the multi-device error path (reported
    by Dan Carpenter), <https://ratatoskr.run/dm-devel/2026/05/17064904/t>,
    2026-05-30; no fix visible in mainline on 2026-09-26. This repository uses
    one device per mapper and does not take that path.
  - A 2018 lockdep fix for a reclaim deadlock class with XFS on top (Bart Van
    Assche), <https://dm-devel.redhat.narkive.com/Vr08IKsb/patch-v2-dm-zoned-avoid-triggering-reclaim-from-inside-dmz-map>,
    2018-06-22. Historical; not linked to the incidents here.

  **No public report or fix was found for a dm-zoned reclaim worker stuck in D
  state**, which is what the author saw twice on 7.2.6.

### 4.4 md RAID5, LUKS2 and XFS on or above zoned devices

- **md RAID5 stripe unit** — <https://github.com/torvalds/linux/blob/master/drivers/md/raid5.h>.
  `DEFAULT_STRIPE_SIZE` is 4096, and on x86 (4 KiB pages) the stripe unit
  cannot be larger. Consistent with md handing dm-zoned 4 KiB writes on every
  kernel tested here.
- **Kernel admin guide: RAID arrays** — <https://docs.kernel.org/admin-guide/md.html>.
  Defines `stripe_cache_size` (default 256, maximum 32768), `sync_speed_min`,
  `repair` and `mismatch_cnt` as used in [03](03-guest-storage-stack.md) and
  [05](05-operations-monitoring-performance.md).
- **mdadm(8), `--assume-clean`** — <https://man7.org/linux/man-pages/man8/mdadm.8.html>.
  "Use this only if you really know what you are doing." The archived Linux
  RAID wiki, <https://archive.kernel.org/oldwiki/raid.wiki.kernel.org/index.php/Initial_Array_Creation.html>
  (last modified 2008-03-03), says that for RAID5 "it is NOT safe to skip the
  initial sync". Both support the pitfall in this repository: 752 parity
  mismatches after `--assume-clean` over fresh dm-zoned devices, so always run
  a full `repair` afterwards.
- **dm-crypt and LUKS on zoned devices** —
  <https://zonedstorage.io/docs/device-mapper/dm-crypt> (read 2026-09-26),
  <https://lwn.net/Articles/856556/> (2021-05-19),
  <https://gitlab.com/cryptsetup/cryptsetup/-/issues/877> (2024-04-02 to
  2024-06-06). dm-crypt handles zoned devices, but zonedstorage.io says only
  plain mode works and LUKS is not supported on them, because writing the LUKS
  header is not sequential; the cryptsetup issue describes a detached-header
  workaround. None of this applies here: LUKS2 sits on `md127`, which is not
  zoned.
- **Native zoned XFS** — <https://lwn.net/Articles/1001751/> (RFC,
  2024-12-11), <https://zonedstorage.io/docs/filesystems/xfs>, and a report
  that the zoned allocator left experimental status in Linux 7.2,
  <https://www.phoronix.com/news/XFS-Zone-Allocator-Linux-7.2> (via an
  aggregator dated 2026-06-16). XFS can run directly on a host-managed drive
  from Linux 6.15 with `CONFIG_XFS_RT` and xfsprogs 6.15. It works per device
  and gives no redundancy across drives, so it does not replace md RAID5
  across three drives. **Not tried by the author.**
- **Research designs** — HSMR-RAID (Lin and Chen, ACM SAC '23),
  <https://dl.acm.org/doi/10.1145/3555776.3577820>: a RAID-5 prototype for
  host-managed SMR arrays that reduces garbage-collection copying; the full
  text could not be read. RAIZN (Kim et al., ASPLOS '23),
  <https://www.pdl.cmu.edu/PDL-FTP/Storage/RAIZN-kim.pdf>: a zone-aware RAID
  device-mapper target for ZNS SSDs, not SMR drives. Neither is a deployable
  stack for these drives, and neither uses dm-zoned under md.

### 4.5 Kernel work related to the performance question

- **linux-block: "Improve zoned (SMR) HDD write throughput" (Damien Le Moal)** —
  <https://ratatoskr.run/linux-block/2026/02/6435389/t> (v4, applied
  2026-02-27); sysfs `zoned_qd1_writes`,
  <https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-block>. Writes to
  a rotational zoned device are issued from one per-disk thread at queue depth
  1 (the `sdX_zwplugs_worker` monitored in [05](05-operations-monitoring-performance.md)).
  The cover letter reports sequential writes on an SMR drive going from 112 to
  246 MB/s. The series is already in Linux 7.1, and `block/blk-zoned.c` is
  identical in 7.1.8 and 7.2, so **it cannot explain why 7.2.6 is faster than
  7.1.8 on this stack.** That cause is still unknown.

### 4.6 Controllers, passthrough and the 88SE9235

- **Linux: "PCI: Add function 1 DMA alias quirk for Marvell 88SE9235"
  (Robin Murphy)** — <https://lkml.rescloud.iu.edu/2306.0/08209.html>, applied
  for Linux 6.5 (<https://lkml.rescloud.iu.edu/2306.1/00977.html>, 2023-06-08);
  analysis <https://lkml.rescloud.iu.edu/2305.2/07165.html>; backported to
  5.15.121 (<https://cdn.kernel.org/pub/linux/kernel/v5.x/ChangeLog-5.15.121>).
  The 9235, like its 92xx siblings, can issue DMA with the requester ID of
  PCI function 1, "possibly only when certain ports are used", so it needs a
  DMA alias when an IOMMU translates its DMA. Upstream 4.4.302's quirk list
  covers other 92xx devices but not the 9235. **Whether Synology's 4.4.302
  kernel carries an equivalent is unknown.** This is an open lead about how
  the passed-through controller behaves under DSM's IOMMU, **not an
  explanation of the 2026-09-24 panic**, which happened in the driver of a
  different controller. Checking the NAS kernel log for DMAR faults right
  after an attach would test it; that has not been done.
- **Proxmox forum: drives not detected on a Marvell 88SE9230** —
  <https://forum.proxmox.com/threads/drives-are-not-detected-on-sata-card-with-marvell-88se9230-chipset.38102/>,
  2017-11 to 2025-04. With the IOMMU on, drives on a sibling chip were
  invisible and logged `failed to IDENTIFY (I/O error, err_mask=0x4)`. Not the
  same symptom as the harmless phantom-port `.05` messages in
  [02](02-synology-controller-passthrough.md), and not verified on this setup.
- **RROrg/rr issue #18569: drives behind an 88SM9705 not recognised by DSM** —
  <https://github.com/RROrg/rr/issues/18569>, 2025-10-04. An Xpenology user
  with 88SM9705 port multipliers claims Synology's kernel only allows port
  multipliers in its own expansion units. An unverified claim, relevant to
  the nested-DSM experiment in [06](06-alternatives-and-lessons.md).
- **zonedstorage.io: Getting started with SMR hard disks** —
  <https://zonedstorage.io/docs/getting-started/smr-disk>. "Most AHCI host
  adapters are known to work with Host Managed disk drives." SAS HBAs need
  explicit support. Nothing about port multipliers or virtualisation.
- **zonedstorage.io: QEMU and KVM** — <https://zonedstorage.io/docs/tools/qemu>.
  Host-managed disks can be given to guests per disk with virtio-scsi or
  vhost-scsi. The documentation distinguishes `scsi-block`, using a host block
  device, from `scsi-generic`, using `/dev/sgX`. DSM's missing block nodes
  prevent the former; the latter remains unverified on DSM/VMM. This guide
  validates whole-controller passthrough.
- **libvirt: PCI hotplug** — <https://libvirt.org/pci-hotplug.html>. A Q35
  guest can hot-plug a PCI Express device, assigned from the host or emulated;
  more devices need extra `pcie-root-port` controllers. Background for the Q35
  requirement in [02](02-synology-controller-passthrough.md).
- **007revad Synology_Information_Wiki: Linux kernel per platform** —
  <https://github.com/007revad/Synology_Information_Wiki/blob/main/pages/Linux-Kernel-in-each-platform-arch.md>,
  updated 2026-09-02. The DS3622xs+ (`broadwellnk`) and the DS1821+ (`v1000`)
  both run 4.4.302. So the DS1821+ limitation in this repository is about
  where the drives sit (which controller), not about the kernel version.

### 4.7 Tools not used here

- **playercatboy/badzones** — <https://github.com/playercatboy/badzones>,
  created 2026-01-13. Read-tests the zones of a host-managed drive to find bad
  sectors. A possible check before deployment. **Not tested by the author.**

---

## 5. What this repository adds

As far as the searches above could find, and with the gaps listed at the top
of this page:

1. **Passing a disk controller, not an add-in card, through Synology VMM.** The
   attach mechanism itself (`vfio-pci` plus `virsh attach-device` into a
   running guest) is known from the passthrough projects in
   [2.1](#21-passing-pcie-devices-to-synology-vmm-guests). What was not found
   elsewhere: using it for a storage controller, a watcher that picks the
   controller by the drive models behind it and refuses DSM's own controller,
   and a stated model requirement with a counter-example (the zoned drives must
   be on a controller DSM does not use, alone in its IOMMU group; not a
   DS1821+ in this layout). The author's own `zonedpool` did the same
   passthrough first ([1](#1-the-same-approach)).
2. **md RAID over dm-zoned on host-managed drives.** No public report of md
   RAID at any level on top of dm-zoned was found, let alone RAID5 with LUKS2
   and XFS above it, or a boot chain that brings it up late and unattended
   (including why the crypttab entry must be `noauto`).
3. **Measurements for that stack.** A guest-kernel comparison on the same
   pool, and the behaviour of the dm-zoned buffer under mixed load until and
   beyond saturation. The only third-party dm-zoned numbers found are for a
   single drive ([catwhiteangel](#catwhiteangel-hc620-on-a-raspberry-pi-5-dm-zoned-vs-btrfs-vs-f2fs-vs-zonefs)).
4. **Telling a hung dm-zoned reclaim worker from a busy one.** Monitoring and
   evidence capture based on D state plus completed drive commands. No
   equivalent, and no upstream report of the stuck worker, was found.
5. **DSM integration on the same box.** Hyper Backup to an rsync module, and
   an NFS v4 remote folder, served by a guest on the same NAS. A Hyper Backup
   target on a host-managed drive exists elsewhere, but on a separate machine
   ([白のblog](#白のblog-an-hc620-on-debian-as-a-synology-hyper-backup-target)).
6. **Negative results.** The zoned btrfs + mergerfs + SnapRAID postmortem, the
   nested-DSM measurements (the ACPI PM timer exit storm of stock DSM kernels
   and RR's custom kernel with kvm-clock on SA6400), and the lab results for
   md, bcache, dm-cache and dm-writecache directly on host-managed drives
   ([06](06-alternatives-and-lessons.md)). No comparable nested-DSM write-up
   was found, but the Xpenology forum could not be read.

What this repository does **not** add:

- Any new kernel code or storage layer. dm-zoned, md, LUKS2 and XFS are
  standard upstream components.
- Evidence that the design is safe in general. It goes against the published
  advice in [section 3](#3-published-advice-against-this-design), it has run
  for days on one system, and one NAS kernel panic remains unexplained
  ([01, section 7.1](01-requirements-and-risks.md#71-nas-kernel-panic-in-dsms-own-storage-driver)).
- Evidence for any hardware other than a DS3622xs+ with a DX1222 and three
  HC680s.

<details>
<summary>Searches run on 2026-09-26</summary>

Three research passes ran independently. Queries are listed as they were run.

**Pass 1 (web, plus GitHub, Codeberg and GitLab APIs)**

- dm-zoned mdadm RAID host-managed SMR home server
- host-managed SMR Synology passthrough VM zoned drives
- zonedstorage.io dm-zoned RAID dm-raid
- "dm-zoned" "mdadm" host-managed
- HC620 host-managed SMR home NAS btrfs zoned experience
- fnOS 飞牛 host-managed SMR 叠瓦 HC620 btrfs 支持
- Unraid host-managed SMR zoned btrfs HC620
- TrueNAS host-managed SMR zoned drive not supported HC620
- "HC680" host-managed SMR Linux
- "HC670" OR "HC650" host-managed SMR home server dm-zoned OR zonefs OR "btrfs zoned"
- Synology Virtual Machine Manager PCI passthrough virsh attach-device vfio-pci
- Synology DSM kernel CONFIG_BLK_DEV_ZONED host-managed SMR not supported
- Xpenology host-managed SMR zoned drive DSM
- "dm-zoned" raid5 OR "raid 5" OR "md raid" SMR drives blog
- "dm-zoned" xfs host managed smr 14TB setup guide
- openmediavault host-managed SMR zoned drive
- md raid zoned block devices support linux-raid mdadm member
- Btrfs RAID stripe tree zoned RAID5 host-managed SMR status 2026
- Proxmox host-managed SMR zoned drive passthrough VM dm-zoned
- reddit datahoarder HC620 host managed SMR Synology does not recognize
- "host managed" SMR "dm-zoned" "mdadm" reddit OR forum raid5 build
- "dm-zoned" LUKS OR cryptsetup XFS NAS zoned drives mdadm
- cryptsetup 2.7 zoned block device support luksFormat SMR release notes
- site:zonedstorage.io RAID zoned block devices md dm-raid
- "Exos X26z" OR "Exos X24z" OR "host-managed" btrfs homelab NAS experience 2026
- HC620 dm-zoned mdadm raid5 14TB 叠瓦 阵列
- dmzadm HC620 格式化 dm-zoned ext4 教程
- 飞牛 fnOS HC620 叠瓦盘 存储空间 RAID 不支持 单盘 btrfs zoned
- Synology NAS WD HC620 OR HC650 OR HC680 host-managed drive cannot initialize
- Synology VMM passthrough SATA controller HBA to VM expansion unit DX517 OR DX1222 OR eSATA virsh
- Marvell 88SE9235 vfio passthrough DMA alias quirk IOMMU
- forum.openmediavault.org host managed SMR zoned HC620
- dm-zoned Linux 6.x slow write 4k bios md raid dm-zoned reclaim hung task
- "dm zoned: Fix zone reclaim trigger" Damien Le Moal commit
- host-managed SMR snapraid mergerfs btrfs zoned HC620 array
- "HC620" "dm-zoned" english blog OR github OR reddit
- Virtual DSM OR xpenology VM dm-zoned OR zoned SMR drives virtio-scsi
- "dm-zoned" "raid" SMR experience blog 2024-2026 home
- RR loader SA6400 custom kernel kvm-clock xpenology VM slow boot acpi_pm
- Synology VMM pass through SATA controller to VM reddit OpenMediaVault TrueNAS virsh
- GitHub API repository search: dm-zoned, host-managed smr, hm-smr, zoned hdd,
  smr zoned nas, zoned storage nas, HC620, HC650 (zonefs and btrfs zoned hit the
  API rate limit)
- Codeberg API repository search: zoned, smr, dm-zoned, host-managed, shingled,
  zonefs (no relevant hits)
- GitLab API project search: smr, dm-zoned, zoned-storage, host-managed,
  shingled, zonefs (no relevant hits)
- Direct reads: the Level1Techs thread (pages 1 and 2); zonedstorage.io
  dm-zoned, XFS, FAQ and Linux ecosystem pages; the kernel dm-zoned
  documentation; upstream `dm-zoned-reclaim.c`; the LKML, linux-btrfs,
  linux-block and dm-devel threads cited above; the Synology VMM specification
  page; GitHub metadata for the passthrough repositories and the author's
  repositories

**Pass 2 (web search, DuckDuckGo, direct fetches)**

- host managed SMR HC620 dm-zoned home NAS
- reddit datahoarder host managed SMR drives cheap HC620 what can I do
- Reddit-restricted searches (three: HM-SMR HC620, dm-zoned, synology): refused,
  Reddit not accessible; an old.reddit.com search fetch was also refused
- DuckDuckGo: site:reddit.com "host managed" SMR HC620/HC650/HC670/HC680
  (titles and snippets only; pages not readable, so no Reddit items are listed)
- DuckDuckGo: reddit HC620 14TB cheap host managed linux works; reddit "HC680"
  host managed
- DuckDuckGo: HC620 群晖 dm-zoned; HC620 群晖 虚拟机 直通 SATA控制器; HC620
  dm-zoned raid5 mdadm 组阵列; HC620 dm-zoned 性能 reclaim; HC620 PVE 直通 dm-zoned
- DuckDuckGo: 群晖 VMM 直通 PCIe virsh attach-device vfio; synology VMM
  "attach-device" SATA controller passthrough; xpenology "host managed" SMR
  (DuckDuckGo then began rate-limiting)
- "host managed" SMR synology
- "dm-zoned" mdadm raid5 host-managed
- "HC680" host managed SMR home use linux
- servethehome forums host managed SMR drives dm-zoned
- synology VMM PCI passthrough vfio-pci virsh attach-device hostdev
- Synology VMM pass through SATA controller HBA to virtual machine vfio
- xpenology forum host managed SMR zoned drive
- "dm-zoned" raid mdadm experience forum SMR drives array
- "host managed" SMR "HC650" OR "HC670" btrfs zoned homelab experience
- hacker news host-managed SMR drives cheap home dm-zoned
- forum.openmediavault.org host managed SMR zoned
- forum.proxmox.com host managed SMR zoned drive dm-zoned
- servethehome forums "host managed" HC620 recertified deal zoned btrfs
- linux-raid mailing list dm-zoned md raid5 zoned block device
- "dmzadm" format raid OR mdadm OR "raid5" blog
- dm-zoned reclaim hung task dmz_reclaim kernel bug
- synology expansion unit DX517 OR DX1222 passthrough virtual machine controller vfio
- Synology DSM "virsh attach-device" GPU passthrough VMM blog
- Synology DSM "iommu_groups" VMM passthrough DS3622xs+ OR DS1621+ OR DS1821+
- xpenology "virsh" "attach-device" synology VMM pci passthrough
- "r/synology" PCIe passthrough VMM virsh vfio-pci
- Synology VMM passthrough M.2 NVMe OR HBA OR SATA card to VM virsh hostdev
- "zoned" OR "host-managed" "Virtual Machine Manager" synology drives VM raw disk
- "88SE9235" vfio passthrough
- Marvell 88SE92xx vfio passthrough "failed to IDENTIFY" port multiplier guest
- quirk_dma_func1_alias Marvell 9235 IOMMU DMA alias function 1
- "217218" Marvell 88SE9235 regression 6.2 IOMMU
- "88SE9235" "DMA alias" quirk patch 2023 Robin Murphy stable
- Direct fetches: the 5.15.121 changelog (searched for 88SE9235); upstream
  v4.4.302 `drivers/pci/quirks.c` (9235 absent)
- xpenology forum HM-SMR "host managed" DSM kernel CONFIG_BLK_DEV_ZONED
- HC620 群晖 叠瓦 host managed
- "dm-zoned" HC620
- fnOS host-managed SMR HC620 support btrfs zoned 飞牛
- "在 NAS 使用 HC620 的正确姿势"
- HC620 叠瓦 btrfs 只读 transaction -11 飞牛 报错
- knightli HC620 SMR f2fs freeze io wait
- HC620 群晖 虚拟机 直通 VMM
- HC620 dm-zoned mdadm 阵列 raid5
- "HC680" "host managed" forum recertified 26TB cheap warning
- "WSH722" OR "HC680" SMR serverpartdeals host managed reddit datahoarder
- truenas forums 2025 host-managed SMR recertified drives bought by mistake
- linux-raid / "dm-zoned" "mdadm" SMR array; "dm-zoned" raid1 OR raid5 md
  experience blog 2024-2026
- "dm-zoned" "md" raid Le Moal SMR drives raid on top
- XFS zoned mode host-managed SMR hard drive kernel 6.15; phoronix XFS zoned;
  "XFS Zone Allocator No Longer Experimental" Linux 7.2
- HC620 host-managed r/DataHoarder; "host managed SMR" r/homelab OR
  r/DataHoarder dm-zoned OR btrfs zoned 2025
- Synology DSM does not support host-managed SMR HC620 community.synology.com
- nascompares HC620 OR HC650 host managed SMR NAS
- forums.servethehome.com "host managed" SMR drives deal zoned btrfs 2024-2026
- "Exos X26z" OR "X20z" OR "X18z" host managed home linux btrfs experience forum
- level1techs forum HC620 OR HC650 OR HC680 host managed SMR btrfs raid1 experience
- unraid forums host managed SMR HC620/HC680/X26z 2025-2026 zoned btrfs pool
- openmediavault forum HC620 OR host managed OR zoned disk btrfs wipe error
- TrueNAS forums host managed SMR HC620 2025 2026 dm-zoned OR VM workaround
- "dm-zoned" "blocked for more than" OR "hung task" dmz reclaim 2025 OR 2026
- mdadm man page --assume-clean raid5 parity mismatch
- synology "mv14xx" kernel panic OR crash; Synology "88SE1475" OR "mv14xx" driver
- xpenology SA6400 VM slow boot acpi_pm clocksource kvm-clock RR loader; RR
  loader SA6400 custom kernel kvm-clock
- "started to look into HM SMR drives" chia linux; "Western Digital HSMR 18TB
  drives good for UNRaid"
- Could not be read (content not verified, nothing listed from them): a
  tenforums HC620 thread (403), xpenology.com threads (403), zhihu (403),
  club.fnnas.com (connection refused), tieba.baidu.com (403), chiphell (567),
  mobile01 (403), community.synology.com posts (empty page), lore.kernel.org
  and bugzilla.kernel.org (bot protection), community.netgear.com (403), a
  Microchip Adaptec SMR RAID white paper (PDF not readable)

**Pass 3 (web search and direct fetches)**

- dm-zoned md raid5 host-managed SMR
- Synology Virtual Machine Manager PCIe passthrough
- "dm-zoned" mdadm RAID array host-managed
- linux-raid md raid zoned block device support dm-zoned mailing list
- RAID host-managed SMR drives paper zoned RAID5 parity
- "dm-zoned" "raid" linux-raid OR dm-devel mdadm over dm-zoned
- HSMR-RAID low overhead RAID-5 host-managed shingled magnetic recording disk array SAC 2023
- md raid zoned devices not supported "zoned" mdadm refuses host-managed kernel patch raid0 raid1
- RAIZN RAID for zoned namespaces ASPLOS 2023
- zonedstorage.io linux dm-crypt zoned support dm-linear dm-flakey device mapper targets zoned
- Damien Le Moal dm-zoned Vault talk slides zoned block device device mapper
- dm-zoned performance evaluation paper host-managed SMR throughput reclaim
- dm-zoned reclaim hung task blocked "dmz_reclaim" bug
- dm-zoned deprecate remove target proposal dm-devel 2024 OR 2025
- site:kb.synology.com Virtual Machine Manager PCIe passthrough GPU requirements
- Synology VMM NVIDIA vGPU GPU passthrough officially supported models DSM 7
- Synology "Virtual Machine Manager" release notes "passthrough" USB OR PCIe OR GPU
- Synology host-managed SMR drive not recognized HC680 OR HC670 OR HC650 OR "Exos X26z"
- Synology DSM zoned block device support CONFIG_BLK_DEV_ZONED host-managed SMR
- "dmzadm" "mdadm"
- reddit host managed SMR dm-zoned raid mdadm experience HC620 OR HC650 OR HC670
- LWN XFS zoned device support 6.15 host-managed SMR realtime device
- "md" raid "zoned block devices" unsupported "md: " patch "bdev_is_zoned" OR "blk_queue_is_zoned" raid
- Hannes Reinecke dm-zoned multiple devices cache device patch series kernel 5.8 dm-devel 2020
- "zoned_qd1_writes" sysfs block
- "dm-zoned" OR "dm_zoned" "blocked for more than 120 seconds" OR "hung_task" reclaim
- Synology DSM vfio-pci passthrough SATA controller OR HBA to VM "virsh attach-device"
- Synology DX1222 OR DX517 expansion unit Marvell 88SE9235 controller eSATA port multiplier
- DS1821+ lspci SATA controller eSATA JMB585 OR ASM1062 OR "V1500B" internal bays controller
- DS3622xs+ lspci Marvell 88SE1475 OR "1b4b:9235" OR mv14xx Synology
- Synology DS1821+ datasheet expansion "DX517" eSATA "AMD Ryzen V1500B" specifications
- "DS1821+" lspci "SATA controller" eSATA same controller internal disks Synology
- Marvell 88SE9235 IOMMU DMA alias quirk function 1 vfio passthrough 1b4b:9235
- kernel bugzilla 42679 Marvell SATA IOMMU phantom function DMA alias 88SE9230
- Synology NAS host managed SMR zoned drive VM passthrough "Virtual Machine Manager" OR VMM
- "host-managed" SMR QEMU passthrough zoned virtio-blk OR scsi-block guest ZBC
- "dm-zoned" RAID evaluation paper SMR array "mdraid" OR "md-raid" OR "software RAID"
- Synology knowledge center SMR drives compatibility "host-managed" not supported
- Synology VMM passthrough NVMe OR "HBA" OR "SATA controller" to virtual machine virsh vfio DS3622xs+ OR DS1621+ OR DS1821+ blog
- LWN LSFMM 2025 OR 2026 zoned storage SMR HDD write plugging Le Moal
- host-managed SMR drive behind SATA port multiplier OR "88SE9235" OR "88SM9705" zoned detected
- synology broadwellnk kernel config 4.4.302 github ".config" DSM 7.2 toolkit
- Direct fetches: the kernel dm-zoned and md admin guides; zonedstorage.io
  dm-zoned, dm-crypt, Linux overview, configuration, FAQ, SMR disk and QEMU
  pages; the dm-zoned-tools README; LWN 714387, 856556 and 1001751; the
  Synology VMM 7.2 and 7.4 specification pages, the VMM changelog, the DX1222
  and DX517 product pages and an SMR knowledge-base article; GitHub READMEs and
  commit history for sramshaw, swaan, jcchen7566, RROrg/rr #18569 and the
  007revad wiki; upstream `dm-zoned-reclaim.c`, `raid5.h`/`raid5.c` and the
  dm-zoned commit history; the kernel sysfs-block ABI; mdadm(8); the LKML
  88SE9235 quirk thread; the linux-block zoned HDD series and the dm-devel
  double-free report; the 2018 dm-devel lockdep fix
- Failed or blocked: lore.kernel.org search (bot protection), ACM Digital
  Library full text (403), the Xpenology forum (403), a Synology KB
  requirements page (rendered by JavaScript), Synology datasheet PDFs (no PDF
  text extractor available)

</details>

## Other pages

[01 — Requirements and risks](01-requirements-and-risks.md) ·
[02 — Synology controller passthrough](02-synology-controller-passthrough.md) ·
[03 — Guest storage stack](03-guest-storage-stack.md) ·
[04 — OpenMediaVault and Synology integration](04-openmediavault-and-synology-integration.md) ·
[05 — Operations, monitoring, performance](05-operations-monitoring-performance.md) ·
[06 — Alternatives and lessons](06-alternatives-and-lessons.md) ·
[08 — Caching](08-caching.md)
