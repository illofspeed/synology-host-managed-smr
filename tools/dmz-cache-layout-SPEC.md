# dm-zoned on-disk metadata (v2) and a cache+zoned -> single-zoned converter

Status: research spec, read-only. Written 2026-10-02.

## Sources (fetched 2026-10-02, local copies in `src/`)

| Short name | Source | Version |
|---|---|---|
| `meta.c` | `torvalds/linux` master `drivers/md/dm-zoned-metadata.c` | last commit c92d632f (2026-07-15) |
| `dmz.h(k)` | `drivers/md/dm-zoned.h` | master |
| `target.c` | `drivers/md/dm-zoned-target.c` | master |
| `reclaim.c` | `drivers/md/dm-zoned-reclaim.c` | master |
| `dm-table.c` | `drivers/md/dm-table.c` | master |
| `tools/*` | `westerndigitalcorporation/dm-zoned-tools`, tag **v2.2.2**, `src/` | v2.2.2 is byte-identical to `master` (diffed) |

Line numbers refer to those files. `tools/` files: `dmz.h`, `dmz_lib.c`, `dmz_format.c`,
`dmz_dev.c`, `dmz_check.c`, `dmz_devmapper.c`, `dmzadm.c`.

Units: **block** is always 4 KiB (`DMZ_BLOCK_SHIFT 12`, `dmz.h(k)`:27-46). Zone size
`zone_nr_blocks` (zb below) is the zoned drive's zone size in 4 KiB blocks. It must be a power
of two (`ilog2` in `meta.c`:1469-1471). Example: a 256 MiB zone has zb = 65536.

---

## 1. Superblock (`struct dmz_super`)

Defined in `meta.c`:41-83. The tools copy is `tools/dmz.h`:74-119 (`dm_zoned_super`, packed).
It is the same layout. The comment numbers in the source give the *end* offset of each field.
The table below gives start offsets. Every integer is **little-endian**.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `magic` | `DMZ_MAGIC` = `('D'<<24)|('Z'<<16)|('B'<<8)|'D'` = **0x445A4244**. On disk the bytes read `44 42 5A 44` (`meta.c`:24-27). |
| 4 | 4 | `version` | `DMZ_META_VER` = **2** (`meta.c`:19, `tools/dmz.h`:41). The kernel rejects a version above 2 (`meta.c`:987-992). |
| 8 | 8 | `gen` | Generation number. It also seeds the CRC. |
| 16 | 8 | `sb_block` | Absolute (global) block number of this superblock (see section 2). |
| 24 | 4 | `nr_meta_blocks` | Blocks in one metadata set: 1 (SB) + map blocks + bitmap blocks. |
| 28 | 4 | `nr_reserved_seq` | Sequential zones reserved for reclaim. |
| 32 | 4 | `nr_chunks` | Entries in the mapping table. This is the exposed capacity in zones. |
| 36 | 4 | `nr_map_blocks` | Blocks used by the chunk mapping table. |
| 40 | 4 | `nr_bitmap_blocks` | Blocks used by the per-zone valid-block bitmaps. |
| 44 | 4 | `crc` | Checksum (see below). |
| 48 | 32 | `dmz_label` | Target label. NUL-padded string, max 31 characters (`tools/dmzadm.c`:211). |
| 80 | 16 | `dmz_uuid` | UUID of the dm-zoned *target* (raw 16 bytes). |
| 96 | 16 | `dev_uuid` | UUID of the *device holding this superblock* (raw 16 bytes). |
| 112 | 400 | `reserved` | Zero. |
| 512 | 3584 | (rest of the 4 KiB block) | Zero. It is still covered by the CRC. |

### CRC

- Kernel write path (`meta.c`:795-796):
  `sb->crc = 0; sb->crc = cpu_to_le32(crc32_le(sb_gen, (unsigned char *)sb, DMZ_BLOCK_SIZE));`
- Kernel check (`meta.c`:998-1006): it saves the stored crc, sets `sb->crc = 0`, computes
  `crc32_le(gen, sb, 4096)` and compares.
- Tools (`tools/dmz_lib.c`:27-41) use a plain bitwise reflected CRC-32 with poly `0xEDB88320`.
  The register starts at the seed and there is **no pre- or post-inversion**. `dmz_write_super`
  computes it over the whole 4096-byte buffer with the crc field still 0
  (`tools/dmz_format.c`:62, 89-90). `dmz_check_sb` passes `sb->gen` as the seed
  (`tools/dmz_check.c`:762-764).
- Summary: **crc = raw_crc32_le(seed = (u32)gen, data = the full 4096-byte block with bytes
  44..47 set to 0)**. The seed parameter is `u32` in both implementations, so a 64-bit `gen`
  is truncated to its low 32 bits. Tool-formatted devices load in the kernel, so the two
  implementations must agree.
- In Python: `raw(seed, data) = ~zlib.crc32(data, ~seed & 0xffffffff) & 0xffffffff`. I checked
  this against the tools' bitwise loop on random 4 KiB buffers with 5 seeds, and they match.

### `gen`: which set is valid

