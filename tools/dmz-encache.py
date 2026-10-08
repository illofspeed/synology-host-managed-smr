#!/usr/bin/env python3
"""dmz-encache: attach a cache device to a single-device dm-zoned drive WITHOUT reformatting
(the inverse of dmz-uncache). The drive's data zones stay where they are; only the metadata moves:

  plain layout:  metadata sets at the drive's first conventional zones S..S+2m-1, zone ids = drive zone
  cached layout: metadata sets on the cache device (blocks 0.. and m2*zb..), zone ids = Nc + drive zone,
                 tertiary superblock at drive block 0 (drive zone 0 becomes a META zone)

Steps: read + verify the plain metadata (SB0/SB1 identical) -> preconditions (drained: no buffer zones;
nothing mapped into the plain metadata zones) -> new geometry exactly as dmzadm's dmz_locate_metadata
for two devices -> write the cache metadata set 1, set 0 body, SB0 -> write the tertiary SB over the
plain SB0 -> zero the plain SB1 (so a single-device table can no longer "recover" the stale set) ->
verify everything by reading it back. The plain metadata zones are backed up first (rollback = restore
them; the 2-device table then fails because its tertiary SB is gone).

Device I/O is O_DIRECT. Requires: the target stopped, the drive's zone 0 conventional, the cache device
an exact multiple of the zone size with at least 2*m2+1 zones.
"""
import argparse, json, mmap, os, re, struct, subprocess, sys, uuid, zlib

BLK = 4096
MAGIC = 0x445A4244
UNMAPPED = 0xFFFFFFFF
SB_FMT = "<IIQQIIIIII32s16s16s"          # magic version gen sb_block nr_meta nr_resv nr_chunks nr_map nr_bitmap crc label dmz_uuid dev_uuid


def die(msg):
    print("ABORT: " + msg, file=sys.stderr)
    sys.exit(3)


def crc_raw(seed, data):
    """Reflected CRC-32 without pre/post inversion, seeded with the low 32 bits of gen (as dm-zoned)."""
    return (~zlib.crc32(data, (~seed) & 0xFFFFFFFF)) & 0xFFFFFFFF


