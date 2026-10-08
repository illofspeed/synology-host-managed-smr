#!/bin/sh
# flashcache-seq-skip.sh [KB] - set DSM's SSD cache (flashcache) sequential-skip threshold.
# DSM skips any sequential stream of >= 1 MiB (skip_seq_thresh_kb=1024); DSM 7 has no UI switch.
# The guest's virtual disks used as dm-zoned / dm-cache cache devices write in bursts of one
# 256 MiB zone, so at 1024 their I/O goes to the NAS's hard drives.
#   1024 (default, = DSM's own default): long streams (btrfs scrub, backups, big copies and the
#                              cache disks' zone streams) bypass the SSDs. Measured best in October 2026,
#                              also with every member cached (docs/09, section 3).
#   524288 (512 MiB):          zone-sized bursts are cached; superseded (the NVMe insert path is slower).
#   0:                         cache everything. Only while a guest member rebuilds onto a
#                              dm-zoned cache device; with 0 a btrfs scrub floods the SSDs.
# Runtime value only: a NAS reboot restores 1024. Run it from DSM Task Scheduler as root, event
# "Boot-up" (and once by hand after any change to the SSD cache in DSM). Revert: disable the task,
# set the value to 1024. See docs/08-caching.md, section "Synology: make the SSD cache take the
# cache disks' I/O".
v=${1:-1024}
case $v in ''|*[!0-9]*) logger -t flashcache-seq "invalid value '$v'"; exit 2 ;; esac
for i in $(seq 1 120); do
  ks=$(sysctl -a 2>/dev/null | awk -F' = ' '/^dev\.flashcache.*\.skip_seq_thresh_kb/{print $1}')
  if [ -n "$ks" ]; then
    for k in $ks; do sysctl -w "$k=$v" >/dev/null && logger -t flashcache-seq "$k=$v"; done
    exit 0
  fi
  sleep 5
done
logger -t flashcache-seq "no flashcache sysctl found after 600 s"
exit 1