- `dmz_load_sb` (`meta.c`:1221-1342) checks both sets. If both are good, the set with the
  higher `gen` becomes primary. **On a tie, set 0 wins** (`meta.c`:1296-1302,
  `if (sb_gen[0] >= sb_gen[1])`). `dmzadm --check` picks the same way
  (`tools/dmz_check.c`:1066-1087).
- If one set is bad, the kernel rebuilds it from the good one (`dmz_recover_mblocks`,
  `meta.c`:1171-1216).
- The flush protocol (`meta.c`:877-967) writes dirty blocks to the *non-primary* set as a log,
  then that set's SB with gen+1, then the same dirty blocks to the primary, then the primary SB
  with gen+1. After a clean flush both sets hold the same gen and the same content.
- Only *dirty* blocks are written. The design therefore assumes **both sets are identical**. A
  converter must write identical map and bitmap content into both sets.
- `dmzadm --format` writes gen = 1 in both sets (`tools/dmz_format.c`:199) and gen = 0 in
  tertiary SBs (`tools/dmz_format.c`:314).

### `dmz_uuid`, `dev_uuid`, `dmz_label` in the multi-device case

- Format generates a random `dmz_uuid` for the target and a random UUID per block device
  (`tools/dmz_format.c`:226-235).
- `dmz_write_super` stores the target UUID and label, plus the UUID of the bdev that contains
  the block being written (`tools/dmz_format.c`:64, 84-88; `dmz_block_to_bdev`,
  `tools/dmz_dev.c`:32-49). As a result:
  - The primary and secondary SBs (both on the cache device) carry `dev_uuid` = the **cache**
    device UUID.
  - The tertiary SB (on the zoned drive) carries `dev_uuid` = the **zoned drive** UUID.
  - All of them carry the same `dmz_uuid` and the same 32-byte `dmz_label`.
- Kernel checks for v2 (`meta.c`:1014-1039):
  - `dmz_uuid` must be non-null and equal across every SB it reads (primary, secondary,
    tertiary).
  - The label must match with `memcmp` over **all 32 bytes** (`BDEVNAME_SIZE`, 1028-1034).
  - `dev_uuid` must be non-null. It is imported into `dev->uuid` and written back unchanged
    (`meta.c`:776). Nothing compares it against anything else.
- Default label at format time: `"dmz-<serial of bdev[0]>"`, falling back to
  `"dmz-<bdev[0] name>"` (`tools/dmz_lib.c`:380-398). In the 2-device case bdev[0] is the
  **cache** device. `dmzadm --start` names the dm device after the label and sets dm uuid
  `"dmz-<dmz_uuid>"` (`tools/dmz_devmapper.c`:160, 190-197).

---

## 2. Metadata layout

A metadata set is a contiguous run of blocks (`meta.c`:29-40):

```
set_start + 0                          : superblock
set_start + 1 .. + nr_map_blocks       : chunk mapping table
set_start + 1 + nr_map_blocks ..       : bitmap blocks (nr_bitmap_blocks)
```

Kernel metadata block number `mblk_no` is relative to the start of the primary set. The device
block is `sb[mblk_primary].block + mblk_no`, read from `sb[primary].dev` (`meta.c`:534-535;
writes at `meta.c`:709-710). The map starts at `mblk_no` 1 (`dmz_load_mapping` reads
`dmz_get_mblock(zmd, i + 1)`, `meta.c`:1695). Bitmap addressing is covered in section 5.

`nr_meta_zones = ceil(nr_meta_blocks / zb)` (`meta.c`:1053-1054). Sets 0 and 1 occupy
`nr_meta_zones` zones each, back to back.

### (a) Single zoned device (`dmzadm --format /dev/zoned`)

- **Primary SB zone**: the first zone reported as conventional (`DMZ_RND`) that is not
  offline or read-only (`meta.c`:1397-1404). The tools choose the first `dmz_zone_rnd` zone
  (conventional or seq-pref) and do not look at its condition (`tools/dmz_lib.c`:225-234, 275).
- `S` = that zone id. Set 0 starts at block `S*zb`. Set 1 starts at block `(S + nr_meta_zones)*zb`
  (`meta.c`:1246-1253; `tools/dmz_format.c`:307-308).
- All `2*nr_meta_zones` zones from S on must be random (conventional). Otherwise load fails
  with "metadata zone %d is not random". Those zones are flagged `DMZ_META` (`meta.c`:2901-2917)
  and are never allocated (`meta.c`:1781-1782, 2262-2266).

### (b) Cache (regular) + zoned (`dmzadm --format /dev/cache /dev/zoned`)

- The kernel requires the regular device first and the zoned device(s) after it
  (`target.c`:705-730, 774-796).
- **Primary SB zone = global zone 0 = cache block 0** (`meta.c`:1513-1517). On the tools side
  the cache zones have `BLK_ZONE_TYPE_UNKNOWN` and are the only "cache" zones
  (`tools/dmz.h`:333-338), so `sb_zone` is the first cache zone.
- Set 0 lives at cache block 0. Set 1 lives at cache block `nr_meta_zones*zb`. **Both sets are on
  the cache device**: `sb[1].dev = sb[0].dev` (`meta.c`:1253). The `2*nr_meta_zones` zones must be
  cache zones (`meta.c`:2910).
