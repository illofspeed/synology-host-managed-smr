#!/bin/sh
# synology-zoned-attach.sh - keep a dedicated SATA controller, with host-managed SMR (zoned)
# drives behind it, attached to a Synology Virtual Machine Manager (VMM) guest.
#
# Why this exists: DSM cannot use host-managed drives at all, VMM has no PCI passthrough in
# its UI, and VMM regenerates a guest's libvirt domain whenever the guest is powered on.
# So the controller can only be attached LIVE, after the guest has started. This watcher
# polls; whenever the target guest is running without the controller, it binds the
# controller to vfio-pci and attaches it with `virsh attach-device --live`.
# It never detaches anything.
#
# Tested ONLY on a DS3622xs+ (DSM 7.4, kernel 4.4.302) + DX1222 expansion unit. There the
# expansion unit's drives sit behind a separate Marvell 88SE9235 (1b4b:9235) in its own IOMMU
# group, while DSM's 12 internal bays use a Marvell 88SE1475 (driver mv14xx). Everything
# else is untested. Read docs/02-synology-controller-passthrough.md before using it.
#
# Fails closed:
#   - PROTECT_PCI_HARD (below) is set in THIS FILE, after the config is read, so the config
#     can add protected addresses but never remove one. The script refuses to act while
#     PROTECT_PCI_HARD is empty or names an address that does not exist (typo guard).
#   - only a device with the configured vendor:device is ever touched;
#   - "model census": a controller is chosen only if exactly ZONED_COUNT drives whose model
#     contains ZONED_MODEL are behind it, and no drive whose model contains one of DSM_MODEL;
#     if more than one controller matches, none is chosen;
#   - a recorded address is re-validated on every use (present, vendor:device, not
#     protected, has an IOMMU group, no DSM drive model behind it).
#
# USE AT YOUR OWN RISK. Unbinding a controller that DSM uses takes DSM's volumes offline.
# On the author's NAS the kernel once panicked in Synology's own mv14xx driver shortly after
# the passed-through controller had been attached and heavy writes went through it (see the
# docs). Have backups.
#
# Usage:
#   synology-zoned-attach.sh census   # read-only: PCI devices, drivers, IOMMU groups, drives
#   synology-zoned-attach.sh status   # armed?, watcher running?, recorded address, guest state
#   synology-zoned-attach.sh once     # one check/attach pass (the default)
#   synology-zoned-attach.sh watch    # loop forever (started at boot by S99zoned-attach.sh)
#
# The config is read ONCE, when the script starts. After editing it, restart the watcher:
#   /usr/local/etc/rc.d/S99zoned-attach.sh restart
#
# Derived from the author's as-built watcher (peer-reviewed v2, in use since 2026-09-13).
# Differences from the as-built: config-driven model/count/vendor values; DSM_MODEL may be a
# list; typo guard for protected addresses; IOMMU-group, vfio-pci-loaded, ambiguity and
# DSM-drive re-checks; the read-only `census` mode; clean exit (lock released) when stopped
# mid-pass; files under one directory. These additions have not run on a Synology yet.
set -u

DIR=${ZONED_ATTACH_DIR:-/volume1/zoned-attach}
CONF=${ZONED_ATTACH_CONF:-$DIR/attach.conf}
[ -f "$CONF" ] && . "$CONF"

# ---- EDIT THIS: every PCI address DSM uses for its own drives, space-separated ------------
# Full form 0000:bb:ss.f. Find them with `synology-zoned-attach.sh census`. Include every
# controller with DSM drives behind it (and the NVMe cache SSDs if you have any).
# On the author's DS3622xs+ this was "0000:07:00.0" (88SE1475, the 12 internal bays).
# PCI addresses are per machine: NEVER copy someone else's.
PROTECT_PCI_HARD=""
# -------------------------------------------------------------------------------------------
PROTECT_PCI="$PROTECT_PCI_HARD ${PROTECT_PCI:-}"   # the config can only ADD to this list

