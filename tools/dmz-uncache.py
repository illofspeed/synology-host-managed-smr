#!/usr/bin/env python3
"""dmz-uncache: convert a two-device dm-zoned target (regular cache device + one host-managed
zoned drive, formatted with `dmzadm --format <cache> <zoned>`) into a single-device dm-zoned
target on the zoned drive alone, preserving the chunk -> zone mapping and the valid-block bitmaps.

OFFLINE ONLY: the dm-zoned target must be stopped (dmsetup remove) and nothing may hold either
device. Spec and source citations: dmz-cache-layout-SPEC.md next to this file (kernel dm-zoned-metadata.c v2 +
dm-zoned-tools 2.2.2). Tested: lab (emulated ZBC drives) and one real 27 TB member (2026-10-03, and four more
conversions on 2026-10-08); see docs/09.

Steps: read+verify old metadata (cache SB0/SB1, tertiary SB on the drive) -> preconditions ->
plan relocation of mapped zones out of the new metadata zones -> [--dry-run stops here] ->
backups -> relocate (zone copy conv->conv) -> write set 1, set 0 (SB0 last) -> reset unmapped
non-empty sequential zones -> print the dmsetup table for the single-device target.
"""
import argparse, json, mmap, os, re, struct, subprocess, sys, zlib

BLK = 4096
RESYNC_HINT = ("start and cleanly remove the 2-device target once so dm-zoned resyncs the sets; do not use dmzadm --check/--repair on a 2-device set, it segfaults on chunks in drive conventional zones")
MAGIC = 0x445A4244
UNMAPPED = 0xFFFFFFFF
SB_FMT = "<IIQQIIIIII32s16s16s"          # magic version gen sb_block nr_meta nr_resv nr_chunks nr_map nr_bitmap crc label dmz_uuid dev_uuid
SB_SIZE = struct.calcsize(SB_FMT)       # 112


def die(msg, code=3):
    print("ABORT: " + msg, file=sys.stderr)
    sys.exit(code)


def crc_raw(seed, data):
    """Reflected CRC-32 (0xEDB88320) without pre/post inversion, as dm-zoned uses (SPEC 1)."""
    return (~zlib.crc32(data, (~seed) & 0xFFFFFFFF)) & 0xFFFFFFFF