- **Tertiary superblock**:
  - Location: block 0 of each zoned device, i.e. the first block of that device's first zone.
  - Writer: `dmz_write_super(dev, 0, bdev[i].block_offset)` (`tools/dmz_format.c`:311-318).
  - Contents: a full SB with gen = 0, `sb_block` = the global block of that zone
    (= `block_offset` = `nr_cache_zones*zb`), the **same** geometry fields as the main sets,
    the same `dmz_uuid`/label, and `dev_uuid` = the zoned drive's UUID.
  - If zone 0 is a sequential zone, the tools reset it first (`tools/dmz_format.c`:24-40).
- **Kernel use of the tertiary SB** (`meta.c`:1308-1340):
  - For each zoned device it reads block 0 of that device (`sb->block = 0`, device-relative). The
    zone at `zone_offset` must be `DMZ_META`. `dmz_init_zone` always flags zone num 0 of every
    zoned device as META when `nr_devs > 1` (`meta.c`:1405-1412).
  - It then calls `dmz_check_sb(..., tertiary=true)`, which checks magic, version >= 2, CRC,
    `sb_block == zone->id << shift`, `dmz_uuid`/label equality and a non-null `dev_uuid`. It only
    warns if gen != 0 (`meta.c`:1041-1050), and it returns **before** the geometry checks.
  - A failed tertiary check fails the whole load: `-EINVAL` aborts the loop and any other error is
    returned at the end (`meta.c`:1333-1341).
  - The tertiary SB is never used for metadata I/O.
  - That zone (drive zone 0) is META and therefore never a data zone. `dmzadm --check` skips it
    (`tools/dmz_check.c`:646-653).

### `sb_block` interpretation

`sb_block` is the **absolute block in the global zone space**: `zone->id << zone_nr_blocks_shift`
(`meta.c`:781-787, check at 1008-1013). In the multi-device case the cache device is global
zones `[0, Nc)` and the zoned drive is `[Nc, Nc+Nz)`. The actual I/O offset is device-relative:
`dmz_start_block` subtracts `dev->zone_offset` (`meta.c`:221-241). On a single device the two are
the same.

---

## 3. Zone numbering

- `dmz_fixup_devices` (`target.c`:763-824):
  - Cache: `reg_dev->nr_zones = DIV_ROUND_UP(capacity, zone_nr_sectors)` and
    `reg_dev->zone_offset = 0`.
  - Each zoned device i gets `zone_offset` = the running total of the previous devices' zone counts.
  - **The cache zones come first.** A partial last (runt) cache zone still gets an id.
- The tools do the same: `bdev[0].nr_zones = ceil(cap/zone_sectors)`,
  `block_offset(bdev[i]) = sum(prev nr_zones)*zb` (`tools/dmzadm.c`:345-361).
- The global id of zoned drive zone k is `Nc + k`, where `Nc = ceil(cache_sectors / zone_sectors)`.
  The zone id maps to (device, start sector) through `dmz_start_sect`:
  `(id - dev->zone_offset) << zone_nr_sectors_shift` on `zone->dev` (`meta.c`:229-234).
  Data I/O uses this too (`target.c`:133-134).
- **Cache zones** are emulated (`dmz_emulate_zones`, `meta.c`:1417-1440). They get `DMZ_CACHE`
  and wp 0, and are counted in `nr_cache_zones` and `nr_useable_zones`. A runt last zone is also
  counted, then flagged OFFLINE. The tools emulate them as type UNKNOWN with a short final zone
  (`tools/dmz_dev.c`:392-409).
- **Zoned-drive zones** (`dmz_init_zone`, `meta.c`:1347-1415):
  - Conventional zones become `DMZ_RND`. SEQWRITE_REQ and SEQWRITE_PREF zones become `DMZ_SEQ`.
  - The wp is taken from the zone report.
  - Offline and read-only zones are flagged and are not counted as usable.
  - In v2, a zone whose length differs from the zone size is OFFLINE and not counted.
  - Zones with capacity < length are rejected outright.
- **Conventional zones on the zoned drive**:
  - *Single device*: the first `2*nr_meta_zones` from S are META. The rest are random data and
    buffer zones. New chunk writes allocate RND zones (`alloc_flags = nr_cache ? CACHE : RND`,
    `meta.c`:2046, 2158).
  - *Multi device*: none of them hold metadata except drive zone 0 (tertiary). They are
    `DMZ_RND` data zones. In practice they are used only (a) by reclaim when no free sequential
    zone is left (`reclaim.c`:284-294) or (b) when mapped there earlier. New chunk mappings and
    buffer zones come **only from cache zones** while `nr_cache > 0`. `dmz_alloc_zone` without
    `DMZ_ALLOC_RECLAIM` never falls back to other lists (`meta.c`:2213-2225). When idle, reclaim
    drains mapped cache zones first and then mapped random zones on the zoned device into
    sequential zones (`meta.c`:1938-1945, `reclaim.c`:465-495).
- **Metadata zones by layout**:
  - Single: zones `[S, S+2m)` on the drive.
  - Multi: global zones `[0, 2m)` on the cache, plus drive zone 0 for the tertiary SB.
  - All are marked `DMZ_META` and excluded from the free lists (`meta.c`:1777-1783).