: "${DOM:=}"; : "${ZONED_MODEL:=}"; : "${ZONED_COUNT:=0}"; : "${DSM_MODEL:=}"
: "${CTRL_VENDOR:=0x1b4b}"; : "${CTRL_DEVICE:=0x9235}"
: "${WANT_NESTED:=0}"; : "${POLL=15}"
VIRSH=/usr/local/bin/virsh
LOG=$DIR/attach.log
STATE=$DIR/attach.state
ENABLE=$DIR/attach.enable
LOCK=$DIR/attach.lock
XML=$DIR/hostdev.xml
PCI=/sys/bus/pci/devices
# DSM has no pgrep. Use the same exact argv matcher as the rc.d hook.
WATCH_SCRIPT=$DIR/synology-zoned-attach.sh
HOOK_LOCK=/tmp/zoned-attach-hook.lock
WATCH_SH=$(printf '/bin/sh\n%s\nwatch\n.' "$WATCH_SCRIPT")
WATCH_SH_SHORT=$(printf 'sh\n%s\nwatch\n.' "$WATCH_SCRIPT")
WATCH_BASH=$(printf '/bin/bash\n%s\nwatch\n.' "$WATCH_SCRIPT")
WATCH_BASH_SHORT=$(printf 'bash\n%s\nwatch\n.' "$WATCH_SCRIPT")
watcher_pid()(
  [ -r "/proc/$1/cmdline" ] || return 1
  cmd=$( { tr '\000\n' '\n\001' <"/proc/$1/cmdline"; } 2>/dev/null; printf '.')
  case "$cmd" in
    "$WATCH_SH"|"$WATCH_SH_SHORT"|"$WATCH_BASH"|"$WATCH_BASH_SHORT") return 0 ;;
  esac
  return 1
)
watcher_running(){
  for proc in /proc/[0-9]*; do
    watcher_pid "${proc##*/}" && return 0
  done
  return 1
}

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null
       [ -t 2 ] && printf '%s\n' "$*" >&2; return 0; }

# Keep these lock helpers in sync with S99zoned-attach.sh (say there, log here).
hook_unlock(){
  rm "$HOOK_LOCK/pid.$hook_pid" 2>/dev/null && rmdir "$HOOK_LOCK" 2>/dev/null
}
hook_lock(){
  # $$ is the parent's PID in a subshell; read the actual lock holder's PID instead.
  read -r hook_pid hook_stat </proc/self/stat || return 1
  if ! mkdir "$HOOK_LOCK" 2>/dev/null; then
    set -- "$HOOK_LOCK"/pid.*
    # Missing/incomplete owner records can be a live acquisition: fail closed.
    [ "$#" -eq 1 ] && [ -f "$1" ] \
      || { log "another start/stop/restart or manual once is running (or lifecycle lock needs manual recovery)"; return 1; }
    owner_pid=${1##*.}
    case "$owner_pid" in ''|*[!0-9]*|0)
      log "invalid lifecycle lock owner - manual recovery required"; return 1 ;;
    esac
    [ ! -d "/proc/$owner_pid" ] \
      || { log "another start/stop/restart or manual once is running"; return 1; }
    # Only the caller that unlinks this dead owner's token may remove the directory.
    # Do not use rm -f: a competing recovery must not remove a new owner's lock.
    if ! { rm "$1" && rmdir "$HOOK_LOCK" && mkdir "$HOOK_LOCK"; } 2>/dev/null; then
      log "lifecycle lock changed or cannot be recovered - retry or check it manually"; return 1
    fi
    log "recovered stale lifecycle lock (owner PID $owner_pid is gone)"
  fi
  trap 'hook_unlock' 0
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  printf '%s\n' "$hook_pid" >"$HOOK_LOCK/pid.$hook_pid" \
    || { log "cannot record lifecycle lock owner - refusing"; return 1; }
}

is_protected(){ for q in $PROTECT_PCI; do [ "$1" = "$q" ] && return 0; done; return 1; }