def ceil(a, b):
    return -(-a // b)


def _abuf(n):
    if off_bad(n):
        die("unaligned I/O size %d" % n)
    return mmap.mmap(-1, n)                             # page-aligned, as O_DIRECT needs


def off_bad(x):
    return x % BLK != 0


def pread(fd, off, n):
    """O_DIRECT read: always from the device, never from a stale page cache."""
    if off_bad(off):
        die("unaligned read at %d" % off)
    buf = _abuf(n)
    if os.preadv(fd, [buf], off) != n:
        die("short read at %d" % off)
    return bytes(buf)


def pwrite(fd, data, off):
    if off_bad(off):
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
        return None, "bad magic %#x" % sb["magic"]
    if sb["version"] != 2:
        return None, "version %d (only 2 supported)" % sb["version"]
    b = bytearray(block)
    b[44:48] = b"\0\0\0\0"
    c = crc_raw(sb["gen"] & 0xFFFFFFFF, bytes(b))
    if c != sb["crc"]:
        return None, "crc mismatch (stored %#x, computed %#x)" % (sb["crc"], c)
    return sb, None


def build_sb(gen, sb_block, nr_meta, nr_resv, nr_chunks, nr_map, nr_bitmap, label, dmz_uuid, dev_uuid):
    b = bytearray(BLK)
    struct.pack_into(SB_FMT, b, 0, MAGIC, 2, gen, sb_block, nr_meta, nr_resv, nr_chunks, nr_map,
                     nr_bitmap, 0, label, dmz_uuid, dev_uuid)
    crc = crc_raw(gen & 0xFFFFFFFF, bytes(b))
    struct.pack_into("<I", b, 44, crc)
    return bytes(b)


def zone_report(dev):
    """blkzone report -> list of dicts (start/len in 512 B sectors; wp RELATIVE to the zone start,
    as blkzone prints it: 0 = empty, len = full)."""
    out = subprocess.run(["blkzone", "report", dev], capture_output=True, text=True, check=True).stdout
    zones = []
    rx = re.compile(r"start:\s*(0x[0-9a-f]+),\s*len\s*(0x[0-9a-f]+),(?:\s*cap\s*(0x[0-9a-f]+),)?\s*wptr\s*(0x[0-9a-f]+).*?zcond:\s*(\d+)\(([^)]*)\)\s*\[type:\s*(\d+)\(([^)]*)\)\]")
    for line in out.splitlines():
        m = rx.search(line)
        if not m:
            continue
        start, ln, cap, wp = (int(m.group(i), 16) if m.group(i) else None for i in (1, 2, 3, 4))
        zones.append({"start": start, "len": ln, "cap": cap if cap is not None else ln,
                      "wp": wp, "cond": int(m.group(5)), "condname": m.group(6),
                      "type": int(m.group(7)), "typename": m.group(8)})
    if not zones:
        die("no zones parsed from blkzone report %s" % dev)
    return zones


def dev_size(dev):
    return int(subprocess.run(["blockdev", "--getsize64", dev], capture_output=True, text=True, check=True).stdout)


def holders(dev):
    name = os.path.basename(os.path.realpath(dev))
    p = "/sys/class/block/%s/holders" % name
    return os.listdir(p) if os.path.isdir(p) else []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache", required=True, help="regular cache device of the 2-device target")
    ap.add_argument("--zoned", required=True, help="host-managed zoned drive")
    ap.add_argument("--backup-dir", help="where to save old metadata + overwritten drive zones (required unless --dry-run)")
    ap.add_argument("--dry-run", action="store_true", help="read, check and plan only; write nothing")
    ap.add_argument("--reserved-seq", type=int, help="new nr_reserved_seq (default: keep the old value)")
    a = ap.parse_args()

    for d in (a.cache, a.zoned):
        if holders(d):
            if not a.dry_run:
                die("%s is in use by %s - stop the dm-zoned target first" % (d, holders(d)))
            print("WARNING: %s is in use by %s - dry run reads a live snapshot" % (d, holders(d)))
        # The page cache of a block device can still hold blocks written through it earlier
        # (e.g. by dmzadm --format) while dm-zoned wrote past it: drop it before reading.
        subprocess.run(["blockdev", "--flushbufs", d], check=True)

    # ---------- geometry of the devices ----------
    zr = zone_report(a.zoned)
    zsec = zr[0]["len"]
    if any(z["len"] != zsec for z in zr[:-1]):
        die("zone sizes differ")
    if zr[-1]["len"] != zsec:
        die("runt last zone: kernel and tools count usable zones differently (SPEC 10.v)")
    if any(z["cap"] != z["len"] for z in zr):
        die("zone capacity < zone length: not supported by dm-zoned")
    zb = zsec // 8                                     # zone size in 4 KiB blocks
    zbytes = zsec * 512
    zbb = max(1, zb >> 15)
    Nz = len(zr)
    Nc = ceil(dev_size(a.cache), zbytes)
    CONV, SWR, SWP = 1, 2, 3
    conv = [k for k, z in enumerate(zr) if z["type"] == CONV]
    bad = [k for k, z in enumerate(zr) if z["condname"].lower() in ("ro", "ol", "offline", "read-only")]
    if bad:
        die("offline/read-only zones present (%s...) - counting would diverge" % bad[:5])
    if not conv:
        die("the zoned drive has no conventional zones: single-device dm-zoned is impossible")
    S = conv[0]
    print("drive: %d zones of %d MiB, %d conventional (first %d), cache: %d zones" % (Nz, zbytes >> 20, len(conv), S, Nc))

    # ---------- old metadata ----------
    cfd = os.open(a.cache, os.O_RDONLY | os.O_DIRECT)
    zfd = os.open(a.zoned, os.O_RDONLY | os.O_DIRECT)
    sb0, e0 = parse_sb(pread(cfd, 0, BLK))
    if not sb0:
        die("cache SB0: " + e0)
    if sb0["sb_block"] != 0:
        die("cache SB0 sb_block %d != 0" % sb0["sb_block"])
    o_m = ceil(sb0["nr_meta_blocks"], zb)
    sb1, e1 = parse_sb(pread(cfd, o_m * zb * BLK, BLK))
    if not sb1:
        die("cache SB1: " + e1 + " (" + RESYNC_HINT + ")")
    if sb1["sb_block"] != o_m * zb:
        die("cache SB1 sb_block mismatch")
    if sb0["gen"] != sb1["gen"]:
        if not a.dry_run:
            die("SB generations differ (%d/%d): %s" % (sb0["gen"], sb1["gen"], RESYNC_HINT))
        print("WARNING: SB generations differ (%d/%d) - live target mid-flush; previewing the newer set" % (sb0["gen"], sb1["gen"]))
    for k in ("nr_meta_blocks", "nr_reserved_seq", "nr_chunks", "nr_map_blocks", "nr_bitmap_blocks", "label", "dmz_uuid"):
        if sb0[k] != sb1[k]:
            die("SB0/SB1 differ in %s" % k)
    o = sb0
    if o["nr_map_blocks"] != ceil(o["nr_chunks"], 512) or o["nr_bitmap_blocks"] != (Nc + Nz) * zbb \
            or o["nr_meta_blocks"] != 1 + o["nr_map_blocks"] + o["nr_bitmap_blocks"]:
        die("old geometry inconsistent with Nc=%d Nz=%d zbb=%d" % (Nc, Nz, zbb))
    # sets must be byte-identical (log protocol assumes it)
    meta_bytes = o["nr_meta_blocks"] * BLK
    s0 = pread(cfd, 0, meta_bytes)
    s1 = pread(cfd, o_m * zb * BLK, meta_bytes)
    if s0[BLK:] != s1[BLK:]:
        if not a.dry_run:
            die("metadata sets 0 and 1 differ: " + RESYNC_HINT)
        print("WARNING: metadata sets differ - live target; previewing the newer set")
        if sb1["gen"] > sb0["gen"]:
            s0 = s1
    t, et = parse_sb(pread(zfd, 0, BLK))
    if not t:
        die("tertiary SB on the drive: " + et)
    if t["dmz_uuid"] != o["dmz_uuid"] or t["label"] != o["label"] or t["sb_block"] != Nc * zb:
        die("tertiary SB does not belong to this target")
    print("old: gen %d, chunks %d, map %d, bitmap %d, meta %d blocks (m=%d), reserved %d, label %r" % (
        o["gen"], o["nr_chunks"], o["nr_map_blocks"], o["nr_bitmap_blocks"], o["nr_meta_blocks"], o_m,
        o["nr_reserved_seq"], o["label"].rstrip(b"\0").decode(errors="replace")))

    omap = []
    mb = s0[BLK:BLK * (1 + o["nr_map_blocks"])]
    for c in range(o["nr_chunks"]):
        omap.append(struct.unpack_from("<II", mb, c * 8))
    bm_off = BLK * (1 + o["nr_map_blocks"])

    def old_bitmap(g):
        return s0[bm_off + g * zbb * BLK: bm_off + (g + 1) * zbb * BLK]

    # ---------- new geometry (replicates dmz_locate_metadata, then the --check identity) ----------
    C = len(conv)
    Uz = Nz
    n_R = a.reserved_seq if a.reserved_seq else o["nr_reserved_seq"]
    if n_R > C:
        n_R = C - 1
    n_bitmap = Nz * zbb
    m = ceil(1 + ceil(Uz - ceil(n_bitmap, zb) - n_R, 512) + n_bitmap, zb)
    for _ in range(10):
        n_chunks = Uz - 2 * m - n_R
        n_map = ceil(n_chunks, 512)
        n_meta = 1 + n_map + n_bitmap
        m2 = ceil(n_meta, zb)
        if m2 == m:
            break
        m = m2
    else:
        die("geometry did not converge")
    if not (2 * m <= C and m < C and 0 < n_R < Uz - m):
        die("geometry infeasible: m=%d C=%d R=%d" % (m, C, n_R))
    if conv[:2 * m] != list(range(S, S + 2 * m)):
        die("the first %d conventional zones are not contiguous from %d" % (2 * m, S))
    meta_zones = set(range(S, S + 2 * m))
    print("new: chunks %d, map %d, bitmap %d, meta %d blocks (m=%d, zones %d..%d), reserved %d" % (
        n_chunks, n_map, n_bitmap, n_meta, m, S, S + 2 * m - 1, n_R))

    # ---------- preconditions ----------
    mapped = {}                                       # drive zone k -> chunk
    problems = []
    emptied = []                                      # (chunk, drive zone) mapped with 0 valid blocks
    for c, (d, b) in enumerate(omap):
        if b != UNMAPPED:
            problems.append("chunk %d has a buffer zone %d (cache not drained)" % (c, b))
        if d == UNMAPPED:
            continue
        if d < Nc:
            problems.append("chunk %d mapped to cache zone %d (cache not drained)" % (c, d))
            continue
        k = d - Nc
        if k >= Nz:
            problems.append("chunk %d mapped to zone id %d beyond the drive" % (c, d))
            continue
        if not any(old_bitmap(d)):
            # A mapped zone without a single valid block reads as zeros, exactly like an unmapped
            # chunk. dm-zoned leaves such zones mapped after discards; drop the mapping here.
            emptied.append((c, k))
            continue
        if c >= n_chunks:
            problems.append("chunk %d >= new nr_chunks %d is still mapped (shrink/discard the tail)" % (c, n_chunks))
        if k in mapped:
            problems.append("zone %d mapped by chunks %d and %d" % (k, mapped[k], c))
        mapped[k] = c
    for g in range(Nc):
        if any(old_bitmap(g)):
            problems.append("cache zone %d has valid bits (cache not drained)" % g)
            break
    if problems:
        for p in problems[:20]:
            print("  - " + p)
        if not a.dry_run:
            die("%d precondition(s) failed" % len(problems))
        print("PREVIEW: %d precondition(s) failed; the plan below ignores chunks still in the cache" % len(problems))
    # relocation plan (applied later): (src zone, dst zone)
    reloc = []
    free_conv = [k for k in conv if k not in mapped and k not in meta_zones and k != 0]
    # a) mapped conventional zones inside the new metadata range -> free conventional zones
    for k in sorted(meta_zones):
        if k in mapped:
            if zr[k]["type"] != CONV:
                die("mapped zone %d in the metadata range is not conventional" % k)
            if not free_conv:
                die("no free conventional zone to relocate zone %d (trim first)" % k)
            reloc.append((k, free_conv.pop(0)))
    # b) the single-device layout needs n_R unmapped sequential zones as its reclaim reserve:
    #    move the emptiest mapped sequential zones into free conventional zones if necessary
    def weight(k):
        return int.from_bytes(old_bitmap(k + Nc), "little").bit_count()
    seq_free = [k for k, z in enumerate(zr) if z["type"] != CONV and k not in mapped]
    short = n_R - len(seq_free)
    if short > 0:
        cand = sorted((k for k in mapped if zr[k]["type"] != CONV), key=weight)[:short]
        if len(cand) < short or len(free_conv) < short:
            die("cannot free %d sequential zones for the reserve: %d free conventional zones left (trim first)" % (short, len(free_conv)))
        for k in cand:
            reloc.append((k, free_conv.pop(0)))
    final = dict(mapped)
    for src, dst in reloc:
        final[dst] = final.pop(src)
    seq_unmapped_final = [k for k, z in enumerate(zr) if z["type"] != CONV and k not in final]
    if len(seq_unmapped_final) < n_R:
        die("internal: reserve still short after planning")
    nonempty_unmapped_seq = [k for k in seq_unmapped_final if zr[k]["wp"] != 0]
    print("chunks mapped with 0 valid blocks, to be unmapped: %d" % len(emptied))
    print("mapped zones: %d (%d conventional), unmapped seq now %d / after plan %d (reserve %d), free conventional left %d" % (
        len(mapped), sum(1 for k in mapped if zr[k]["type"] == CONV), len(seq_free), len(seq_unmapped_final), n_R, len(free_conv)))
    print("relocations: %s" % (", ".join("%d->%d" % r for r in reloc) or "none"))
    print("unmapped non-empty sequential zones to reset: %d %s" % (len(nonempty_unmapped_seq), nonempty_unmapped_seq[:10]))
    if a.dry_run:
        print("DRY RUN: nothing written" + (" (preconditions FAILED, see above)" if problems else ""))
        return

    if not a.backup_dir:
        die("--backup-dir is required for a real run")
    os.makedirs(a.backup_dir, exist_ok=True)
    os.close(zfd)
    zfd = os.open(a.zoned, os.O_RDWR | os.O_DIRECT)

    # ---------- backups ----------
    with open(os.path.join(a.backup_dir, "cache-meta-set0.bin"), "wb") as f:
        f.write(s0)
    with open(os.path.join(a.backup_dir, "cache-meta-set1.bin"), "wb") as f:
        f.write(s1)
    with open(os.path.join(a.backup_dir, "drive-zones-%d-%d.bin" % (S, S + 2 * m - 1)), "wb") as f:
        for k in range(S, S + 2 * m):
            f.write(pread(zfd, zr[k]["start"] * 512, zbytes))
    json.dump({"Nc": Nc, "Nz": Nz, "zb": zb, "S": S, "m": m, "relocations": reloc,
               "old_gen": o["gen"], "tertiary_dev_uuid": t["dev_uuid"].hex()},
              open(os.path.join(a.backup_dir, "plan.json"), "w"), indent=1)
    print("backups written to %s" % a.backup_dir)

    # ---------- relocate ----------
    wp_limit = {}                                          # dst zone -> valid blocks limit (seq sources)
    for src, dst in reloc:
        n = zbytes if zr[src]["type"] == CONV else zr[src]["wp"] * 512
        if zr[src]["type"] != CONV:
            wp_limit[dst] = n // BLK
        data = pread(zfd, zr[src]["start"] * 512, n) if n else b""
        if n:
            pwrite(zfd, data, zr[dst]["start"] * 512)
        os.fsync(zfd)
        if n and pread(zfd, zr[dst]["start"] * 512, n) != data:
            die("relocation %d->%d verify failed" % (src, dst))
        c = mapped.pop(src)
        mapped[dst] = c
        print("relocated chunk %d: zone %d -> %d" % (c, src, dst))
    zone_of_reloc = {dst: src for src, dst in reloc}       # new zone -> old zone (for the bitmap)

    # ---------- build the new set ----------
    newmap = bytearray(b"\xff" * (n_map * BLK))
    for k, c in mapped.items():
        struct.pack_into("<II", newmap, c * 8, k, UNMAPPED)
    newbm = bytearray(n_bitmap * BLK)
    for k in mapped:
        oldk = zone_of_reloc.get(k, k)
        bm = bytearray(old_bitmap(oldk + Nc))
        lim = wp_limit.get(k)
        if lim is not None and lim < zb:                  # moved from a seq zone: nothing valid at/after its wp
            for b in range(lim, zb):
                bm[b >> 3] &= ~(1 << (b & 7)) & 0xFF
        newbm[k * zbb * BLK:(k + 1) * zbb * BLK] = bytes(bm)
    gen = o["gen"] + 1
    body = bytes(newmap) + bytes(newbm)
    sbs = [build_sb(gen, (S + i * m) * zb, n_meta, n_R, n_chunks, n_map, n_bitmap, o["label"], o["dmz_uuid"], t["dev_uuid"])
           for i in (0, 1)]
    set_off = [zr[S]["start"] * 512, zr[S + m]["start"] * 512]

    # set 1 complete, then set 0 body, SB0 last (the old 2-device target stays loadable until then)
    pwrite(zfd, body, set_off[1] + BLK)
    pwrite(zfd, sbs[1], set_off[1])
    os.fsync(zfd)
    pwrite(zfd, body, set_off[0] + BLK)
    os.fsync(zfd)
    pwrite(zfd, sbs[0], set_off[0])
    os.fsync(zfd)
    for i in (0, 1):
        chk, err = parse_sb(pread(zfd, set_off[i], BLK))
        if not chk or pread(zfd, set_off[i] + BLK, len(body)) != body:
            die("verify of new set %d failed: %s" % (i, err))
    print("new metadata written: gen %d, sets at drive zones %d and %d" % (gen, S, S + m))
    os.close(zfd)
    os.close(cfd)

    # ---------- reset unmapped non-empty sequential zones ----------
    for k in nonempty_unmapped_seq:
        subprocess.run(["blkzone", "reset", "-o", str(zr[k]["start"]), "-c", "1", a.zoned], check=True)
    print("reset %d unmapped non-empty sequential zones" % len(nonempty_unmapped_seq))
    print("next: dmzadm --check %s ; dmsetup create <name> --table \"0 %d zoned %s\"" % (a.zoned, n_chunks * zsec, a.zoned))
    print("old cache metadata left untouched (rollback: restore the drive-zones backup, start the 2-device target)")


if __name__ == "__main__":
    main()