---

## 4. Mapping table

- Entry format (`meta.c`:93-104): `struct dmz_map { __le32 dzone_id; __le32 bzone_id; }`, 8 bytes,
  little-endian. There are **512 entries per 4 KiB block** (`DMZ_MAP_ENTRIES`).
  `DMZ_MAP_UNMAPPED = UINT_MAX = 0xFFFFFFFF`.
- Chunk c lives in map block `1 + c/512` of the set, at entry `c % 512`
  (`meta.c`:1692-1770, 1826-1836). The map holds `nr_map_blocks` blocks. Unused trailing
  entries are written as UNMAPPED by format (`tools/dmz_format.c`:116-140).
- **Stored ids are global zone ids** (`dzone->id`, `meta.c`:2306, 2178). In the 2-device layout
  a zoned-drive zone is stored as `Nc + k`.
- Load-time rules (`meta.c`:1704-1764):
  - The id must be `< nr_zones`, the zone must exist, and a bzone must be RND or CACHE.
  - Unmapped bzones of unmapped chunks are not checked by the kernel. `dmzadm --check` flags them
    (`tools/dmz_check.c`:291-301).
  - **The kernel does NOT reject a dzone that is a META zone.** It would set `DMZ_DATA` on it, so
    a converter must ensure this never happens.
- Chunk c covers the logical sectors `[c*zone_sectors, (c+1)*zone_sectors)`
  (`dmz_bio_chunk`, `dmz.h(k)`:83-85). The exposed size is `nr_chunks * zone_sectors`
  (`target.c`:889-891).

---

## 5. Block bitmaps

- Per-zone bitmap size (`meta.c`:1472-1476; the tools use the same formula,
  `tools/dmz_lib.c`:282-285):
  - `zone_bitmap_size = zb/8` bytes.
  - `zone_nr_bitmap_blocks` (zbb) = `max(1, zb >> 15)`.
  - `zone_bits_per_mblk = min(zb, 32768)`.
- Example: a 256 MiB zone gives zb = 65536 and **zbb = 2**.
- Total: `nr_bitmap_blocks = nr_zones * zbb`, counting **every** zone (cache, meta, offline,
  runt) (`tools/dmz_lib.c`:278-286). The kernel does not check this value but addresses blocks
  by zone id.
- Address (`dmz_get_bitmap`, `meta.c`:2393-2402):
  ```c
  bitmap_block = 1 + zmd->nr_map_blocks + zone->id * zmd->zone_nr_bitmap_blocks
                 + (chunk_block >> DMZ_BLOCK_SHIFT_BITS);   /* >> 15 */
  ```
  This is relative to the start of the set, indexed by **global zone id**. Bitmaps follow the
  map directly.
- Bit order (`meta.c`:2612):
  - The kernel calls `test_bit(chunk_block & 0x7FFF, (unsigned long *)block)`.
  - The tools use bytes: bit b is `byte[b>>3] & (1 << (b&7))` (`tools/dmz.h`:296-310).
  - On little-endian hosts (x86-64) these are the same: LSB first within each byte.
- A set bit means the block holds valid data in *that* zone. Zone weight is the popcount
  (`meta.c`:2736-2766). For sequential zones, only blocks below the wp are consulted on read
  (`target.c`:197-198).

---

## 6. Geometry formulas (dmzadm) and kernel checks

### dmzadm `dmz_locate_metadata` (`tools/dmz_lib.c`:204-343)

The same code runs for single and multi device. Only the meaning of "cache zone" changes:
UNKNOWN-type emulated zones for multi, conventional/seq-pref zones for single
(`tools/dmz.h`:333-338).

```
nr_zones        = all zones (multi: Nc + Nz incl. runt; single: Nz)        (dmz_dev.c:364-366)
nr_usable_zones = all cache zones + non-cache zones not READONLY/OFFLINE    (lib.c:221-249)
nr_cache_zones  = count of cache zones (must be >= 3)                       (lib.c:255-260)
R = nr_reserved_seq (default 16, dmzadm.c:136; --seq=N >= 1);
    if R > nr_cache_zones: R = nr_cache_zones - 1                           (lib.c:266-267)
sb_block = first cache zone start block                                     (lib.c:275)
zbb = max(1, zb >> 15);  nr_bitmap_blocks = nr_zones * zbb
nr_bitmap_zones = ceil(nr_bitmap_blocks / zb)
-- first estimate --
chunks_est = usable - (nr_bitmap_zones + R)
map_est    = ceil(chunks_est / 512)
m_est      = ceil((1 + map_est + nr_bitmap_blocks) / zb);  require 2*m_est <= nr_cache_zones
-- final --
nr_chunks      = usable - (2*m_est + R)
nr_map_blocks  = ceil(nr_chunks / 512)
nr_meta_blocks = 1 + nr_map_blocks + nr_bitmap_blocks
nr_meta_zones  = ceil(nr_meta_blocks / zb)
```

Edge case: `nr_chunks` uses `m_est`, but `dmzadm --check` recomputes it with the final `m`
(`tools/dmz_check.c`:862-871). If `m < m_est` at a boundary, a fresh format would fail its own
check. A converter should solve for a consistent `m` (see 9.iii).

