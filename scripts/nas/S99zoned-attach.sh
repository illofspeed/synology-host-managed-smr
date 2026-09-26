#!/bin/sh
# /usr/local/etc/rc.d/S99zoned-attach.sh - start the zoned-controller watcher at DSM boot.
#
# DSM runs /usr/local/etc/rc.d/*.sh with "start" at boot ("stop" is for manual use). The
# author uses this file-based hook because DSM Task Scheduler boot-up tasks proved
# unreliable for this. Install as root, mode 755. See docs/02-synology-controller-passthrough.md.
#
#   S99zoned-attach.sh start     # at boot: waits for /volume1 in the background, then starts
#   S99zoned-attach.sh restart   # after editing attach.conf (the watcher reads it only at start)
#   S99zoned-attach.sh stop
#   S99zoned-attach.sh status
DIR=/volume1/zoned-attach
SCRIPT=$DIR/synology-zoned-attach.sh
STOP_TIMEOUT=60
HOOK_LOCK=/tmp/zoned-attach-hook.lock
say(){ logger -t zoned-attach "rc.d: $*" 2>/dev/null; [ -t 1 ] && echo "$*"; return 0; }

# Serialize lifecycle changes and manual once passes, including the startup check.
# Keep these lock helpers in sync with synology-zoned-attach.sh (log there, say here).
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
      || { say "another start/stop/restart or manual once is running (or lifecycle lock needs manual recovery)"; return 1; }
    owner_pid=${1##*.}
    case "$owner_pid" in ''|*[!0-9]*|0)
      say "invalid lifecycle lock owner - manual recovery required"; return 1 ;;
    esac
    [ ! -d "/proc/$owner_pid" ] \
      || { say "another start/stop/restart or manual once is running"; return 1; }
    # Only the caller that unlinks this dead owner's token may remove the directory.
    # Do not use rm -f: a competing recovery must not remove a new owner's lock.
    if ! { rm "$1" && rmdir "$HOOK_LOCK" && mkdir "$HOOK_LOCK"; } 2>/dev/null; then
      say "lifecycle lock changed or cannot be recovered - retry or check it manually"; return 1
    fi
    say "recovered stale lifecycle lock (owner PID $owner_pid is gone)"
  fi
  trap 'hook_unlock' 0
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  printf '%s\n' "$hook_pid" >"$HOOK_LOCK/pid.$hook_pid" \
    || { say "cannot record lifecycle lock owner - refusing"; return 1; }
}

# DSM has no pgrep. Match the full argv, including its NUL argument boundaries.
# Translate literal newlines separately so they cannot masquerade as boundaries;
# the final dot preserves trailing empty arguments through command substitution.
# Keep this matcher in sync with synology-zoned-attach.sh's watcher_pid().
WATCH_SH=$(printf '/bin/sh\n%s\nwatch\n.' "$SCRIPT")
WATCH_SH_SHORT=$(printf 'sh\n%s\nwatch\n.' "$SCRIPT")
WATCH_BASH=$(printf '/bin/bash\n%s\nwatch\n.' "$SCRIPT")
WATCH_BASH_SHORT=$(printf 'bash\n%s\nwatch\n.' "$SCRIPT")
watcher_pid()(
  [ -r "/proc/$1/cmdline" ] || return 1
  cmd=$( { tr '\000\n' '\n\001' <"/proc/$1/cmdline"; } 2>/dev/null; printf '.')
  case "$cmd" in
    "$WATCH_SH"|"$WATCH_SH_SHORT"|"$WATCH_BASH"|"$WATCH_BASH_SHORT") return 0 ;;
  esac
  return 1
)
watcher_pids(){
  for proc in /proc/[0-9]*; do
    watcher_pid "${proc##*/}" && echo "${proc##*/}"
  done
  return 0
}
running(){ [ -n "$(watcher_pids)" ]; }

start(){
  # /volume1 may not be mounted yet when rc.d runs (an encrypted volume mounts late).
  # Wait up to 5 minutes instead of silently never starting.
  n=0
  while [ ! -f "$SCRIPT" ] && [ $n -lt 60 ]; do sleep 5; n=$((n+1)); done
  [ -f "$SCRIPT" ] || { say "$SCRIPT not found after $((n*5)) s - watcher NOT started"; return 1; }
  if running; then say "watcher already running - not starting a second one"; return 0; fi
  # A lock left behind by a crash or a hard kill would make every pass a silent no-op.
  # No watcher is running, and HOOK_LOCK excludes a manual once pass, so it is stale.
  if [ -d "$DIR/attach.lock" ]; then
    rmdir "$DIR/attach.lock" 2>/dev/null \
      || { say "cannot remove stale attach.lock - watcher NOT started"; return 1; }
  fi
  nohup /bin/sh "$SCRIPT" watch >/dev/null 2>>"$DIR/attach.log" &
  pid=$!
  sleep 2
  watcher_pid "$pid" \
    || { say "watcher exited immediately - check $DIR/attach.log"; return 1; }
  say "watcher started (pid $pid)"
}

stop(){
  pids=$(watcher_pids)
  [ -n "$pids" ] || { say "watcher not running"; return 0; }
  deadline=$(( $(date +%s) + STOP_TIMEOUT ))
  for pid in $pids; do
    # Re-check before signalling: a process may have exited since the scan.
    watcher_pid "$pid" || continue
    if ! kill -TERM "$pid" 2>/dev/null && watcher_pid "$pid"; then
      say "cannot stop watcher (pid $pid) - leaving lock intact"; return 1
    fi
  done
  while :; do
    # Poll only the identified PIDs; scan all of /proc once more before success.
    left=""
    for pid in $pids; do watcher_pid "$pid" && left="$left $pid"; done
    pids=$left
    if [ -z "$pids" ]; then
      pids=$(watcher_pids)
      [ -n "$pids" ] || break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      say "watcher STILL running after ${STOP_TIMEOUT}s - leaving lock intact; check $DIR/attach.log"
      return 1
    fi
    sleep 1
  done
  say "watcher stopped"
}

case "${1:-}" in
  start)   ( hook_lock && start ) </dev/null >/dev/null 2>&1 & ;; # never block DSM's boot
  stop)    ( hook_lock && stop ) ;;
  restart) ( hook_lock && stop && start ) ;;
  status)  pids=$(watcher_pids)
           if [ -n "$pids" ]; then
             echo "watcher running (pid $(echo $pids))"
           else echo "watcher NOT running"; exit 1; fi ;;
  *)       echo "usage: $0 start|stop|restart|status" >&2; exit 2 ;;
esac
