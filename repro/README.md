# Reproducers (no host-managed drives needed)

Each script builds a small RAM-backed host-managed SCSI disk with `scsi_debug` (32 zones of 64 MiB, 8 conventional,
4 KiB sectors), plus a 1 GiB file-backed cache device where needed, runs the case and cleans up. Root only; it refuses
to run if `scsi_debug` is already loaded. ~3 GiB of RAM/disk, a few minutes each. Tested 2026-10-08 on kernel
7.2.6 (Ubuntu mainline build) in a Debian 13 VM.

`scsi_debug` rather than `null_blk`: SCSI/ATA disks, like the real drives, report the write pointer of a conventional
zone as -1, and reproducer 1 depends on that; `null_blk` reports the zone's end and does not trigger the crash.

| Script | Shows | Stock result | With the patch |
|---|---|---|---|
| `1-dmzadm-check-two-devices.sh` | `dmzadm --check <cache> <zoned>` after reclaim moved chunks into the drive's conventional zones | segfault, exit 139, output ends at "Checking zone bitmaps..." (dm-zoned-tools 2.2.2) | exit 0, "No error detected" (`patches/dmzadm-check-conv-zones.patch`; run with `DMZADM=/path/to/patched/dmzadm`) |
| `2-dm-zoned-idle-reclaim-loop.sh [s]` | an idle two-device target with no free sequential zone | ~600 MB/s read + write without pause, zone counters unchanged (stock dm-zoned, 7.2.6) | 0 MB/s (`patches/dm-zoned-reclaim.patch`) |
| `3-dmzadm-repair-drill.sh` | primary chunk map corrupted, secondary set intact | `dmzadm --repair`: 0 of 12 chunks intact | recovery with `tools/dmz-metaset.py --copy 1`: 12 of 12 intact |

The second dm-zoned problem (the idle poll not re-armed after a busy reclaim pass) needs a load pattern that is
hard to make deterministic in a few minutes; it was seen on the real drives (see `docs/09`, section 4.2).
