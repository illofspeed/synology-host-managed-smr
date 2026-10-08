#!/usr/bin/env python3
"""dmz-metaset: inspect or repair the two metadata sets of a SINGLE-device dm-zoned drive by hand.

  dmz-metaset --zoned DEV                      show both superblocks and whether the set bodies match
  dmz-metaset --zoned DEV --copy 1 [--force]   copy the body (map + bitmaps) of set 1 over set 0 and
                                               give both superblocks the same, newest generation
  dmz-metaset --zoned DEV --copy 0 [--force]   the other direction

Why: when `dmzadm --check` reports invalid chunk mappings in the PRIMARY set while the secondary set is
intact (same generation), the kernel refuses the target (good) but `dmzadm --repair` "repairs" the primary
by unmapping the affected chunks, resets their zones and then syncs that over the intact secondary set
(= data loss; lab drill 2026-10-03). The right move is to copy the intact set over the damaged one.
Each superblock keeps its own sb_block (set 1's superblock position differs), so a plain dd of the whole
set would leave a wrong sb_block; this tool rewrites the superblocks properly. O_DIRECT, target stopped.
Caveat: when the generations differ, the kernel takes the newer set; this tool refuses to copy an older set
over a newer one unless --force (you must know that the older one is the good one, e.g. after a failed
repair that bumped the generation of the damaged copy).
"""
import argparse, mmap, os, struct, subprocess, sys, zlib

BLK = 4096
MAGIC = 0x445A4244
SB_FMT = "<IIQQIIIIII32s16s16s"


def die(m):
    print("ABORT: " + m, file=sys.stderr)
    sys.exit(3)


def crc_raw(seed, data):
    return (~zlib.crc32(data, (~seed) & 0xFFFFFFFF)) & 0xFFFFFFFF


def _abuf(n):
    if n % BLK:
        die("unaligned size %d" % n)
    return mmap.mmap(-1, n)


def pread(fd, off, n):
    buf = _abuf(n)
    if os.preadv(fd, [buf], off) != n:
        die("short read at %d" % off)
    return bytes(buf)


def pwrite(fd, data, off):
    buf = _abuf(len(data))
    buf[:] = data
    if os.pwritev(fd, [buf], off) != len(data):
        die("short write at %d" % off)


def parse_sb(block):
    f = struct.unpack_from(SB_FMT, block, 0)
    sb = dict(zip(["magic", "version", "gen", "sb_block", "nr_meta_blocks", "nr_reserved_seq", "nr_chunks",
                   "nr_map_blocks", "nr_bitmap_blocks", "crc", "label", "dmz_uuid", "dev_uuid"], f))
    if sb["magic"] != MAGIC:
        return None, "bad magic"
    if sb["version"] != 2:
        return None, "version %d" % sb["version"]
    b = bytearray(block)
    b[44:48] = b"\0\0\0\0"
    if crc_raw(sb["gen"] & 0xFFFFFFFF, bytes(b)) != sb["crc"]:
        return None, "bad CRC"
    return sb, None


def rewrite_sb(block, gen, sb_block):
    b = bytearray(block)
    struct.pack_into("<Q", b, 8, gen)
    struct.pack_into("<Q", b, 16, sb_block)
    b[44:48] = b"\0\0\0\0"
    struct.pack_into("<I", b, 44, crc_raw(gen & 0xFFFFFFFF, bytes(b)))
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zoned", required=True)
    ap.add_argument("--copy", type=int, choices=[0, 1], help="source set to copy over the other one")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    name = os.path.basename(os.path.realpath(a.zoned))
    hp = "/sys/class/block/%s/holders" % name
    if os.path.isdir(hp) and os.listdir(hp):
        die("%s is in use by %s" % (a.zoned, os.listdir(hp)))
    subprocess.run(["blockdev", "--flushbufs", a.zoned], check=True)
    rep = subprocess.run(["blkzone", "report", "-c", "1", a.zoned], capture_output=True, text=True, check=True).stdout
    zsec = int(rep.split("len")[1].split(",")[0].strip(), 16)
    zb = zsec // 8
    zbytes = zsec * 512
    fd = os.open(a.zoned, os.O_RDWR | os.O_DIRECT)
    sb0, e0 = parse_sb(pread(fd, 0, BLK))
    # set 1 position comes from whichever superblock is readable
    if sb0:
        m = -(-sb0["nr_meta_blocks"] // zb)
    else:
        m = None
        for k in range(1, 64):
            s, _ = parse_sb(pread(fd, k * zbytes, BLK))
            if s and s["sb_block"] == k * zb:
                m = k
                break
        if m is None:
            die("SB0 unreadable (%s) and no secondary superblock found in zones 1..63" % e0)
    sb1, e1 = parse_sb(pread(fd, m * zbytes, BLK))
    for i, (sb, e) in enumerate(((sb0, e0), (sb1, e1))):
        if sb:
            print("set %d: gen %d, sb_block %d, chunks %d, map %d, bitmap %d, meta %d" % (
                i, sb["gen"], sb["sb_block"], sb["nr_chunks"], sb["nr_map_blocks"], sb["nr_bitmap_blocks"], sb["nr_meta_blocks"]))
        else:
            print("set %d: superblock invalid (%s)" % (i, e))
    good = sb0 or sb1
    n = good["nr_meta_blocks"]
    body = [pread(fd, i * m * zbytes + BLK, (n - 1) * BLK) for i in (0, 1)]
    print("set bodies (map + bitmaps, %d blocks): %s" % (n - 1, "identical" if body[0] == body[1] else "DIFFER"))
    if a.copy is None:
        return
    src, dst = a.copy, 1 - a.copy
    ssb = (sb0, sb1)[src]
    dsb = (sb0, sb1)[dst]
    if not ssb:
        die("source set %d has no valid superblock" % src)
    if dsb and dsb["gen"] > ssb["gen"] and not a.force:
        die("destination set %d is NEWER (gen %d > %d): the kernel would prefer it; use --force only if you know set %d is the good one" % (
            dst, dsb["gen"], ssb["gen"], src))
    gen = max(ssb["gen"], dsb["gen"] if dsb else 0)
    sb_block = [0, m * zb]
    pwrite(fd, body[src], dst * m * zbytes + BLK)
    os.fsync(fd)
    pwrite(fd, rewrite_sb(pread(fd, src * m * zbytes, BLK), gen, sb_block[dst]), dst * m * zbytes)
    pwrite(fd, rewrite_sb(pread(fd, src * m * zbytes, BLK), gen, sb_block[src]), src * m * zbytes)
    os.fsync(fd)
    for i in (0, 1):
        chk, e = parse_sb(pread(fd, i * m * zbytes, BLK))
        if not chk or chk["gen"] != gen or chk["sb_block"] != sb_block[i]:
            die("verify of set %d superblock failed: %s" % (i, e))
    if pread(fd, dst * m * zbytes + BLK, (n - 1) * BLK) != body[src]:
        die("verify of the copied body failed")
    print("set %d copied over set %d; both superblocks at gen %d. Next: dmzadm --check %s" % (src, dst, gen, a.zoned))


if __name__ == "__main__":
    main()