def ceil(a, b):
    return -(-a // b)


def _abuf(n):
    if n % BLK:
        die("unaligned I/O size %d" % n)
    return mmap.mmap(-1, n)


def pread(fd, off, n):
    if off % BLK:
        die("unaligned read at %d" % off)
    buf = _abuf(n)
    if os.preadv(fd, [buf], off) != n:
        die("short read at %d" % off)
    return bytes(buf)


def pwrite(fd, data, off):
    if off % BLK:
        die("unaligned write at %d" % off)
    buf = _abuf(len(data))
    buf[:] = data
    if os.pwritev(fd, [buf], off) != len(data):
        die("short write at %d" % off)


def parse_sb(block):
    f = struct.unpack_from(SB_FMT, block, 0)
    sb = dict(zip(["magic", "version", "gen", "sb_block", "nr_meta_blocks", "nr_reserved_seq",
                   "nr_chunks", "nr_map_blocks", "nr_bitmap_blocks", "crc", "label", "dmz_uuid",
                   "dev_uuid"], f))
    if sb["magic"] != MAGIC:
        return None, "bad magic 0x%08x" % sb["magic"]
    if sb["version"] != 2:
        return None, "version %d (need 2)" % sb["version"]
    b = bytearray(block)
    b[44:48] = b"\0\0\0\0"
    if crc_raw(sb["gen"] & 0xFFFFFFFF, bytes(b)) != sb["crc"]:
        return None, "bad CRC"
    sb["label"] = sb["label"].split(b"\0", 1)[0].decode(errors="replace")
    return sb, None


def build_sb(gen, sb_block, nr_meta, nr_resv, nr_chunks, nr_map, nr_bitmap, label, dmz_uuid, dev_uuid):
    b = bytearray(BLK)
    struct.pack_into(SB_FMT, b, 0, MAGIC, 2, gen, sb_block, nr_meta, nr_resv, nr_chunks, nr_map,
                     nr_bitmap, 0, label, dmz_uuid, dev_uuid)
    struct.pack_into("<I", b, 44, crc_raw(gen & 0xFFFFFFFF, bytes(b)))
    return bytes(b)


def zone_report(dev):
    """blkzone report -> list of dicts (sectors; wp RELATIVE to the zone start as blkzone prints it)."""
    out = subprocess.run(["blkzone", "report", dev], capture_output=True, text=True, check=True).stdout
    rx = re.compile(r"start:\s*(0x[0-9a-f]+),\s*len\s*(0x[0-9a-f]+),(?:\s*cap\s*(0x[0-9a-f]+),)?\s*wptr\s*(0x[0-9a-f]+).*?zcond:\s*(\d+)\(([^)]*)\)\s*\[type:\s*(\d+)\(([^)]*)\)\]")
    zones = []
    for line in out.splitlines():
        m = rx.search(line)
        if m:
            zones.append({"start": int(m.group(1), 16), "len": int(m.group(2), 16), "wp": int(m.group(4), 16),
                          "cond": int(m.group(5)), "condname": m.group(6), "type": int(m.group(7))})
    if not zones:
        die("no zones reported for %s" % dev)
    return zones


def dev_size(dev):
    return int(subprocess.run(["blockdev", "--getsize64", dev], capture_output=True, text=True, check=True).stdout)


def holders(dev):
    name = os.path.basename(os.path.realpath(dev))
    p = "/sys/class/block/%s/holders" % name
    return os.listdir(p) if os.path.isdir(p) else []


def main():
    ap = argparse.ArgumentParser(description="attach a cache device to a plain dm-zoned drive (metadata move, no reformat)")
    ap.add_argument("--cache", required=True)
    ap.add_argument("--zoned", required=True)
    ap.add_argument("--backup-dir")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    for d in (a.cache, a.zoned):
        if not os.path.exists(d):
            die("%s does not exist" % d)
        h = holders(d)
        if h:
            if not a.dry_run:
                die("%s is in use by %s (stop the dm-zoned target first)" % (d, h))
            print("WARNING: %s is in use by %s - dry run reads a live snapshot" % (d, h))
        subprocess.run(["blockdev", "--flushbufs", d], check=True)

    # ---------- drive geometry ----------
    zr = zone_report(a.zoned)
    zsec = zr[0]["len"]
    if any(z["len"] != zsec for z in zr[:-1]):
        die("zones are not all the same size")
    zb = zsec // 8
    zbytes = zsec * 512
    zbb = max(1, zb >> 15)
    Nz = len(zr)
    CONV = 1
    conv = [k for k, z in enumerate(zr) if z["type"] == CONV]
    if [k for k, z in enumerate(zr) if z["condname"].lower() in ("ro", "ol", "offline", "read-only")]:
        die("offline/read-only zones present - zone counting would diverge")
    if not conv or conv[0] != 0:
        die("drive zone 0 must be conventional (it holds the plain SB0 now and the tertiary SB later)")
    S = 0
    csize = dev_size(a.cache)
    if csize % zbytes:
        die("cache device size %d is not a multiple of the zone size %d" % (csize, zbytes))
    Nc = csize // zbytes
    print("drive: %d zones of %d MiB, %d conventional; cache: %d zones" % (Nz, zbytes >> 20, len(conv), Nc))

    # ---------- plain metadata ----------
    zfd = os.open(a.zoned, os.O_RDONLY | os.O_DIRECT)
    sb0, e = parse_sb(pread(zfd, 0, BLK))
    if not sb0:
        die("plain SB0 at drive block 0: %s (is this drive really a single-device dm-zoned?)" % e)
    if sb0["sb_block"] != 0:
        die("SB0 sb_block %d != 0: this looks like a tertiary SB of an already cached layout" % sb0["sb_block"])
    m1 = ceil(sb0["nr_meta_blocks"], zb)
    sb1, e = parse_sb(pread(zfd, m1 * zbytes, BLK))
    if not sb1:
        die("plain SB1 at drive zone %d: %s" % (m1, e))
    if sb1["sb_block"] != m1 * zb:
        die("SB1 sb_block mismatch")
    if sb0["gen"] != sb1["gen"]:
        die("SB generations differ (%d/%d): start and cleanly remove the plain target once" % (sb0["gen"], sb1["gen"]))
    for k in ("nr_meta_blocks", "nr_reserved_seq", "nr_chunks", "nr_map_blocks", "nr_bitmap_blocks", "label", "dmz_uuid"):
        if sb0[k] != sb1[k]:
            die("SB0/SB1 differ in %s" % k)
    o = sb0
    if o["nr_map_blocks"] != ceil(o["nr_chunks"], 512) or o["nr_bitmap_blocks"] != Nz * zbb \
            or o["nr_meta_blocks"] != 1 + o["nr_map_blocks"] + o["nr_bitmap_blocks"]:
        die("plain geometry inconsistent with Nz=%d zbb=%d" % (Nz, zbb))
    meta_bytes = o["nr_meta_blocks"] * BLK
    s0 = pread(zfd, 0, meta_bytes)
    s1 = pread(zfd, m1 * zbytes, meta_bytes)
    if s0[BLK:] != s1[BLK:]:
        die("plain metadata sets 0 and 1 differ: start and cleanly remove the plain target once")
    print("plain: gen %d, chunks %d, map %d, bitmap %d, meta %d blocks (m=%d, zones 0..%d), reserved %d, label '%s'" % (
        o["gen"], o["nr_chunks"], o["nr_map_blocks"], o["nr_bitmap_blocks"], o["nr_meta_blocks"], m1, 2 * m1 - 1,
        o["nr_reserved_seq"], o["label"]))
    omap = [struct.unpack_from("<II", s0, BLK + c * 8) for c in range(o["nr_chunks"])]
    bm_off = BLK * (1 + o["nr_map_blocks"])
    old_bitmap = s0[bm_off: bm_off + o["nr_bitmap_blocks"] * BLK]
    plain_meta_zones = set(range(0, 2 * m1))

    # ---------- preconditions ----------
    problems, used = [], {}
    for c, (d, b) in enumerate(omap):
        if d == UNMAPPED:
            if b != UNMAPPED:
                problems.append("chunk %d unmapped but has buffer zone %d" % (c, b))
            continue
        if b != UNMAPPED:
            problems.append("chunk %d has buffer zone %d (drain first: start the plain target, 'dmsetup message <t> 0 reclaim', wait until 0 chunks are buffered)" % (c, b))
        if d >= Nz:
            problems.append("chunk %d mapped to zone %d beyond the drive" % (c, d))
        elif d in plain_meta_zones:
            problems.append("chunk %d mapped to plain metadata zone %d" % (c, d))
        if d in used:
            problems.append("zone %d mapped by chunks %d and %d" % (d, used[d], c))
        used[d] = c
    if problems:
        for p in problems[:20]:
            print("  - " + p)
        die("%d precondition(s) failed" % len(problems))
    nonempty_unmapped_seq = [k for k, z in enumerate(zr) if z["type"] != CONV and k not in used and z["wp"] != 0]

    # ---------- two-device geometry (dmz_locate_metadata with nr_bdev > 1) ----------
    U = Nc + Nz
    R = o["nr_reserved_seq"]
    if R > Nc:
        R = Nc - 1
    n_bitmap = U * zbb
    m = ceil(1 + ceil(U - ceil(n_bitmap, zb) - R, 512) + n_bitmap, zb)
    for _ in range(10):
        n_chunks = U - 2 * m - R
        n_map = ceil(n_chunks, 512)
        n_meta = 1 + n_map + n_bitmap
        m2 = ceil(n_meta, zb)
        if m2 == m:
            break
        m = m2
    else:
        die("geometry did not converge")
    if Nc < 3 or 2 * m > Nc or 2 * m + 1 > Nc:
        die("cache device too small: %d zones, need at least %d" % (Nc, 2 * m + 1))
    print("cached: chunks %d, map %d, bitmap %d, meta %d blocks (m=%d, cache zones 0..%d), reserved %d; target size %d sectors (+%d)" % (
        n_chunks, n_map, n_bitmap, n_meta, m, 2 * m - 1, R, n_chunks * zsec, (n_chunks - o["nr_chunks"]) * zsec))
    print("mapped chunks: %d (all zone ids shift by +%d); unmapped non-empty sequential zones to reset: %d" % (
        len(used), Nc, len(nonempty_unmapped_seq)))

    # ---------- build the new set ----------
    newmap = bytearray(b"\xff" * (n_map * BLK))
    for c, (d, b) in enumerate(omap):
        if d != UNMAPPED:
            struct.pack_into("<II", newmap, c * 8, d + Nc, UNMAPPED)
    newbm = bytes(Nc * zbb * BLK) + old_bitmap
    if len(newbm) != n_bitmap * BLK:
        die("internal: bitmap size")
    body = bytes(newmap) + newbm
    gen = o["gen"] + 1
    cache_uuid = uuid.uuid4().bytes
    sbs = [build_sb(gen, i * m * zb, n_meta, R, n_chunks, n_map, n_bitmap, o["label"].encode(), o["dmz_uuid"], cache_uuid)
           for i in (0, 1)]
    tert = build_sb(0, Nc * zb, n_meta, R, n_chunks, n_map, n_bitmap, o["label"].encode(), o["dmz_uuid"], o["dev_uuid"])
    table = "0 %d zoned %s %s" % (n_chunks * zsec, a.cache, a.zoned)
    if a.dry_run:
        print("DRY RUN: nothing written; table afterwards: %s" % table)
        return
    if not a.backup_dir:
        die("--backup-dir is required for a real run")
    os.makedirs(a.backup_dir, exist_ok=True)
    os.close(zfd)
    zfd = os.open(a.zoned, os.O_RDWR | os.O_DIRECT)
    cfd = os.open(a.cache, os.O_RDWR | os.O_DIRECT)

    # ---------- backups ----------
    with open(os.path.join(a.backup_dir, "drive-zones-0-%d.bin" % (2 * m1 - 1)), "wb") as f:
        for k in range(2 * m1):
            f.write(pread(zfd, k * zbytes, zbytes))
    with open(os.path.join(a.backup_dir, "cache-first-blocks.bin"), "wb") as f:   # old SBs of the cache device, if any
        f.write(pread(cfd, 0, BLK))
        f.write(pread(cfd, m * zbytes, BLK))
    json.dump({"Nc": Nc, "Nz": Nz, "zb": zb, "m_plain": m1, "m_cached": m, "plain_gen": o["gen"], "new_gen": gen,
               "n_chunks": n_chunks, "table": table, "cache_uuid": cache_uuid.hex(), "drive_uuid": o["dev_uuid"].hex()},
              open(os.path.join(a.backup_dir, "plan.json"), "w"), indent=1)
    print("backups written to %s" % a.backup_dir)

    # ---------- write: cache set 1, set 0 body, SB0; then the tertiary SB; then kill the plain SB1 ----------
    pwrite(cfd, body, m * zbytes + BLK)
    pwrite(cfd, sbs[1], m * zbytes)
    os.fsync(cfd)
    pwrite(cfd, body, BLK)
    os.fsync(cfd)
    pwrite(cfd, sbs[0], 0)
    os.fsync(cfd)
    for i in (0, 1):
        chk, err = parse_sb(pread(cfd, i * m * zbytes, BLK))
        if not chk or pread(cfd, i * m * zbytes + BLK, len(body)) != body:
            die("verify of cache set %d failed: %s (drive untouched so far)" % (i, err))
    print("cache metadata written: gen %d, sets at cache zones 0 and %d" % (gen, m))
    pwrite(zfd, tert, 0)
    os.fsync(zfd)
    pwrite(zfd, bytes(BLK), m1 * zbytes)
    os.fsync(zfd)
    chk, err = parse_sb(pread(zfd, 0, BLK))
    if not chk or chk["sb_block"] != Nc * zb or pread(zfd, m1 * zbytes, BLK) != bytes(BLK):
        die("verify of the tertiary SB / plain SB1 wipe failed: %s" % err)
    print("tertiary SB written at drive block 0 (sb_block %d), plain SB1 zeroed" % (Nc * zb))
    os.close(zfd)
    os.close(cfd)
    for k in nonempty_unmapped_seq:
        subprocess.run(["blkzone", "reset", "-o", str(zr[k]["start"]), "-c", "1", a.zoned], check=True)
    print("reset %d unmapped non-empty sequential zones" % len(nonempty_unmapped_seq))
    print("next: dmsetup create <name> --table \"%s\"   (then read the data back; dmzadm --check on 2-device sets segfaults in 2.2.2)" % table)
    print("rollback (before the cached target has been used): restore drive zones 0..%d from the backup" % (2 * m1 - 1))


if __name__ == "__main__":
    main()
