#!/bin/bash
# dmzadm --check on a two-device (cache + zoned) set segfaults once chunks are mapped to conventional zones of the
# zoned device. Stock dm-zoned-tools 2.2.2 / master: exit 139. With patches/dmzadm-check-conv-zones.patch: exit 0.
# usage: DMZADM=/path/to/dmzadm ./1-dmzadm-check-two-devices.sh
. "$(dirname "$0")/common.sh"
setup_zoned; setup_cache
"$DMZADM" --format "$C" "$Z" --force >/dev/null || exit 2
dmsetup create dmzrepro --table "0 $(blockdev --getsz $Z) zoned $C $Z" || exit 2
fill_and_drain
dmsetup remove dmzrepro
log "running: $DMZADM --check $C $Z"
"$DMZADM" --check "$C" "$Z" > /tmp/dmz-repro-check.txt 2>&1; rc=$?
tail -3 /tmp/dmz-repro-check.txt
case $rc in 139) log "RESULT: segfault (exit 139) - bug reproduced";; 0) log "RESULT: exit 0 - fixed build";; *) log "RESULT: exit $rc";; esac
