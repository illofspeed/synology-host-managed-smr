#!/bin/bash
# An idle two-device dm-zoned target with no free sequential zone copies random zone -> random zone forever.
# Stock dm-zoned: the zoned device keeps reading and writing while idle, zone counters unchanged.
# With patches/dm-zoned-reclaim.patch: 0 MB/s. usage: ./2-dm-zoned-idle-reclaim-loop.sh [seconds, default 120]
. "$(dirname "$0")/common.sh"
SEC=${1:-120}
log "dm_zoned srcversion $(cat /sys/module/dm_zoned/srcversion 2>/dev/null || echo '(not loaded yet)')"
setup_zoned; setup_cache
"$DMZADM" --format "$C" "$Z" --force >/dev/null || exit 2
dmsetup create dmzrepro --table "0 $(blockdev --getsz $Z) zoned $C $Z" || exit 2
fill_and_drain
log "now idle for $SEC s, sampling the zoned device every 10 s (dm-zoned's idle period is 10 s)"
zb=$(basename $Z); r0=$(awk '{print $3}' /sys/block/$zb/stat); w0=$(awk '{print $7}' /sys/block/$zb/stat)
for i in $(seq 1 $((SEC / 10))); do
  sleep 10; r=$(awk '{print $3}' /sys/block/$zb/stat); w=$(awk '{print $7}' /sys/block/$zb/stat)
  log "read $(( (r - r0) * 512 / 10 / 1000000 )) MB/s, write $(( (w - w0) * 512 / 10 / 1000000 )) MB/s | $(dmsetup status dmzrepro | cut -d' ' -f5-)"
  r0=$r; w0=$w
done
log "RESULT: steady read+write with unchanged counters = bug reproduced; 0 MB/s = fixed module"
