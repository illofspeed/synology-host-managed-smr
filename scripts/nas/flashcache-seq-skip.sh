#!/bin/sh
# flashcache-seq-skip.sh - let DSM's SSD cache (flashcache) cache sequential I/O too.
# DSM skips any sequential stream of >= 1 MiB (skip_seq_thresh_kb=1024); DSM 7 has no UI switch.
# The guest's virtual disks used as dm-zoned / dm-cache cache devices produce exactly such
# streams, so without this their I/O goes to the NAS's hard drives. Runtime value only: a NAS
# reboot restores 1024. Run it from DSM Task Scheduler as root, event "Boot-up" (and once by hand
# after any change to the SSD cache in DSM). Revert: disable the task, set the value to 1024.
# See docs/08-caching.md, section "Synology: make the SSD cache take the cache disks' I/O".
for i in $(seq 1 120); do
  ks=$(sysctl -a 2>/dev/null | awk -F' = ' '/^dev\.flashcache.*\.skip_seq_thresh_kb/{print $1}')
  if [ -n "$ks" ]; then
    for k in $ks; do sysctl -w "$k=0" >/dev/null && logger -t flashcache-seq "$k=0"; done
    exit 0
  fi
  sleep 5
done
logger -t flashcache-seq "no flashcache sysctl found after 600 s"
exit 1