### Kernel load checks: everything that can reject a hand-made SB

1. Magic (`meta.c`:981-985).
2. `version <= 2`. A tertiary SB requires version >= 2 (987-996).
3. CRC (998-1006).
4. `sb_block == zone_id(SB zone) * zb` (1008-1013).
5. v2: non-null `dmz_uuid` equal across all SBs, the full 32-byte label equal across all SBs,
   and a non-null `dev_uuid` (1014-1039).
6. `nr_meta_zones = ceil(nr_meta_blocks/zb)` must be nonzero. Single device: it must be
   `< nr_rnd_zones` (usable conventional zones). Multi device: it must be `< nr_cache_zones`
   (1053-1060).
7. `0 < nr_reserved_seq < nr_useable_zones - nr_meta_zones` (1062-1066).
8. `nr_chunks <= nr_useable_zones - (2*nr_meta_zones + nr_reserved_seq)` (1068-1074).
   **This is `<=`, not `==`.**
9. Secondary SB location: zone `S + nr_meta_zones`, which must exist (1246-1253).
10. Every zone in `[S, S+2*nr_meta_zones)` must exist and be RND or CACHE (2901-2917).
11. Map entries (1704-1753): id `< nr_zones`, the zone exists, and a bzone is RND/CACHE.
12. Device level (`target.c`):
    - Single device: the device must be zoned (705-708, 798-806).
    - Multi device: the first device is regular, the others zoned, with equal zone sizes
      (774-796).
    - Zones must have capacity == length (`meta.c`:1372-1373).

What the kernel does **not** check:

- That `nr_map_blocks == ceil(nr_chunks/512)`. `map_mblk` is sized `nr_map_blocks` but indexed by
  chunk/512 (`meta.c`:1687, 2040), so a smaller value overflows the array. **Keep it exact.**
- That `nr_bitmap_blocks == nr_zones*zbb`, or that `nr_meta_blocks == 1+map+bitmap`.
- That unmapped zones have empty bitmaps.
- That mapped zones are not META.
- The `gen` of the tertiary SB (warning only).

### `dmzadm --check` additionally requires (`tools/dmz_check.c`:735-911)

- `nr_meta_blocks == 1 + nr_map_blocks + nr_bitmap_blocks`.
- `nr_reserved_seq <= nr_cache_zones`.
- **`nr_chunks == nr_usable_zones - (2*nr_meta_zones + nr_reserved_seq)` exactly.**
- `nr_map_blocks == ceil(nr_chunks/512)`.
- `nr_bitmap_blocks == nr_zones*zbb`.
- A non-empty label.

`dmzadm --start` builds the table with length `nr_chunks*zone_sectors`, where `nr_chunks` comes
from `dmz_locate_metadata` using the **default** R = 16, not the SB's value
(`tools/dmz_devmapper.c`:142-155, 352-366). That is harmless: `dmz_ctr` overwrites `ti->len`
(`target.c`:889-891), and dm-table takes `ti->len` *after* ctr (`dm-table.c`:749-754).

---

## 7. Write pointers

- WPs are **not stored in metadata**. The kernel reads them with `blkdev_report_zones` at every
  load: `zone->wp_block = (wp - start)/8` for SEQ zones, and 0 for RND/CACHE zones
  (`meta.c`:1387-1390). Later updates come from `dmz_update_zone` and the write-error handling
  (`meta.c`:1552-1631).
- Mapped sequential zones keep the on-disk WP. Bitmap bits at or above the WP are ignored on read
  (`target.c`:197-198). `dmzadm --check` flags them as errors (`tools/dmz_check.c`:512-538).
- **Unmapped, non-empty sequential zones are NOT reset at load.** `dmz_load_mapping` just puts
  them on the reserved or unmapped seq lists with a non-zero WP (`meta.c`:1798-1817).
  `dmz_alloc_zone` does not reset either. Zones are reset only in `dmz_free_zone`
  (`meta.c`:2274-2278).
  - If reclaim later picks such a zone as the target, `dmz_reclaim_align_wp` returns `-EIO`
    when `wp_block > block` (`reclaim.c`:59-72), so reclaim of that chunk fails.
  - If a new chunk is mapped onto it, the data zone has `wp != 0`, and writes at block 0 go
    through a buffer zone.
  - `dmzadm --check` reports "unmapped sequential zone not empty", and `--repair` resets it
    (`tools/dmz_check.c`:460-470).
  - **Recommendation: reset (or verify empty) every unmapped seq zone after conversion.**
- A mapped seq zone that is empty is accepted by the kernel. `--check` only prints it, and
  `--repair` unmaps it (`tools/dmz_check.c`:304-316).

---

## 8. `dmzadm --check` / `--repair`

- **`--check`** (`tools/dmz_check.c`:1146-1220):
  1. Recomputes the geometry with `dmz_locate_metadata`.
  2. Checks SB 0 and SB 1 with the strict check above. If SB 0 is bad, it scans for SB 1.
  3. Picks the higher gen (set 0 on a tie).
  4. Checks the mapping (`dmz_check_mapping`, 371-416): ids `< nr_zones`, no zone used by two
     chunks, no buffer on a cache-mapped chunk, bzone must be a cache zone.
  5. Checks the bitmaps (618-693): unmapped zones need an empty bitmap and, if seq, an empty
     zone. Mapped seq zones need no valid bits at or after the WP and no overlap with their
     bzone.
  6. Byte-compares the other set when gens are equal (1092-1141).
  7. Checks tertiary SBs (multi only, 1042-1060). It uses the *strict* check, so the tertiary SB
     geometry must match too.
