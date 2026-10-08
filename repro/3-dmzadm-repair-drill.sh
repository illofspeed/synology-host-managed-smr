#!/bin/bash
# dmzadm --repair destroys a single-device member whose PRIMARY chunk map is corrupt while the secondary
# metadata set is intact (same generation). Then the safe recovery with tools/dmz-metaset.py.
# usage: ./3-dmzadm-repair-drill.sh      (needs python3 for the recovery part)
. "$(dirname "$0")/common.sh"
META=$(cd "$(dirname "$0")/../tools" && pwd)/dmz-metaset.py
N=${N:-12}
setup_zoned
sums=$(mktemp -d)
run(){  # $1 = label, $2 = "repair" | "metaset"
  "$DMZADM" --format "$Z" --force >/dev/null || exit 2
  dmsetup create dmzrepro --table "0 $(blockdev --getsz $Z) zoned $Z" || exit 2
  for c in $(seq 0 $((N - 1))); do head -c $((ZS_MB << 20)) /dev/urandom | tee >(sha256sum | cut -c1-64 > $sums/$c) | dd of=/dev/mapper/dmzrepro bs=4M seek=$((c * ZS_MB / 4)) oflag=direct status=none; done
  sync; sleep 1; dmsetup remove dmzrepro
  dd if=/dev/urandom of=$Z bs=4096 seek=1 count=1 oflag=direct status=none    # map block 0 of metadata set 0
  log "$1: map block of the primary set corrupted; check says: $("$DMZADM" --check $Z 2>&1 | grep -m1 -iE 'invalid|error')"
  if [ "$2" = repair ]; then "$DMZADM" --repair $Z >/dev/null 2>&1; log "$1: dmzadm --repair done; check now: $("$DMZADM" --check $Z 2>&1 | tail -1)"
  else python3 "$META" --zoned $Z --copy 1 | tail -1; log "$1: check now: $("$DMZADM" --check $Z 2>&1 | tail -1)"; fi
  dmsetup create dmzrepro --table "0 $(blockdev --getsz $Z) zoned $Z" || { log "$1: kernel refused the target"; return; }
  local ok=0; for c in $(seq 0 $((N - 1))); do [ "$(dd if=/dev/mapper/dmzrepro bs=4M skip=$((c * ZS_MB / 4)) count=$((ZS_MB / 4)) iflag=direct status=none | sha256sum | cut -c1-64)" = "$(cat $sums/$c)" ] && ok=$((ok + 1)); done
  log "RESULT ($1): $ok of $N chunks intact"; dmsetup remove dmzrepro
}
run "A, dmzadm --repair" repair
run "B, dmz-metaset --copy 1" metaset
rm -rf "$sums"