# models of the drives DSM currently sees behind a PCI device (AHCI/libata and SCSI HBAs);
# used by `census` only
drive_models(){ for m in "$PCI/$1"/ata*/host*/target*/*/model "$PCI/$1"/host*/target*/*/model; do
                  [ -f "$m" ] && tr -s ' ' <"$m"; done; return 0; }

dsm_drive_behind(){ for m in "$PCI/$1"/ata*/host*/target*/*/model "$PCI/$1"/host*/target*/*/model; do
    [ -f "$m" ] || continue; ms=$(cat "$m" 2>/dev/null)
    for q in $DSM_MODEL; do case "$ms" in *"$q"*) return 0;; esac; done
  done; return 1; }

preflight(){ rc=0
  [ -n "$(printf '%s' "$PROTECT_PCI_HARD" | tr -d ' ')" ] \
    || { log "CONFIG ERROR: PROTECT_PCI_HARD in $0 is empty - refusing"; rc=1; }
  for q in $PROTECT_PCI; do
    [ -d "$PCI/$q" ] || { log "CONFIG ERROR: protected address '$q' does not exist (use the full form 0000:bb:ss.f) - refusing"; rc=1; }
  done
  [ -n "$DOM" ] || { log "CONFIG ERROR: DOM is empty - refusing"; rc=1; }
  [ -n "$ZONED_MODEL" ] || { log "CONFIG ERROR: ZONED_MODEL is empty - refusing"; rc=1; }
  [ -n "$(printf '%s' "$DSM_MODEL" | tr -d ' ')" ] || { log "CONFIG ERROR: DSM_MODEL is empty - refusing"; rc=1; }
  case "$ZONED_COUNT" in ''|*[!0-9]*|0) log "CONFIG ERROR: ZONED_COUNT must be a number >= 1 - refusing"; rc=1;; esac
  # Bound the length before numeric comparisons to avoid overflow on bad input.
  case "$POLL" in ''|*[!0-9]*|?????*)
    log "CONFIG ERROR: POLL must be whole seconds from 1 to 3600 (at most 4 digits) - refusing"; rc=1 ;;
    *) if [ "$POLL" -lt 1 ] || [ "$POLL" -gt 3600 ]; then
         log "CONFIG ERROR: POLL must be whole seconds from 1 to 3600 (at most 4 digits) - refusing"; rc=1
       fi ;;
  esac
  return $rc; }

valid_addr(){ a=$1
  [ -n "$a" ] || return 1
  is_protected "$a" && { log "REFUSE: $a is protected (PROTECT_PCI)"; return 1; }
  [ -d "$PCI/$a" ] || { log "REFUSE: $a not present"; return 1; }
  [ "$(cat "$PCI/$a/vendor" 2>/dev/null)" = "$CTRL_VENDOR" ] || { log "REFUSE: $a wrong vendor"; return 1; }
  [ "$(cat "$PCI/$a/device" 2>/dev/null)" = "$CTRL_DEVICE" ] || { log "REFUSE: $a wrong device"; return 1; }
  [ -e "$PCI/$a/iommu_group" ] || { log "REFUSE: $a has no IOMMU group"; return 1; }
  dsm_drive_behind "$a" && { log "REFUSE: $a has a DSM drive model behind it"; return 1; }
  return 0; }

# The model census: exactly ZONED_COUNT zoned drives and no DSM drive behind the controller.
# Once the controller is bound to vfio-pci, DSM no longer sees its drives and the census is
# empty; the address recorded in STATE is then used (after valid_addr).
find_ctrl(){ found=""; hits=0
  for p in "$PCI"/*; do a=${p##*/}
    is_protected "$a" && continue
    [ "$(cat "$p/vendor" 2>/dev/null)" = "$CTRL_VENDOR" ] || continue
    [ "$(cat "$p/device" 2>/dev/null)" = "$CTRL_DEVICE" ] || continue
    dsm_drive_behind "$a" && { log "REFUSE $a: a DSM drive model is behind it"; continue; }
    n=0
    for m in "$p"/ata*/host*/target*/*/model "$p"/host*/target*/*/model; do [ -f "$m" ] || continue
      case "$(cat "$m" 2>/dev/null)" in *"$ZONED_MODEL"*) n=$((n+1));; esac
    done
    [ "$n" = "$ZONED_COUNT" ] && { found="$a"; hits=$((hits+1)); }
  done
  [ "$hits" -gt 1 ] && { log "REFUSE: $hits controllers match the census - ambiguous"; found=""; }
  echo "$found"; }

# Minimal hostdev XML: ONLY the host-side <source>. A <hostdev> block dumped from a running
# guest also carries that guest's own <address>/<alias>; reusing it on another domain can
# fail or land in an occupied slot. libvirt places the device itself.
mkxml(){ a=$1; b=$(echo "$a"|cut -d: -f2); s=$(echo "$a"|cut -d: -f3|cut -d. -f1); f=$(echo "$a"|cut -d. -f2)
  printf "<hostdev mode='subsystem' type='pci' managed='no'>\n  <source><address domain='0x0000' bus='0x%s' slot='0x%s' function='0x%s'/></source>\n</hostdev>\n" "$b" "$s" "$f" >"$XML"
  echo "$XML"; }

# scoped to <hostdev>...<source> ONLY - a guest-side PCI address must never match
is_attached(){ a=$1; b=$(echo "$a"|cut -d: -f2); s=$(echo "$a"|cut -d: -f3|cut -d. -f1); f=$(echo "$a"|cut -d. -f2)
  $VIRSH dumpxml "$DOM" 2>/dev/null \
    | awk '/<hostdev/,/<\/hostdev>/' | awk '/<source>/,/<\/source>/' \
    | tr -d ' \n' | grep -q "bus='0x$b'slot='0x$s'function='0x$f'"; }

cur_driver(){ d=$(readlink "$PCI/$1/driver" 2>/dev/null); echo "${d##*/}"; }