- **`--repair`** (1270-1335):
  - It runs the same checks in repair mode. It unmaps bad entries, clears stray bits and resets
    non-empty unmapped seq zones.
  - It then copies the chosen set over the other one (`dmz_repair_sync_meta`, 1225-1265).
  - It only works inside the geometry computed from the device list it is given.
  - It **cannot convert layouts**. On the bare zoned drive it looks for an SB at the first
    conventional zone. The block there is either the tertiary SB (its `sb_block` is
    `Nc*zb`, not 0, so it fails the location check, and `nr_chunks` also mismatches) or not an
    SB at all. It reports "No valid superblock found".
  - It **is useful after conversion**: `dmzadm --check /dev/zoned` is the strongest offline
    validator, and `--repair` cleans non-empty unmapped seq zones and stray bitmap bits.
- **Bug (2.2.2 and upstream master, found in the lab 2026-10-02):** `--check`/`--repair` on a
  **2-device** set segfaults in the bitmap check once a chunk is mapped to a **drive conventional
  zone**. The kernel reports conventional zones with `wp = (u64)-1`. `dmz_check_mapped_zone_bitmap`
  only skips "cache" zones, and with two devices `dmz_zone_is_cache()` means the emulated
  cache-device zones only (single device: random zones). So `wp_block` becomes garbage and the
  loop reads far past the 2-block bitmap buffer (`segfault … error 4 in dmzadm[68a4…]`). A fresh
  or lightly used pair (data only in cache and seq zones) checks fine. The HC680 has 1,006
  conventional zones, so the real dz2 pair is affected once reclaim uses them. Single-device
  checks are fine (random zones count as cache there). Use the kernel instead: start the
  2-device target, read the data, remove it cleanly. With `--repair` the same loop could clear
  bits based on heap garbage before it crashes, so never run it on a 2-device set.
- `--relabel` (1340-1416) needs all sets valid. After conversion it can change the inherited
  "dmz-<cache serial>" label.

---

## 9. Per-device information a converter must handle

