# 08 — Caching: dm-zoned cache devices and a volume cache

This page covers two optional cache layers the author added on 2026-09-29, why
they help, what they cost, and how they were measured. Both use **regular block
devices**: on the reference system, virtual disks of the NAS, which sit behind
DSM's own NVMe SSD cache. Nothing here puts a cache *on* the zoned drives
([06, section 5](06-alternatives-and-lessons.md#5-zfs-lvm-md-and-caches-directly-on-host-managed-drives)
explains why that fails). Every number comes from the author's logs of
2026-09-28 and 09-29 on one machine; each test ran once.

> [!WARNING]
> **Both layers make the pool depend on the cache device.** A dm-zoned cache
> device holds that member's **mapping metadata**. Without it, the data on the
> drive cannot be put back together. A write-back volume cache holds data that
> may not have reached the drives yet. If the cache devices are virtual disks
> on the NAS's own volume, **losing that volume loses the zoned pool too**. The
> pool is then no longer an independent copy of the NAS's data. Keep a backup
> that does not live on either.

## Contents

1. [The bottleneck: every write goes through the drive's own buffer](#1-the-bottleneck-every-write-goes-through-the-drives-own-buffer)
2. [What a member rebuild costs without a cache](#2-what-a-member-rebuild-costs-without-a-cache)
3. [dm-zoned cache devices](#3-dm-zoned-cache-devices)
4. [A volume cache between the RAID and LUKS](#4-a-volume-cache-between-the-raid-and-luks)
5. [Synology: make the SSD cache take the cache disks' I/O](#5-synology-make-the-ssd-cache-take-the-cache-disks-io)
6. [What is still untested](#6-what-is-still-untested)

## 1. The bottleneck: every write goes through the drive's own buffer

dm-zoned turns a host-managed drive into a normal block device. For a write to a
chunk that holds no data yet, it **always** allocates a random-write zone: a
conventional zone of the drive, or a cache zone if a cache device exists.
It never writes such a chunk straight into a sequential zone. The upstream
source says so in `dmz_get_chunk_mapping()` (`drivers/md/dm-zoned-metadata.c`,
comment `/* Allocate a random zone */`). Reclaim later copies each full buffer
zone into a sequential zone (`dmz_reclaim_rnd_data()` in `dm-zoned-reclaim.c`
allocates the destination with `DMZ_ALLOC_SEQ`).

Without a cache device, both happen **on the same drive**. The drive writes the
data into its conventional zones, reads it back, and writes it again
sequentially. On the reference drives this settles at about **30 MB/s per
drive** once the buffer is full. That matches the idle drain rate in
[05, section 1.2](05-operations-monitoring-performance.md#12-the-dm-zoned-write-buffer)
(7-8 zones of 256 MiB per minute).

Larger copy jobs did **not** help. Raising `dm_mod.kcopyd_subjob_size_kb` from 512 to
its maximum of 1024 (read when the dm-zoned target is created; the pool was
restarted for it) left the rebuild at 26 MB/s against 27-30 MB/s before.

## 2. What a member rebuild costs without a cache

Measured during the drive-replacement test of 2026-09-28
([05, section 3.7](05-operations-monitoring-performance.md#37-replacing-a-drive-tested-2026-09-28)):
one member was pulled, re-formatted, and added back.

| Phase | md recovery rate | Why |
|---|---|---|
| First ~55 min | 80-93 MB/s | The new member's 998 conventional zones (~250 GiB) absorb the writes |
| Afterwards | **28-30 MB/s**, falling to 26 | Every rebuilt chunk goes through the buffer and reclaim on the same drive |
| md's estimate at 2.4 % and at 6.8 % | 14,177 and 14,940 min | **About 10 days** for a 24.6 TiB member |

During those 10 days the RAID5 has no redundancy. A write-intent bitmap would
shorten a rebuild after a brief interruption; see
[03, Step 5](03-guest-storage-stack.md#step-5---create-the-raid5) for why the
reference array had none.

## 3. dm-zoned cache devices

dm-zoned accepts one regular block device in front of the zoned drives
(`Documentation/admin-guide/device-mapper/dm-zoned.rst`, "multi-device"). That
device is split into cache zones of the same size as the drive's zones. It
becomes the write buffer, and it holds the member's metadata.

### 3.1 What it changed

Member re-formatted with a 256 GiB cache device (a NAS virtual disk), then added
back to the array at 10:01 on 2026-09-29:

| Phase | md recovery | Cache device | Drive |
|---|---|---|---|
| Cache filling | 108-132 MB/s | writes ~103-117 MB/s | — |
| Cache full, reclaim reading data that went to the NAS's **hard drives** (see [section 5](#5-synology-make-the-ssd-cache-take-the-cache-disks-io)) | 7-26 MB/s | reads 14-39 MB/s | writes 14-40 MB/s |
| Cache full, reclaim reading from the NAS's **SSD cache** | **92-178 MB/s** | reads **131-137 MB/s** | **writes 131-137 MB/s, only sequential** |

The drive only ever writes sequentially: reclaim reads the cache device and
writes each zone once, in order. The NAS's own RAID rebuild ran next to it at
normal priority the whole afternoon (96-125 MB/s). The member rebuild ran at
73-100 MB/s shortly after the switch, and at 150-170 MB/s from about 15:00 on.
That makes the rebuild **about 2-3 days instead of 10**.

The dm-zoned device got slightly larger, because the cache zones count as
capacity: 53,259,272,192 sectors instead of 52,722,401,280. md needs at least
the old size, so a member with a cache device can be added to an array built
without one.

### 3.2 The catch: the cache device is bound to the member

The cache device holds the member's dm-zoned metadata (primary and secondary
metadata sets; the drive keeps only a third superblock). `dmzadm`
2.2.2 can `--format`, `--check`, `--repair`, `--relabel`, `--start` and
`--stop`. It **cannot** detach or move a cache device.

- **Removing the cache** means re-formatting the member without it, then a full
  md rebuild of that member (the ~10 days of section 2).
- **Moving the cache** to another device of the same size should work as a
  byte-exact copy while the pool is stopped, because the copy carries the same
  superblocks. This is **untested**.
- **Adding a cache** to a member also means re-formatting it and a full rebuild.
  The cheap moment is a drive replacement, which re-formats the member anyway.

The author therefore gives a member a cache device **only when that member is
rebuilt anyway**. The other members keep their on-drive buffer.

### 3.3 How to set it up

Only on a member that md has already failed and removed: re-formatting a
**surviving** member of a degraded RAID5 destroys the array. The procedure is
the drive replacement in
[05, section 3.7](05-operations-monitoring-performance.md#37-replacing-a-drive-tested-2026-09-28),
with the cache device named first:

```sh
# the regular device first, then the zoned drive
dmzadm --format /dev/disk/by-id/<CACHE_DISK> /dev/disk/by-id/ata-WDC_WSH722870ALE604_<SERIAL> --force
dmsetup create dzN --table "0 $(blockdev --getsz /dev/disk/by-id/ata-WDC_WSH722870ALE604_<SERIAL>) zoned /dev/disk/by-id/<CACHE_DISK> /dev/disk/by-id/ata-WDC_WSH722870ALE604_<SERIAL>"
mdadm /dev/md/hc680 --add /dev/mapper/dzN
```

`--force` was needed because both devices still carried old signatures. For
boot, add the cache device as a third field on the member's line in
`/etc/zonedpool/dmzoned.conf`
([examples/dmzoned.conf.example](../examples/dmzoned.conf.example)). The
assemble script ([scripts/guest/zonedpool-dmzassemble](../scripts/guest/zonedpool-dmzassemble))
waits for both devices and builds the two-device table. That path was
exercised by a guest reboot on 2026-09-29.

## 4. A volume cache between the RAID and LUKS

This is a Linux `dm-cache` layer **above** the RAID: md sees nothing of it, and
neither do the drives. It caches the array as a whole:

```text
dz1 dz2 dz3 → md RAID5 → hc680cache (dm-cache, write-back) → hc680crypt (LUKS2) → XFS
```

It sits **below LUKS**, so the cache device only ever holds ciphertext. dm-cache
does not change the origin device's format: it can be inserted into an existing
pool and removed again without re-formatting anything.

### 4.1 Layout and setup

The cache device is prepared with LVM: a volume group `hc680ssd`, a 1 GiB
metadata volume (zeroed before first use, as dm-cache requires) and a data
volume (480 GiB on a 512 GiB virtual disk). The target:

```text
0 <md sectors> cache /dev/hc680ssd/volcache_meta /dev/hc680ssd/volcache_data /dev/md/hc680 1024 1 writeback smq 0
```

512 KiB cache blocks (1024 sectors), write-back, the default `smq` policy. The
pieces:

| File | Role |
|---|---|
| [scripts/guest/zonedpool-volcache](../scripts/guest/zonedpool-volcache) | `start` activates the volume group and creates `hc680cache`; `stop` removes it |
| [systemd/zonedpool-volcache.service](../systemd/zonedpool-volcache.service) | After the array assembles, before LUKS opens |
| [systemd/zonedpool-cryptopen.service.d/volcache.conf](../systemd/zonedpool-cryptopen.service.d/volcache.conf) | LUKS opens **only** on `/dev/mapper/hc680cache`, and refuses to fall back to the raw array |
| `/etc/crypttab` | `hc680crypt /dev/mapper/hc680cache …` instead of `UUID=…` |

> [!CAUTION]
> **Never open LUKS on the raw array while a write-back cache exists.** Once
> the layer is in place, the same LUKS header, and so the same UUID, is visible
> on the raw md device **and** through the cache. Opening it on the raw md
> device bypasses blocks that are still dirty in the cache, and the filesystem
> sees stale data. That is why the unlock unit and `crypttab` name the cache
> device by path and never by UUID.

Inserting it into the running pool took 10 seconds of downtime (stop NFS,
unmount, close LUKS, create the layer, open, mount). md kept running, including
a member rebuild. The author's setup script did the checks first: the disk is
blank and unused, LUKS is open on the raw array, and no clients are connected.

### 4.2 What it changed

`fio`, 8 GiB file on the pool, O_DIRECT, while a member rebuild was running
(so every number is lower than on an idle pool):

| Test | Before | With volume cache |
|---|---|---|
| Random read 4 KiB, queue depth 16 | 303 IOPS, 53 ms | **9,804 IOPS, 1.6 ms**; second pass **12,859 IOPS, 1.2 ms** |
| Random write 4 KiB, queue depth 16 | 208 IOPS, 77 ms | **5,620 IOPS, 2.8 ms** |
| Sequential write 1 MiB | 77 MB/s | 75 MB/s |
| Sequential read 1 MiB | 163 MB/s | 124 MB/s (see below) |

- **Random I/O** is served from the cache: about 20-40 times faster.
- **Sequential I/O** passes by, because `smq` does not cache streams. It does
  not speed up large copies; for those, the per-member cache of section 3 is
  what helps.
- **The lower sequential read** was measured while the member rebuild competed
  harder (md 97 → 56 MB/s during that run). It is not yet confirmed on an idle
  pool.
- **The cache stays warm across reboots.** After a guest reboot, a 30-second
  random-read test on the same file had a 100 % hit ratio (185,684 hits, 0
  misses). dm-cache keeps its mapping in the metadata volume.

### 4.3 Removing it

Without data loss: switch the policy to `cleaner`, wait until the dirty count
reaches 0, then take the pool offline and remove the layer:

```sh
dmsetup reload hc680cache --table "$(dmsetup table hc680cache | sed 's/ smq 0$/ cleaner 0/')"
dmsetup resume hc680cache
dmsetup status hc680cache          # field 14 = dirty blocks; wait for 0
```

Then stop NFS, unmount, close LUKS, `dmsetup remove hc680cache`, remove the
drop-in and restore `crypttab`. This rollback is **untested**.

## 5. Synology: make the SSD cache take the cache disks' I/O

On the reference NAS the cache devices are VMM virtual disks on volume 1, which
has a read-write NVMe SSD cache. A virtual disk can be added to the running
guest (VMM → Edit → Storage); it appeared in the guest immediately. Give each
one a different size, because DSM does not show which disk is which inside the
guest.

**DSM's SSD cache skips sequential I/O.** DSM's cache is Synology's
`flashcache`. Its sysctl
`dev.flashcache_<cache>+<volume>.skip_seq_thresh_kb` is 1024: any sequential
stream of 1 MiB or more bypasses the SSDs. The virtual disk's traffic is exactly
that. In the cache statistics, 69 % of writes and 67 % of reads were "uncached
sequential", and the size histogram peaked at exactly 1,048,576 bytes. So the
cache devices were read back from the NAS's hard drives. The rebuild fell to
7-26 MB/s whenever the NAS's own RAID rebuild competed for them. DSM 7 has **no
UI switch** for this any more.

Setting it to 0 fixed the rebuild (measurements below). It also has a cost: with 0, a
DSM Data Scrubbing (btrfs scrub) put both NVMe cache SSDs at 100 % busy while the hard drives
sat at ~20 %, because the scrub's long sequential read stream was inserted into the cache.
Setting 524288 (512 MiB) brought the SSDs back to normal at once. The value the author keeps:

| Situation | `skip_seq_thresh_kb` |
|---|---|
| Normal operation, NAS scrubs and repairs, backups | **524288** (512 MiB): zone-sized bursts (256 MiB) from the cache disks are cached, long streams bypass the SSDs |
| A guest member rebuilds onto a dm-zoned cache device | **0** for the duration (one stream across hundreds of GB), then back to 524288 |
| Both at once | avoid; schedule them apart |

```sh
K='dev.flashcache_shared_cache_vg1_alloc_cache_1+volume_1.skip_seq_thresh_kb'
sysctl -w "$K=524288"                                     # normal
sysctl -w "$K=0"                                          # only during a cached member rebuild
dmsetup table cachedev_0 | grep -i "skip sequential"      # → skip sequential thresh(...K)
```

The name is the reference NAS's; `sysctl -a | grep skip_seq_thresh_kb` shows
yours. The value is lost at every NAS reboot.
[scripts/nas/flashcache-seq-skip.sh](../scripts/nas/flashcache-seq-skip.sh)
sets it (default 524288, or the value given as its argument) for every
flashcache instance it finds. Run it from DSM's Task Scheduler as root on the
"Boot-up" event. A manual run was verified, but whether DSM fires the task at
boot is **not yet verified**. Also run it once by hand after any change to the
SSD cache in DSM. Not yet measured: whether 524288 keeps the zone bursts cached
in daily use, and a member rebuild during a NAS scrub.

What changed with 0 during the rebuild:

- The "uncached sequential" counters stopped rising.
- Dirty data in the NAS cache levelled off at about the virtual disks' size
  (~262 GiB for one 256 GiB disk). The virtual disk rewrites its blocks in
  place, so there was no pile-up.
- Reclaim then read the cache device at 131-137 MB/s.

With 0 permanently, **every** sequential stream on that volume passes through
the SSDs (backups, large copies, scrubs), adding wear, displacing other cached
data and, during a scrub, saturating them. Hence 0 only for the rebuild.

**The NAS's own rebuild priority matters too.** With DSM's RAID resync set to
lower impact, the NAS's own rebuild fell to 10-25 MB/s (a ~10-day estimate)
while the guest's cache disks were busy. At normal priority the NAS rebuilt at
96-125 MB/s, and the member rebuild ran at 73-170 MB/s next to it.

## 6. What is still untested

- Moving a dm-zoned cache device to another device (section 3.2).
- Removing the volume cache with the `cleaner` policy (section 4.3).
- Whether DSM runs the Task Scheduler boot-up task at boot (section 5). On the
  reference NAS a boot-up task for another purpose never ran in September 2026.
- A crash with dirty data in the write-back volume cache. dm-cache persists its
  metadata, but no power-cut or forced-reset test has been done yet.
- Everyday write throughput with all members cached. Only one member has a
  cache device.
- Whether the 7.2.6 idle-drain stall
  ([05, section 1.2.1](05-operations-monitoring-performance.md#121-the-idle-drain-can-stall-kernel-726-install-the-reclaim-kick))
  also happens on a member with a cache device.

## Other pages

[01 — Requirements and risks](01-requirements-and-risks.md) ·
[02 — Synology controller passthrough](02-synology-controller-passthrough.md) ·
[03 — Guest storage stack](03-guest-storage-stack.md) ·
[04 — OpenMediaVault and Synology integration](04-openmediavault-and-synology-integration.md) ·
[05 — Operations, monitoring, performance](05-operations-monitoring-performance.md) ·
[06 — Alternatives and lessons](06-alternatives-and-lessons.md) ·
[07 — Prior art](07-prior-art.md)