bind_vfio(){ a=$1; D=$PCI/$a
  valid_addr "$a" || return 1
  [ "$(cur_driver "$a")" = vfio-pci ] && return 0
  [ -d /sys/bus/pci/drivers/vfio-pci ] || { log "vfio-pci driver not loaded - not unbinding $a"; return 1; }
  [ -n "$(cur_driver "$a")" ] && { echo "$a" >"$D/driver/unbind" 2>/dev/null; sleep 3; }
  echo vfio-pci >"$D/driver_override" 2>/dev/null
  echo "$a" >/sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null; sleep 2
  [ "$(cur_driver "$a")" = vfio-pci ]; }

# Optional, Intel only: expose VMX to guests (DSM's kvm_intel defaults to nested=0, the
# parameter is read-only at runtime and DSM has no /etc/modprobe.d). Reloads the module
# only while NO guest is running, i.e. in practice at NAS boot before VMM starts guests.
maybe_nested(){ [ "$WANT_NESTED" = 1 ] || return 0
  [ -r /sys/module/kvm_intel/parameters/nested ] || return 0
  [ "$(cat /sys/module/kvm_intel/parameters/nested)" = Y ] && return 0
  [ "$(awk '$1=="kvm_intel"{print $3}' /proc/modules)" = 0 ] || { log "nested: kvm_intel busy, skipping"; return 0; }
  [ -z "$($VIRSH list --name 2>/dev/null | tr -d '[:space:]')" ] || return 0
  /sbin/rmmod kvm_intel 2>/dev/null || { log "nested: rmmod failed"; return 1; }
  /sbin/insmod /lib/modules/kvm-intel.ko nested=1 2>/dev/null \
    || { /sbin/insmod /lib/modules/kvm-intel.ko 2>/dev/null; log "nested: reload FAILED, default restored"; return 1; }
  log "nested: enabled"; }

once(){ [ -f "$ENABLE" ] || return 0
  preflight || return 1
  [ -x "$VIRSH" ] || { log "virsh missing at $VIRSH"; return 1; }
  mkdir "$LOCK" 2>/dev/null || return 0                    # another instance is working
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM                # exit (and drop the lock) on kill
  st=$($VIRSH domstate "$DOM" 2>/dev/null)
  if [ "$st" = running ]; then
    a=$(find_ctrl)
    if [ -n "$a" ]; then
      [ "$a" = "$(cat "$STATE" 2>/dev/null)" ] || echo "$a" >"$STATE" 2>/dev/null \
        || log "WARN: could not persist state for $a"
    else
      a=$(cat "$STATE" 2>/dev/null)
    fi
    if valid_addr "$a"; then
      if ! is_attached "$a"; then
        if bind_vfio "$a"; then
          x=$(mkxml "$a")
          if $VIRSH attach-device "$DOM" "$x" --live >/dev/null 2>&1; then log "attached $a"
          else log "attach FAILED for $a"; fi
        else log "vfio bind FAILED for $a"; fi
      fi
    else
      log "no usable controller (census empty and recorded address invalid)"
    fi
  fi
  rmdir "$LOCK" 2>/dev/null; trap - EXIT INT TERM; return 0; }