- Primary and secondary SBs: `dev_uuid` (currently the cache device's UUID) and `sb_block`
  (absolute location). Both must be rewritten.
- The tertiary SB at drive block 0 is the only per-device record on the zoned drive.
  - If drive zone 0 is conventional, single-device set 0 starts at block 0 and overwrites it.
  - **Back it up first.** Without it the old 2-device target will not load.
  - If drive zone 0 is a sequential zone, it stays a non-empty unmapped seq zone (wp = 1 block)
    after conversion. Reset it.
- Nothing else is per-device. WPs come from the drive. Zone types come from the report and the
  device order.

---

## 10. Converter recipe

Notation:

| Symbol | Meaning |
|---|---|
| `zb` | Zone size in blocks |
| `zbb` | Bitmap blocks per zone |
| `Nc` | Cache zones = `ceil(cache_sectors/zone_sectors)` |
| `Nz` | Drive zones |
| `o_*` | Old values from the cache SB |
| `n_*` | New values |

### (i) Read the old metadata (cache device, read-only)

1. The old target must be **stopped cleanly**. `dmz_dtr` flushes metadata (`target.c`:974).
   Nothing may hold the devices.
2. Before stopping, **drain the cache**. Leave the target idle (idle reclaim starts after
   10 s, `reclaim.c`:42), and optionally send `dmsetup message <dev> 0 reclaim`
   (`target.c`:1129-1134). Wait until `dmsetup status` shows `U/T cache` with U == T
   (`target.c`:1088-1091). Ideally the drive's random zones also show all-unmapped
   ("u/t random").
3. Read SB0 at cache block 0. Validate magic, version 2, CRC with seed `(u32)gen`, and
   `sb_block == 0`.
4. Compute `o_m = ceil(o_nr_meta_blocks/zb)`. Read SB1 at cache block `o_m*zb` and validate it
   (`sb_block == o_m*zb`).
5. Choose `P` = the set with the higher gen, or set 0 on a tie.
   - If both are valid with equal gens, byte-compare blocks `1..o_nr_meta_blocks-1`
     (`dmzadm --check /dev/cache /dev/zoned` does this too, but see the bug in §8: it segfaults on
     a real HC680 pair).
   - If the gens differ, stop. Start the 2-device target once and remove it cleanly; dm-zoned
     resyncs the sets. Do not use `dmzadm --repair` on the 2-device set (§8).
6. Sanity-check the old geometry:
   - `o_nr_map_blocks == ceil(o_nr_chunks/512)`.
   - `o_nr_bitmap_blocks == (Nc+Nz)*zbb`.
   - `o_nr_meta_blocks == 1 + map + bitmap`.
7. Read the tertiary SB at drive block 0. It must have the same `dmz_uuid`/label and
   `sb_block == Nc*zb`. Record its `dev_uuid` (the drive's UUID).
8. Load the map: `o_nr_map_blocks` blocks from `P_start + 1`, entries `0..o_nr_chunks-1`.
9. Bitmap of global zone g: `zbb` blocks at `P_start + 1 + o_nr_map_blocks + g*zbb`.

### (ii) Preconditions (abort if any fails)

Run a zone report of the drive (`blkzone report` or the BLKREPORTZONE ioctl). Compute `S`, the
first conventional zone, and the new geometry (iii). Then check all of the following:

1. No dzone or bzone in `[0, Nc)`: nothing is mapped to the cache. Every bzone_id is UNMAPPED.
   In the multi-device layout bzones are always cache zones, so a remaining bzone means the cache
   is not drained.
2. All cache-zone bitmaps are all-zero. This is optional but strongly recommended; it is a
   consistency check.
3. For each mapped dzone with old id `d`, compute `k = d - Nc`. `k` must not fall in the new
   metadata range `[S, S+2*n_m)`. `k` must not be 0 when 0 is outside that range: it was META
   before, so this should be impossible.
4. Every chunk `c >= n_nr_chunks` is UNMAPPED.
   - This is usually the **hard** condition, because the exposed capacity shrinks (see the note
     below).
   - The upper layer (LUKS, file system) must be shrunk to `<= n_nr_chunks*zone_bytes` first.
   - The tail chunks must then be unmapped, e.g. `blkdiscard -o <n_nr_chunks*zone_bytes>` on
     the old dm device. A full-chunk discard empties the zone, and `dmz_put_chunk_mapping`
     unmaps an inactive empty zone (`target.c`:357-390, `meta.c`:2137-2145).
   - Then flush and stop, and re-read.
5. The drive has `>= 2*n_m` contiguous usable conventional zones starting at S, and preferably
   many more. In single-device mode the remaining conventional zones are the *only* random/buffer
   zones. The kernel minimum is `nr_rnd_zones > n_m`. dmzadm wants `>= 3` conventional zones and
   `2*m <= conv`.
   - **UNVERIFIED for the HC680**: whether it has conventional zones at all, and how many and
     where. Check with `blkzone report /dev/sdX | grep -c CONVENTIONAL`. Without conventional
     zones a single-device dm-zoned target is impossible.
6. No offline or read-only zones inside `[S, S+2*n_m)`. Tool and kernel differ on S when a
   conventional zone is offline (section 2a). If any conventional zone is offline, stop.

**Capacity note.** `o_nr_chunks = (Nc + Uz) - 2*o_m - o_R`. `n_nr_chunks = Uz - 2*n_m - n_R`, where
Uz is the count of usable drive zones. The device therefore shrinks by about
`Nc - 2*(o_m - n_m) + (n_R - o_R)` zones, roughly **the size of the cache device**.

Worked example, computed with the tools' formula: 256 MiB zones, Nc = 4096, Nz = Uz = 100000,
R = 16.

| | m | nr_chunks |
|---|---|---|
| Old | 4 | 104072 |
| New | 4 | 99976 |

The difference is 4096 chunks, which is 1 TiB. `n_R` can be lowered to 1 to win back up to
15 zones. Both the kernel and `--check` accept that: `--check` uses the SB's R. It costs
reclaim headroom.

### (iii) New geometry and id translation

```
zbb       = max(1, zb >> 15)
n_bitmap  = Nz * zbb                                  # all drive zones incl. offline/runt
Uz        = #drive zones that are conventional (any cond)  +  #seq zones not RO/OFFLINE
            (tools count) — must equal the kernel's nr_useable_zones, i.e. no offline/RO
            conventional zones and no runt zone; otherwise counts diverge (see v)
C         = #conventional zones (dmzadm "cache" count, single-device)
n_R       = o_R (or chosen >= 1);  if n_R > C: n_R = C - 1
# replicate dmz_locate_metadata, then enforce the --check identity:
m = ceil((1 + ceil((Uz - ceil(n_bitmap/zb) - n_R)/512) + n_bitmap) / zb)   # m_est
loop:
    n_chunks = Uz - 2*m - n_R
    n_map    = ceil(n_chunks / 512)
    n_meta   = 1 + n_map + n_bitmap
    m2       = ceil(n_meta / zb)
    if m2 == m: break
    m = m2            # (normally never iterates; guards the edge case in section 6)
require 2*m <= C, m < nr_rnd_zones, 0 < n_R < Uz - m
S     = first conventional zone id;  set0_start = S*zb;  set1_start = (S+m)*zb
id_new(old_id) = old_id - Nc        for every mapped dzone id (and bzone id, which must be none)
```

`n_chunks` may be set *lower* than the formula. The kernel accepts that (check 8), but then
`dmzadm --check` fails on it. Prefer the exact formula and shrink the upper layer to fit.

### (iv) Build and write the two new sets on the drive (conventional zones, random writes OK)

1. **Back up** before writing:
   - Drive blocks `[S*zb, (S+2m)*zb)`, which covers the tertiary SB at block 0.
   - Both old metadata sets on the cache device. The old metadata stays untouched, which gives
     the rollback path.
2. **Map** (`n_map` blocks):
   - Start with all entries = `0xFFFFFFFF/0xFFFFFFFF`.
   - For c in `[0, n_chunks)`: if the old dzone `d != UNMAPPED`, write
     `dzone = le32(d - Nc)` and `bzone = 0xFFFFFFFF`.
3. **Bitmaps** (`n_bitmap` blocks):
   - All zero by default.
   - For each mapped old zone d, copy the `zbb` old blocks at
     `P_start + 1 + o_nr_map_blocks + d*zbb` to new offset `1 + n_map + (d-Nc)*zbb`.
   - Optionally clear bits at or above the zone WP for seq zones; `--check` would flag them.
4. **SB** (4096 bytes, zeroed):
   - `magic = 0x445A4244`, `version = 2`, `gen = G` (same G in both sets, e.g. `o_gen + 1`, or 1
     like format).
   - `sb_block`: `S*zb` for set 0 and `(S+m)*zb` for set 1.
   - `nr_meta_blocks = n_meta`, `nr_reserved_seq = n_R`, `nr_chunks = n_chunks`,
     `nr_map_blocks = n_map`, `nr_bitmap_blocks = n_bitmap`.
   - `dmz_label` = the old 32 bytes verbatim. `dmz_uuid` = the old value. `dev_uuid` = the
     tertiary SB's `dev_uuid` (any non-null value is accepted).
   - `crc = raw_crc32_le((u32)G, block with crc=0)`.
5. **Write order** (crash-safe):
   1. Set 1: map, bitmaps, then SB1.
   2. Set 0: map and bitmaps.
   3. fsync / flush.
   4. SB0, written **last**. When S = 0 this overwrites the tertiary SB.
   5. fsync.

   Until step 4 the old 2-device target is still loadable. Use 4 KiB-aligned `O_DIRECT` pwrites
   (`tools/dmz_dev.c`:777-809 does the same).
6. If drive zone 0 is outside `[S, S+2m)` and is a non-empty seq zone (old tertiary), reset it.
   Also reset every other unmapped non-empty seq zone (section 7).
7. Verify offline with `dmzadm --check /dev/zoned`. It must report "No error detected". Use
   `dmzadm --repair /dev/zoned` only for the WP and stray-bit class of issues.
8. Start with `dmzadm --start /dev/zoned` or `dmsetup create <label> --table "0 <n_chunks*zone_sectors> zoned /dev/zoned"`.
   Confirm the kernel log lines "DM-Zoned metadata version 2" and the target size.
9. Only after the upper layer verifies, invalidate the old cache metadata (zero cache blocks 0
   and `o_m*zb`). Starting the old 2-device target against the modified drive would corrupt it.

### (v) What could still make the kernel (or tools) reject it

- **Zone counting differences** between the tools' formula (`n_chunks`) and the kernel's
  `nr_useable_zones`:
  - Offline or read-only conventional zones: the tools count them as usable cache zones, the
    kernel does not.
  - A runt last zone: the tools count it, kernel v2 treats it as offline (`meta.c`:1358-1362).
  - In either case the kernel check `nr_chunks <= useable - 2m - R` can fail by the difference.
    Compute `n_chunks` from the kernel's count if they differ, and accept the `--check` mismatch.
- `nr_meta_zones >= nr_rnd_zones` (too few conventional zones), or any zone in `[S, S+2m)` that
  is not conventional.
- A mapped id `>= nr_zones` or a missing zone. A bzone that is not RND.
- CRC computed with the wrong seed or with inversion. Any non-zero byte in the region the CRC
  did not see: the CRC covers the full 4 KiB.
- Label differing in any of the 32 bytes between SB0 and SB1, or a null `dmz_uuid`/`dev_uuid`.
- `sb_block` not equal to `zone_id*zb` of the zone it sits in.
- `nr_map_blocks < ceil(nr_chunks/512)`. The kernel does not check this, and it overflows
  `map_mblk`, so it must be exact.
- Not kernel rejections, but silent damage:
  - A mapped zone inside the new metadata range: not checked, causes corruption.
  - Unmapped non-empty seq zones: reclaim `-EIO`.
  - Differing set contents: the log protocol assumes identical sets.

---

## UNVERIFIED / not confirmed from source

1. Whether the WD Ultrastar HC680 exposes conventional zones, and how many and where. This
   decides whether single-device mode is possible at all and how much random-write space
   remains. Check the live zone report.
2. Big-endian hosts: bitmap bit order would differ from the tools' byte-wise order. Only
   little-endian is verified, by equivalence of the two implementations.
3. `crc32_le` having no pre/post inversion is inferred from the tools' raw implementation (no
   inversion) plus the fact that tool-formatted devices load in the kernel. I did not read
   `lib/crc32.c` itself.
4. That `blkdiscard` of the tail on the old target actually unmaps every tail chunk. This
   follows from `dmz_handle_discard` and `dmz_put_chunk_mapping`. Chunks with a buffer zone, or
   zones under reclaim at that moment, may need another idle period. Re-check the map rather
   than assume.
5. Kernels older than the fetched master (e.g. the running 7.0.14-pve) were not diffed. The
   recent commits shown (c92d632f, 55c99f2d) are cosmetic, but whether 7.0.x matches master in
   these paths is unverified.
