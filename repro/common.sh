# shared setup for the reproducers: a small RAM-backed host-managed SCSI disk from scsi_debug (32 zones of 64 MiB,
# 8 conventional, 4 KiB sectors) and, for two-device tests, a 1 GiB file-backed cache device (16 zones). scsi_debug
# is used rather than null_blk because SCSI/ATA disks (like real drives) report the write pointer of a conventional
# zone as -1, which one of the bugs needs; null_blk reports the zone end. Needs root, scsi_debug, dm-zoned, dmzadm
# (dm-zoned-tools). Uses ~3 GiB of RAM/disk. Refuses if scsi_debug is already loaded.
set -u
ZS_MB=${ZS_MB:-64}; GB=${GB:-2}; NCONV=${NCONV:-8}; CACHE_MB=${CACHE_MB:-1024}
DMZADM=${DMZADM:-dmzadm}
log(){ echo "[$(date +%T)] $*"; }
need(){ command -v "$1" >/dev/null || { echo "missing: $1"; exit 2; }; }
setup_zoned(){
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
  need "$DMZADM"; need blkzone; need dmsetup; need losetup
  lsmod | grep -q '^scsi_debug' && { echo "scsi_debug is already loaded - refusing (it may be in use)"; exit 2; }
  modprobe scsi_debug zbc=managed dev_size_mb=$((GB * 1024)) zone_size_mb=$ZS_MB zone_nr_conv=$NCONV sector_size=4096 max_luns=1 num_tgts=1 || exit 2
  udevadm settle; sleep 2
  Z=""; for d in /sys/block/sd*; do [ "$(cat $d/device/model 2>/dev/null | tr -d ' ')" = scsi_debug ] && Z=/dev/$(basename $d); done
  [ -b "$Z" ] || { echo "scsi_debug disk not found"; exit 2; }
  log "zoned device $Z: $(blkzone report $Z | wc -l) zones of $ZS_MB MiB, $(blkzone report $Z | grep -c CONVENTIONAL) conventional"
}
setup_cache(){
  CIMG=$(mktemp /var/tmp/dmz-repro-cache.XXXXXX); truncate -s ${CACHE_MB}M "$CIMG"
  C=$(losetup -f --show "$CIMG"); log "cache device $C (${CACHE_MB} MiB file)"
}
cleanup(){
  for t in dmzrepro; do dmsetup info $t >/dev/null 2>&1 && dmsetup remove $t; done
  [ -n "${C:-}" ] && losetup -d "$C" 2>/dev/null; [ -n "${CIMG:-}" ] && rm -f "$CIMG"
  udevadm settle; lsmod | grep -q '^scsi_debug' && modprobe -r scsi_debug
}
trap cleanup EXIT
# fill the whole target with data, then let reclaim drain the cache: afterwards no sequential zone is free and
# some chunks live in conventional zones of the zoned drive (the state both two-device bugs need)
fill_and_drain(){
  local dev=/dev/mapper/dmzrepro
  log "filling $(( $(blockdev --getsz $dev) / 2048 )) MiB"
  dd if=/dev/urandom of=$dev bs=4M oflag=direct status=none 2>/dev/null; sync
  dmsetup message dmzrepro 0 reclaim
  local t=0
  until dmsetup status dmzrepro | awk '{for(i=1;i<=NF;i++) if($(i+1)=="cache"){split($i,a,"/"); exit !(a[1]==a[2])}}'; do
    sleep 5; t=$((t+1)); [ $t -lt 120 ] || { log "cache did not drain"; break; }; dmsetup message dmzrepro 0 reclaim
  done
  log "after fill + drain: $(dmsetup status dmzrepro | cut -d' ' -f4-)"
}