census(){
  echo "IOMMU groups: $(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)  (0 = no IOMMU in DSM: stop here)"
  for p in "$PCI"/*; do a=${p##*/}
    v=$(cat "$p/vendor" 2>/dev/null); d=$(cat "$p/device" 2>/dev/null); drv=$(cur_driver "$a")
    n=$(drive_models "$a" | grep -c .); nv=$(cat "$p"/nvme/nvme*/model 2>/dev/null | grep -c .)
    [ "$n" -gt 0 ] || [ "$nv" -gt 0 ] || [ "$drv" = vfio-pci ] \
      || [ "$v:$d" = "$CTRL_VENDOR:$CTRL_DEVICE" ] || continue
    g=$(readlink "$p/iommu_group" 2>/dev/null); g=${g##*/}
    mem=$(ls "$p/iommu_group/devices" 2>/dev/null | tr '\n' ' ')
    tag=""; is_protected "$a" && tag="  [PROTECTED]"
    echo "$a  ${v#0x}:${d#0x}  driver=${drv:-none}  iommu_group=${g:-NONE}  group members: ${mem:-none}$tag"
    drive_models "$a" | sed 's/^/      drive: /'
    [ "$nv" -gt 0 ] && cat "$p"/nvme/nvme*/model 2>/dev/null | sed 's/^/      nvme:  /'
    [ "$drv" = vfio-pci ] && echo "      (bound to vfio-pci: its drives are not visible to DSM)"
  done
  if [ -n "$ZONED_MODEL" ] && [ -n "$(printf '%s' "$DSM_MODEL" | tr -d ' ')" ] && [ "$ZONED_COUNT" != 0 ]; then
    c=$(LOG=/dev/null; find_ctrl)
    echo "census verdict (ZONED_MODEL=$ZONED_MODEL ZONED_COUNT=$ZONED_COUNT DSM_MODEL=$DSM_MODEL): ${c:-NONE - no controller matches exactly, more than one does, or it is already bound to vfio-pci}"
  else
    echo "census verdict: set ZONED_MODEL, ZONED_COUNT and DSM_MODEL in $CONF to see which controller would be chosen"
  fi
  echo "protected: $(echo $PROTECT_PCI)"; }

case "${1:-once}" in
  once)   (
            hook_lock || exit 1
            # Keep once()'s pass-lock traps separate from the lifecycle lock's traps.
            ( maybe_nested; once )
          ) ;;
  census) census ;;
  status) w=stopped; watcher_running && w=running
          echo "armed=$([ -f "$ENABLE" ] && echo yes || echo no) watcher=$w state=$(cat "$STATE" 2>/dev/null) domain=$($VIRSH domstate "$DOM" 2>/dev/null) hostdevs=$($VIRSH dumpxml "$DOM" 2>/dev/null | grep -c '<hostdev')"
          [ -d "$LOCK" ] && echo "lock present: $LOCK"
          tail -8 "$LOG" 2>/dev/null; exit 0 ;;
  watch)  preflight || { log "watcher NOT started (fix the config, then restart)"; exit 1; }
          log "watcher up (pid $$)"; i=0
          while :; do
            [ $i -lt 80 ] && maybe_nested   # kvm_intel may not exist yet at rc.d time;
            once; i=$((i+1))                # keep trying for ~20 min, then give up
            [ $((i % 240)) = 0 ] && log "heartbeat: still watching"
            sleep "$POLL" || { log "POLL sleep failed - watcher exiting to prevent a busy loop"; exit 1; }
          done ;;
  *)      echo "usage: $0 census|status|once|watch" >&2; exit 2 ;;
esac
