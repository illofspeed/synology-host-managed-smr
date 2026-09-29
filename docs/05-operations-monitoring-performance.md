# 05 - Operations, monitoring and performance

This guide covers running the pool once it is built: what normal behaviour looks like, how
to monitor it, routine maintenance, and what to do when something breaks.

> **Before you start**
>
> - This has been tested on exactly one setup: a DS3622xs+ (DSM 7.4) with a DX1222 expansion
>   unit, 3 x WD Ultrastar HC680 27 TB, and a Debian 13 / OpenMediaVault 8 guest in VMM on
>   kernel `7.2.6-070206-generic`. Everything else is untested.
> - It only works because the zoned drives sit behind a controller that DSM does not use for
>   its own disks. On the DS3622xs+ that is the expansion unit's Marvell 88SE9235, passed
>   through **whole** to the guest. If your zoned drives would share the controller that DSM
>   boots and runs from, as they would on a DS1821+ in this layout, none of this applies.
>   See [01-requirements-and-risks.md](01-requirements-and-risks.md).
> - The NAS kernel panicked once in DSM's own storage driver shortly after the controller
>   was attached to a freshly started guest and heavy writes went through it. The cause is
>   unproven. Read [01, section 7.1](01-requirements-and-risks.md#71-nas-kernel-panic-in-dsms-own-storage-driver)
>   and keep backups.

Names used here are the ones from [03-guest-storage-stack.md](03-guest-storage-stack.md):
mappers `dz1..dz3`, array `/dev/md/hc680` (`md127`), LUKS mapping `hc680crypt`, mount point
`/srv/hc680`, units `zonedpool-dmzassemble`, `zonedpool-mdassemble`, `zonedpool-cryptopen`.
All guest commands run as root.

## Contents

1. [What normal looks like](#1-what-normal-looks-like)
2. [Monitoring](#2-monitoring)
3. [Maintenance](#3-maintenance)
4. [Recovery playbook](#4-recovery-playbook)
5. [Pitfalls at a glance](#5-pitfalls-at-a-glance)

---

## 1. What normal looks like

### 1.1 Boot and attach

| Event | What you see |
|---|---|
| Controller attached to the guest | The drives appear 1 to 3 minutes later. Meanwhile `dmesg` fills with `failed to resume link` / `failed to IDENTIFY (I/O error)` lines for port `.05` of each port multiplier. On the reference guest that was 12 `failed to IDENTIFY` lines at every attach. They come from a phantom port and are harmless ([02](02-synology-controller-passthrough.md)). |
| Reboot inside the guest | The controller stays attached. In the passing reboot test the pool was mounted about 90 s into boot (mappers ~84 s, array ~86 s, LUKS ~89 s, mount ~90 s), with NFS, SMB and rsync running right after. |
| VMM power cycle of the guest | Add about 2.5 minutes for the watcher to re-attach the controller and the drives to enumerate. |
| Worst case seen | One early boot waited 11 minutes for the drives; the pool was up about 12 minutes after the reboot. That is why the timeouts are long. |
| Reboot with a cache device and the volume cache ([08](08-caching.md)), 2026-09-29 | Shutdown took about 5 minutes: an open console login on tty1 held it 90 s (systemd's stop timeout), `blk-availability.service` timed out after another 90 s, and the rest went to the final shutdown and the VM restart. After the kernel started, the mappers took 1.5-2 min (one member 30 s late), then array, volume cache, LUKS and mount followed within about 20 s. A member rebuild resumed where it stopped. |
| A drive running a SMART self-test | A guest reboot resets the controller, and the drive aborts the test ("Interrupted (host reset)"). Restart it afterwards. |

### 1.2 The dm-zoned write buffer

dm-zoned writes incoming data into the drive's conventional zones first and later moves it
("reclaims" it) into the sequential zones. On the HC680, 998 conventional zones per drive are
available as this buffer: about 250 GiB per drive. The buffer decides your write speed:

- **While it has room, writes are fast.**
- **Under load, reclaim runs but cannot keep up, so the buffer keeps filling.** In the stress
  test (1.4) it filled at about 13 to 17 zones per minute per drive.
- **It only shrinks while the pool is idle.** Measured before LUKS was added: about 7 zones
  per minute per drive, so about 2 to 2.5 hours from full to empty. With LUKS, after a kick
  (below): about 8 zones per minute per drive, about 1.5 hours.
- **On 7.2.6 the idle drain does not always start by itself.** See 1.2.1. Install the
  `zonedpool-reclaim-kick` timer.
- **Once it is full, throughput drops to roughly a third to a half** and stays there. It does
  not collapse further and nothing fails.

Rough planning figure, derived rather than measured: three drives x ~250 GiB of buffer, of
which two thirds is data and one third parity, lets an empty buffer take in on the order of
500 GiB of new data before the slowdown, before accounting for additional space freed by
concurrent reclaim. Plan large copies accordingly, and leave idle time between big jobs so
the buffer can drain.

Watch it:

```sh
for m in dz1 dz2 dz3; do
  printf '%s  ' "$m"; dmsetup status "$m" | grep -oE '[0-9]+/[0-9]+ (random|sequential)' | tr '\n' ' '; echo
done
```

```
dz1  24/998 random 99046/99562 sequential
```

The **first** number is the count of **free** zones. `24/998 random` means 974 of the 998
buffer zones are in use: the buffer is nearly full. After a fresh format, with the array and
filesystem just created on top, the reference drives showed `961/998 random` and
`99560/99562 sequential`. The metrics script in section 2 exports the used ratio per mapper.

#### 1.2.1 The idle drain can stall (kernel 7.2.6): install the reclaim kick

**Observed 2026-09-28:** after a 40-hour md repair ended, the pool was completely idle (no I/O
on the drives, md or the LUKS device, no reclaim worker running), yet the buffers stayed at
`310/998 random` free on every drive for hours. Nothing was wrong with the data; the drain
simply never restarted.

**Why, from the v7.2.6 source** (`drivers/md/dm-zoned-reclaim.c`): the reclaim worker re-arms
its 10-second idle poll only on the path where it decides reclaim is *not* needed (line 514).
After a pass that did reclaim, it calls `dmz_schedule_reclaim()` (line 547), which re-queues
the work only if reclaim is warranted at that instant (lines 634-639): the target idle, or 30 %
or less of the buffer free. During the repair the targets were busy with about 31 % free, so
the last pass ended with nothing re-armed. The only other wake-ups are a new write that pushes
free space to 30 % or less (`dm-zoned-metadata.c` line 2212), a target resume, and the
`reclaim` message. Result: the buffer can stay about two thirds full indefinitely, and the
next large copy gets only about 31 % of the buffer (roughly 150 GB of data) before it slows
down, instead of nearly all of it. It is not dangerous, only slower.

**Workaround:** send the `reclaim` message regularly. It makes dm-zoned re-evaluate: it starts
reclaim if the target is idle (or 30 % or less is free) and does nothing otherwise, so it is
safe at any time.

```sh
dmsetup message dz1 0 reclaim       # one-off, per mapper
```

The repository ships a timer that does this for every zoned target every 15 minutes:

```sh
install -m 0755 scripts/guest/zonedpool-reclaim-kick /usr/local/sbin/
install -m 0644 systemd/zonedpool-reclaim-kick.service systemd/zonedpool-reclaim-kick.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now zonedpool-reclaim-kick.timer
```

On the reference pool the first kick started reclaim at once on all three drives (about
35 MB/s read and 36 MB/s written per drive) and emptied the buffers in about 1.5 hours.
Undo: `systemctl disable --now zonedpool-reclaim-kick.timer` and delete the three files. The
upstream fix would be to re-arm the idle poll at the end of every pass; as of this writing it
has not been reported upstream. Whether other kernel versions behave the same is untested.

### 1.3 Measured throughput

All numbers are from the reference system. On kernel 7.2.6, the copies from the NAS that
were measured were limited by the NAS side, not by the pool, until the dm-zoned buffer was
full.

| What | Conditions | Result |
|---|---|---|
| Sequential write, empty buffer | 32 GiB, one writer, before LUKS was added | 178-204 MiB/s, flat |
| Sequential write, buffer > 85 % full | long soak, same stack | 56-83 MiB/s, flat |
| Long soak | 320 GiB written | zero errors, no throughput drift |
| Space amplification | 90 s of writing | 13 GiB of `df` growth for 13 GiB of data (ratio 1.04) |
| Buffer drain | pool idle | ~7 zones/min per drive, ~2 h from full |
| Hyper Backup alone | kernel 7.2.6, encrypted pool | ~68 MB/s into the pool, drives ~22 % busy |
| Hyper Backup alone | kernel 6.12, fsync-heavy index phase | ~9.5 MB/s |
| md repair or resync | idle pool | 173-205 MB/s, a full pass takes about 33-40 h |
| md repair | under heavy writes | backs off to its 10 MB/s floor |
| LUKS2 aes-xts, 512-bit key | `cryptsetup benchmark`, one thread | ~950 MiB/s encrypt, ~1020 MiB/s decrypt |

The guest kernel changes throughput more than anything else. Same stack, same encrypted pool,
same two 60-second tests ([03, step 2](03-guest-storage-stack.md#step-2---choose-and-pin-the-kernel)):

| Guest kernel | 1 writer, O_DIRECT, 1 MiB | 4 writers, buffered, incl. final sync |
|---|---:|---:|
| Debian 13 `6.12.107` | 24.6 MiB/s | not measured |
| Debian backports `7.1.8` | 24.7 MiB/s | 34.4 MiB/s |
| Ubuntu mainline `7.2.6-070206-generic` | **165.4 MiB/s** | **261.4 MiB/s** |
| Zabbly `7.2.7` | 58-69 MiB/s (3 runs) | 210.7 MiB/s |

md RAID5 hands dm-zoned 4 KiB writes on every one of these kernels. **Why 7.2 is so much
faster is unknown.** `block/blk-zoned.c` is byte-identical in 7.1.8 and 7.2, so do not credit
zone write plugging. The author runs Ubuntu mainline 7.2.6.

### 1.4 The stress test of 2026-09-26

Kernel 7.2.6, encrypted pool. Three loads at once: a Hyper Backup seed from DSM, a media
push of about 3 TB with rsync from DSM, and the md parity repair.

| Phase | Pool writes | Buffer (used zones per drive, of 998) | Drives |
|---|---|---|---|
| Start | 116-143 MB/s (the NAS was the limit) | 418 -> 486 -> 554 -> 625 -> 713 -> 770 in 5-minute steps, about 13-17 zones/min | Reclaim started copying under load about 3 minutes in: 81-97 % busy, each writing 70-83 MB/s and reading 16-39 MB/s for reclaim |
| Filling | unchanged | 848, then 986 | |
| Saturated, about 45 minutes in | **38-69 MB/s** | 998/998 on one drive, 986-992 on the other two | 86-99 % busy, reclaim reading 28-44 MB/s per drive |

Throughout: about 210,000 commands completed per 5 minutes, reclaim workers changing and
copying, zero kernel errors in the guest, no kernel fault on the NAS, the evidence capture
never triggered, and none of the stuck-worker alerts fired. The md repair backed off from
about 190 MB/s to about 46 MB/s at the start and then to its 10 MB/s floor, with 0 mismatches.
The saturated state held for more than an hour without a hang or an error.

### 1.5 Reclaim workers in D state: busy is not hung

A dm-zoned reclaim worker shows up as a kernel worker thread named like
`kworker/u8:3+dmz_rwq_dmz-<SERIAL>_0`. While it copies data it waits for the disk in
uninterruptible sleep (state `D`), and **it can sit in D for long periods while working
normally.** After a 3.19 TB copy, all three reclaim workers sat in D in `dmz_reclaim_copy`
while they drained about 1.1 TB of buffered writes. That was expected.

During the stress test, a watch flagged "same reclaim threads in D on two polls". Checked by
hand, it was not a hang:

- stack `dmz_reclaim_copy <- dmz_reclaim_rnd_data <- dmz_do_reclaim`
- 10 to 21 new context switches per worker every 10 seconds
- 2,400 to 2,700 commands completed per drive every 10 seconds

The stack alone does not tell a busy worker from a hung one: both wait in `dmz_reclaim_copy`.
The progress counters do. **A hang is D state while the drive completes no commands.**

The two real incidents, both on kernel 7.2.6, both right after the array was reassembled
following a power event on the NAS:

1. After the NAS kernel panic, the chain reassembled the mappers and the array by itself, but
   one reclaim worker sat in D with zero disk I/O (write counters frozen). The pool held no
   data and the buffer was completely free (998/998). It went away only when the guest was
   restarted.
2. After the NAS had been shut down by mistake and powered on again, one reclaim worker was
   in D again after a clean boot. About an hour later it had cleared by itself.

There is no upstream bug report or fix for this. A later review of the kernel code suggested
a likely but unverified harmless mechanism: an idle reclaim loop that only sends TEST UNIT
READY to the drive and moves no data. According to the same review, genuinely blocked threads
would more likely wait in `dmz_reclaim_copy -> wait_on_bit_io`, a dm-zoned mutex,
`scsi_block_when_processing_errors` (port-multiplier error recovery), or `blk_wait_io` in the
per-disk `sdX_zwplugs_worker` thread (kernel 7.1 and later; its waits are invisible to the
kernel's 120 s hung-task detector). The stacks of the two incidents were not recorded. That is
why the metrics script now captures evidence automatically (2.7).

To check by hand:

```sh
# Which threads are in D right now?
ps -eLo stat,tid,comm | awk '$1 ~ /^D/'
cat /proc/<TID>/stack
grep ctxt_switches /proc/<TID>/status          # run twice; rising = making progress

# Are the drives completing commands? iodone_cnt is HEX: let the shell convert it.
drives() {
  for s in /sys/block/sd*; do
    [ "$(cat "$s/queue/zoned" 2>/dev/null)" = host-managed ] || continue
    printf '%s done=%d sectors_written=%s\n' "${s##*/}" "$(cat "$s/device/iodone_cnt")" "$(awk '{print $7}' "$s/stat")"
  done
}
drives; sleep 10; drives
```

> **Why `printf %d` and not `awk`:** `iodone_cnt` and `iorequest_cnt` are hexadecimal
> (`0x...`). awk reads them as 0. A hand-written watch that summed them with awk reported
> "no progress" while the drives were completing thousands of commands every 10 seconds.

### 1.6 Messages that look alarming but are normal

| What you see | Why it is fine |
|---|---|
| `ataN.05: failed to IDENTIFY (I/O error)` at every attach | Phantom port-multiplier port. Check the real links `ataN.00`-`.04` instead ([02](02-synology-controller-passthrough.md)). |
| `dmz_rwq_*` workers in D for a long time | Busy reclaim, as long as the drives keep completing commands (1.5). |
| A `dmz_fwq` worker in `submit_bio_wait` | dm-zoned's periodic metadata flush. |
| `md127_resync` in D | md's sync thread waiting for I/O. |
| About 128 open zones on each drive | dm-zoned manages the drive's open-zone budget itself. On this stack the open-zone count is not a fault signal. |
| `df` shows about 1 TB used on an empty pool | XFS metadata across 50 allocation groups. A one-time cost. |
| Buffer at 998/998 after a large copy | Expected. It drains while idle. |
| md repair crawling at about 10 MB/s | It yields to real I/O by design. |
| node_exporter logs an error from its `xfs` collector at every scrape on kernel 7.2 (`parsing "xpc"`) | Kernel 7.2's XFS statistics are newer than the exporter's parser. Cosmetic; you only lose that collector's XFS metrics. |
| Workqueue "hogged CPU" notices in `dmesg` on 7.2.6 | Seen during a resync, with no md, dm, XFS or ATA errors. Not investigated further. |

---

## 2. Monitoring

### 2.1 What you get

| Piece | Where it runs | File |
|---|---|---|
| Metrics script, every 5 minutes | guest | [scripts/guest/zoned-pool-metrics](../scripts/guest/zoned-pool-metrics) |
| node_exporter textfile collector | guest | Debian package `prometheus-node-exporter` |
| Alert rules | your Prometheus server | [monitoring/prometheus-rules.yml](../monitoring/prometheus-rules.yml) |
| Alert delivery | your Alertmanager | not included |

The metric names start with `hc680_` after the reference pool. The script and rules are
derived from the author's as-built versions. The differences are listed at the top of each
file. This exact script was not run on the reference system, so check its output after
installing (2.3).

### 2.2 Install the script and its timer

```sh
apt install prometheus-node-exporter smartmontools python3 curl
install -m 0755 scripts/guest/zoned-pool-metrics /usr/local/sbin/zoned-pool-metrics

cat > /etc/systemd/system/zoned-pool-metrics.service <<'EOF'
[Unit]
Description=Collect zoned pool metrics for node_exporter

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zoned-pool-metrics
EOF

cat > /etc/systemd/system/zoned-pool-metrics.timer <<'EOF'
[Unit]
Description=Collect zoned pool metrics every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now zoned-pool-metrics.timer
```

The timer settings are the as-built ones (the as-built units were called `hc680-metrics.*`).
The script writes `hc680.prom` into `/var/lib/prometheus/node-exporter`, the textfile
directory of Debian's `prometheus-node-exporter` package, where the as-built guest's
node_exporter picked it up without extra settings. If yours looks elsewhere, set
`Environment=HC_TEXTFILE_DIR=...` in the service. `HC_MOUNT` and `HC_MD` override the mount
point and the md device name (see the script header).

### 2.3 Check the output

```sh
systemctl start zoned-pool-metrics.service
systemctl status zoned-pool-metrics.service --no-pager
cat /var/lib/prometheus/node-exporter/hc680.prom
curl -s http://localhost:9100/metrics | grep -E '^(node_textfile_scrape_error|hc680_array_up|hc680_dmzoned_buffer_ratio|hc680_smart_ok|hc680_smart_health_known)'
```

`node_textfile_scrape_error` must be `0`, and the `hc680_` series must be there. For each
host-managed drive, expect one `hc680_smart_ok` line and one `hc680_smart_health_known` line,
both `1`. Unreadable health (including SMART disabled) produces `health_known 0` and no
`smart_ok` sample; investigate it even if the rest of the metrics file is fresh.

> **Why check the endpoint and not just the file:** one malformed line makes node_exporter
> drop the **whole** file. It happened twice in this project: once because values for the
> same metric were printed interleaved with other metrics (the text format requires each
> metric family in one block), and once because a `grep -c ... || echo 0` printed a stray
> `0` line. Both times every pool metric vanished silently.

Then check that the stuck-worker detection can actually see your threads. While the pool is
writing:

```sh
ps -eLo comm | grep -E 'dmz_rwq|zwplugs' | sort | uniq -c
lsblk -dno NAME,SERIAL
```

The script looks for `dmz_rwq_dmz-<serial of the drive>` and `<sdX>_zwplugs_worker`. On the
reference drives the dm-zoned labels came out as `dmz-<serial>`, so the first pattern
matched. If your worker names differ, the D-state gauges stay at 0 forever and the stuck-worker
alert can never fire. Adjust the pattern in the script. The `zwplugs` thread exists only on
kernel 7.1 and later.

### 2.4 Prometheus: scrape the guest and load the rules

On your Prometheus server, from the root of a checkout of this repository:

```yaml
# prometheus.yml (excerpt)
scrape_configs:
  - job_name: zoned-pool-guest
    static_configs:
      - targets: ['<GUEST_IP>:9100']

rule_files:
  - /etc/prometheus/rules/*.yml
```

```sh
promtool check rules monitoring/prometheus-rules.yml
install -D -m 0644 monitoring/prometheus-rules.yml /etc/prometheus/rules/zoned-pool.yml
systemctl reload prometheus        # or send SIGHUP to the Prometheus process
```

In the Prometheus web UI, the Alerts page should list the ten `Hc680*` rules, all healthy
and inactive.

> **Why keep backups out of the rules directory:** a glob loads every matching file. In the
> author's monitoring setup, backup copies left in a rules directory were loaded as live
> rules, and every alert fired three times. Put backups somewhere else.

> **Why test delivery end to end:** a green alerting stack is not proof that anyone gets
> paged. In this project, 1,884 notifications once went into a cache that nobody read. Inject
> a test alert at the top of the chain, for example with `amtool alert add`, and check that it
> reaches you.

### 2.5 The alerts

| Alert | Fires when | Severity | What it means, first step |
|---|---|---|---|
| `Hc680PoolDown` | `hc680_array_up == 0` for 5 min | critical | The array is missing or `/srv/hc680` is not mounted. Walk the chain ([4.1](#41-pool-not-mounted-after-boot-walk-the-chain)). |
| `Hc680ArrayDegraded` | fewer active members than expected, for 2 min | critical | No redundancy left. Check `dmsetup ls` first: the missing member may be a mapper, not a drive ([3.7](#37-replacing-a-drive-tested-2026-09-28)). |
| `Hc680ParityMismatches` | `mismatch_cnt > 0` for 15 min | warning | Expected during the first repair after `--assume-clean`. After a completed repair, run a `check`; mismatches found then are real ([3.2](#32-parity-check-and-repair)). |
| `Hc680SmartFailed` | SMART overall health not passed, 5 min | critical | Plan a replacement ([3.7](#37-replacing-a-drive-tested-2026-09-28)). |
| `Hc680SmartUnknown` | `hc680_smart_health_known == 0` for 30 min | warning | Health cannot be read: SMART may be disabled or the drive is not answering. Check `smartctl -H -A` on that drive (3.5). |
| `Hc680DriveHot` | drive above 55 C for 15 min | warning | Airflow in the expansion unit. The reference drives ran at 42-44 C. |
| `Hc680WriteBufferFull` | buffer ratio above 0.85 for 30 min | info | Not a fault: throughput is reduced until the pool has been idle for a while (1.2). Full while idle for hours means reclaim is not working ([4.2](#42-stuck-reclaim-worker)). |
| `Hc680ReclaimWorkerStuck` | see 2.6 | critical | A dm-zoned reclaim worker is hung ([4.2](#42-stuck-reclaim-worker)). |
| `Hc680ZoneWriteWorkerStuck` | see 2.6 | critical | The per-disk zone-write thread is hung ([4.2](#42-stuck-reclaim-worker)). |
| `Hc680MetricsStale` | no fresh metrics for 20 min, or none at all, for 10 min | warning | Timer stopped, script failing, file rejected by node_exporter, or the guest is down. While it fires, the other alerts work from old values or none. |

Notes:

- **`Hc680PoolDown` after a guest power cycle.** The metrics timer first runs 3 minutes after
  boot. If the drives are late, the pool can be reported down for a few minutes and the alert
  may fire briefly. Raise `for:` if that bothers you.
- **`Hc680MetricsStale` covers the guest being down.** When node_exporter cannot be scraped,
  the `hc680_` series disappear. `Hc680PoolDown` then cannot fire, but `Hc680MetricsStale`
  does: its second half fires for every target of the `zoned-pool-guest` job whose `up` series
  exists without a matching `hc680_metrics_timestamp_seconds`. It is per target, so with
  several guests one healthy guest does not hide a missing one. Keep the job name in the rule
  and in the scrape config the same.
- **`Hc680ParityMismatches` stays on after the initial repair.** md keeps the count from the
  last `check` or `repair` until the next one starts. After the repair that fixed the
  mismatches, the count stays until you run a `check`.
- The 55 C threshold matches the temperature limit set in OpenMediaVault's SMART settings
  on the reference guest (3.5).

### 2.6 Hang or busy: how the stuck-worker rules decide

Each 5-minute run of the script records, per mapper:

- `hc680_dmzoned_reclaim_dstate`: 1 if that mapper's reclaim worker is in D **at that
  instant**.
- `hc680_zwplugs_worker_dstate`: the same for the drive's `sdX_zwplugs_worker` thread.
- `hc680_drive_io_sectors_total`: sectors read and written by the physical drive.
- `hc680_drive_ata_requests_total{kind="done"}`: SCSI commands the drive has completed,
  including TEST UNIT READY. (`kind="issued"` counts those dispatched.)
- `hc680_dmzoned_reclaim_ctxt_switches_total` and `hc680_drive_inflight`, for diagnosis.

`Hc680ReclaimWorkerStuck` fires only when **all three** hold for 20 minutes, and then for 5
more minutes:

```
  min_over_time(hc680_dmzoned_reclaim_dstate[20m]) == 1        # in D at every sample
and on (job, instance, mapper, drive)
  sum by (job, instance, mapper, drive) (increase(hc680_drive_io_sectors_total[20m])) == 0     # no data moved
and on (job, instance, mapper, drive)
  sum by (job, instance, mapper, drive) (increase(hc680_drive_ata_requests_total{kind="done"}[20m])) == 0
                                                                # no command completed
```

| Situation | In D? | Sectors | Commands done | Alert |
|---|---|---|---|---|
| Busy reclaim (the normal case under load) | often | rising | rising | no |
| Reclaim loop sending only TEST UNIT READY (suspected, harmless) | yes | flat | rising | no |
| Real hang | yes | flat | flat | **yes** |

`Hc680ZoneWriteWorkerStuck` does the same for the `zwplugs` thread, with the command counter
only.

> **Why the command counter:** the first version of the rule used only D state plus sectors.
> A worker that loops on TEST UNIT READY moves no sectors but keeps completing commands, and
> the kernel review suggested exactly that as the likely harmless explanation for the
> incidents. The second counter separates that case from a real hang.
>
> **Why 20 minutes:** D state is sampled only every 5 minutes, so 20 minutes means four
> consecutive samples. The drives complete thousands of commands per 10 seconds while
> working, so a 20-minute window with zero completions is not a busy pool.

### 2.7 Automatic evidence capture

A hung worker is gone after the reboot that fixes it, so the script records the state while
it lasts. When a reclaim or zone-write thread is in D on **two consecutive runs** (5 minutes
apart) **and** the summed `iodone_cnt` of all host-managed drives has not changed between
them, it writes a file to `/var/log/hc680-dmz-evidence/`:

- all threads in D, and the kernel stacks and `wchan` of those related to dm-zoned, kcopyd,
  zone write plugs, md, XFS and dm-crypt
- `dmsetup status` of every mapper
- per drive: in-flight requests, `iorequest_cnt`, `iodone_cnt`, `ioerr_cnt`, `stat`, and the
  zone write plugs from debugfs (if debugfs is mounted and the kernel has them)
- the md section of `/proc/mdstat` and the last 60 lines of `dmesg`

It keeps the newest 20 files. The state between runs is kept in `/run/hc680-dmz-dstate`.

Limitation: the "no progress" test sums all drives. If one drive hangs while the others keep
working, nothing is captured, although the per-mapper alert still fires. Capture by hand in
that case ([4.2](#42-stuck-reclaim-worker)).

> **Why only when the drives stop:** the first capture rule fired on D state alone. That
> would have triggered during every large copy, because busy reclaim sits in D.

### 2.8 What this monitoring does not cover

- **The NAS.** A kernel panic in DSM, DSM's own arrays, and the attach watcher are not
  watched here. A missing controller shows up only indirectly, as `Hc680PoolDown` or
  `Hc680MetricsStale`. The author sends the NAS kernel log to another machine over netconsole,
  which is the only reason the panic could be analysed ([01](01-requirements-and-risks.md)).
- **The guest's kernel log.** No rule here matches kernel messages. The lesson from the
  earlier btrfs design was that only kernel log lines showed a silent failure
  ([06](06-alternatives-and-lessons.md)). If you ship logs to a log server, consider alerting
  on XFS, md, `device-mapper: zoned` and ATA error lines. That is a suggestion; the as-built
  rules do not do it.
- **mdadm's own monitor** mails `root` on array events (`MAILADDR root` in `mdadm.conf`). That
  only helps if mail from the guest reaches someone.

---

## 3. Maintenance

### 3.1 Quick health check

```sh
cat /proc/mdstat                                   # md127 ... [3/3] [UUU]
mdadm --detail /dev/md/hc680 | grep -E 'State :|Active Devices|Failed Devices'
cat /sys/block/md127/md/mismatch_cnt
cat /sys/block/md127/md/stripe_cache_size          # 8192 as built; a runtime setting (03, step 5)
for m in dz1 dz2 dz3; do echo "$m $(dmsetup status $m)"; done
findmnt /srv/hc680                                 # from /dev/mapper/hc680crypt
systemctl --failed
ps -eLo stat,tid,comm | awk '$1 ~ /^D/'            # D state is fine while the drives work (1.5)
ls /var/log/hc680-dmz-evidence/ 2>/dev/null        # should be empty
dmesg --level=err,warn | grep -vE 'ata[0-9]+\.05' | tail -20
```

### 3.2 Parity check and repair

A `check` reads every stripe and counts mismatches without changing anything. A `repair` also
rewrites parity where it does not match. On RAID5, repair recomputes parity from the data
blocks; it cannot tell which block was actually wrong.

```sh
cat /sys/block/md127/md/sync_action                # must be "idle" before you start
echo check > /sys/block/md127/md/sync_action
cat /proc/mdstat                                   # progress and speed (a repair shows as "resync")
cat /sys/block/md127/md/mismatch_cnt               # after it finishes
echo idle > /sys/block/md127/md/sync_action        # to stop a running pass
```

What to expect:

- A full pass runs at about 173-205 MB/s on an idle pool and takes about 33-40 hours.
- **Reference result:** the mandatory repair after the build finished on 2026-09-28 with
  **0 mismatches**, after 40.5 hours (2026-09-26 09:30 to 09-28 02:04), while 3.19 TB of media and a Hyper Backup seed were
  written into the pool at the same time.
- It yields to real I/O. Under heavy writes it drops to its minimum speed, 10 MB/s on the
  reference guest (`/sys/block/md127/md/sync_speed_min`, `/proc/sys/dev/raid/speed_limit_min`).
- dm-zoned answers reads of never-written areas from its metadata, so the drives do almost no
  physical I/O there.
- An interrupted `repair` or `check` can come back as a `resync` from its checkpoint. That
  happened when the NAS was shut down in the middle of a repair. The kernel's md
  documentation counts mismatches for `check` and `repair`, and only "possibly" for
  `resync`. Run a `check` afterwards if you need a trustworthy number.

> **Why the repair after creation is mandatory:** the array was created with
> `mdadm --create --assume-clean` over freshly formatted dm-zoned devices, on the reasoning
> that they read back as zeros. The first repair found **752** mismatches. Until a full repair
> has run, a drive failure can rebuild wrong data ([03, step 6](03-guest-storage-stack.md#step-6---run-a-full-parity-repair-mandatory-after---assume-clean)).

How often to run a `check` is your decision; the author's schedule is not recorded. Debian's
`mdadm` package may schedule periodic checks by itself. See what is scheduled on your guest:

```sh
systemctl list-timers --all | grep -iE 'mdcheck|checkarray'
```

If a `check` **after** a completed repair finds mismatches, stop and investigate before you
run another repair: `dmesg` for I/O errors, SMART on every drive, and `ioerr_cnt` under
`/sys/block/sdX/device/`.

### 3.3 Kernel updates and re-running the benchmark

The kernel decides whether this pool runs at 25 MB/s or 165 MB/s (1.3). Newer is not
automatically faster: Zabbly's 7.2.7 build reached less than half of Ubuntu's 7.2.6 on the
single-writer test. Treat every kernel change as a test.

The author keeps Debian 6.12.107, Debian backports 7.1.8 and Zabbly 7.2.7 installed as
fallbacks, with the Zabbly apt source disabled so that its kernel updates do not arrive
automatically. The running kernel is pinned by GRUB entry id
([03, step 2c](03-guest-storage-stack.md#2c-pin-the-kernel-by-entry-id)).

Procedure:

1. **Record a baseline** on the current kernel with the benchmark below, if you have none.
2. **Install the new kernel** next to the old ones. Do not remove the old ones.
3. **Check its configuration:**

   ```sh
   k=<NEW_KERNEL_VERSION>
   grep -E '^CONFIG_(BLK_DEV_ZONED|DM_ZONED|MD_RAID456|DM_CRYPT|XFS_FS)=' /boot/config-$k
   grep -E 'CONFIG_XFS_ONLINE_SCRUB' /boot/config-$k      # see 3.4
   ```

4. **Pause the writers:** Hyper Backup, rsync pushes, and any md `check` or `repair`.
5. **Boot the new kernel once** with `grub-reboot`, as in
   [03, step 2b](03-guest-storage-stack.md#2b-boot-the-new-kernel-once-before-you-pin-it). A
   reboot inside the guest keeps the controller attached.
6. **Check the chain:** `systemctl --failed`, `cat /proc/mdstat`, `findmnt /srv/hc680`.
7. **Check the monitoring:** run the metrics script and look at the endpoint (2.3), including
   the worker names. Kernel changes can rename threads.
8. **Run the benchmark** and compare with the baseline.
9. **Watch for a stuck reclaim worker** for a while. Both incidents came right after the
   array had been reassembled.
10. **Pin it or drop it.** If it is better, change `GRUB_DEFAULT` to the new entry id and run
    `update-grub`. If not, reboot: the pin still points at the old kernel.

**The benchmark.** The author's exact command lines were not recorded. The `fio` jobs below
reproduce the same two tests (60 seconds, one O_DIRECT writer with 1 MiB blocks; four
buffered writers including the final flush), but they are not the original commands.
Compare kernels only against a baseline taken with these same commands on your own pool.

Install `fio` first. Pause all other writers before running the benchmark; the block below
requires md to be idle and at least 90 % of each random-zone buffer to be free. Adjust
`md127` to your array's kernel name if necessary.

```sh
apt install fio
```

> [!WARNING]
> This benchmark creates up to 84 GiB of test files and writes into them for 60 s per job.
> On success, its final command deletes
> only the unique directory created by `mktemp` in this run. If a prerequisite or job fails,
> the subshell aborts; any test directory already created is left for inspection. After
> inspecting it, remove only the directory printed as `Benchmark directory:` with
> `rm -rf -- /srv/hc680/bench.<suffix>`, replacing `<suffix>` with that run's exact suffix.
> Never substitute an existing directory or remove `/srv/hc680/bench`.

```bash
(
  set -euo pipefail
  command -v fio >/dev/null || { echo 'fio is not installed; STOP' >&2; exit 1; }
  mountpoint -q /srv/hc680 || { echo 'Pool is not mounted; STOP' >&2; exit 1; }
  [ "$(cat /sys/block/md127/md/sync_action)" = idle ] \
    || { echo 'md is not idle; STOP' >&2; exit 1; }
  for m in dz1 dz2 dz3; do
    dmsetup status "$m" | awk '
      /[0-9]+\/[0-9]+ random/ {
        for (i=1; i<NF; i++) if ($(i+1)=="random") {
          split($i,z,"/"); print $i " random";
          if (z[2]>0 && z[1]/z[2]>=0.90) ready=1
        }
      }
      END { exit !ready }' || { echo "$m buffer is not ready; STOP" >&2; exit 1; }
  done
  bench=$(mktemp -d /srv/hc680/bench.XXXXXXXX)
  printf 'Benchmark directory: %s\n' "$bench"
  cd "$bench"

  fio --name=direct-1 --directory="$bench" --rw=write --bs=1M --direct=1 \
      --ioengine=psync --size=20G --time_based --runtime=60 --numjobs=1

  fio --name=buffered-4 --directory="$bench" --rw=write --bs=1M --direct=0 \
      --ioengine=psync --size=16G --time_based --runtime=60 --numjobs=4 \
      --end_fsync=1 --group_reporting

  cd /srv/hc680
  rm -rf -- "$bench"
)
```

Read the `WRITE: bw=` line of each run. Run each test three times: the Zabbly kernel gave
58, 69 and 68 MiB/s in three runs of the same test. Each run consumes buffer zones: leave
the pool idle between repeats until every mapper's printed `random` counts are back to at
least 90 % free, otherwise the block stops before writing. Idle reclaim frees about 7 zones
per minute per drive (1.2); deleting the test files alone does not guarantee this recovery.
Note the buffer occupancy before each run,
because a fuller buffer is slower. If you want to see what reaches the drives, run
`iostat -x 5` from the `sysstat` package in a second terminal and look at the average write
size of the `dm-*` and `sd*` devices. On every kernel tested so far it was 4 KiB.

> **Why the `mountpoint` guard:** twice during testing, the author wrote into an unmounted
> mount point because an array or mount had failed silently. The second time it filled the
> test machine's root disk.

### 3.4 `xfs_scrub_all.timer`

Debian enables `xfs_scrub_all.timer` by default. On the reference guest it is scheduled for
Sundays at 03:10, and on kernels that support XFS online scrub it includes a full media scan
of all file data once a month.

```sh
grep CONFIG_XFS_ONLINE_SCRUB /boot/config-$(uname -r)
systemctl list-timers xfs_scrub_all.timer
```

- **`# CONFIG_XFS_ONLINE_SCRUB is not set`** (Ubuntu's 7.2.6): the scrub cannot run at all.
  On such a kernel `xfs_scrub` reports that the kernel metadata scrubbing facility is not
  available. On the reference guest the timer is still enabled and does nothing.
- **`CONFIG_XFS_ONLINE_SCRUB=y`** (Debian's 7.1.8 and Zabbly's 7.2.7, for example): it does real
  work. A media scan reads every file's data through LUKS, md and dm-zoned, competing with
  backups and reclaim at a fixed time of the week. Decide whether you want that. XFS has no
  data checksums, so the scan finds read errors, which a full md `check` also finds. To turn
  it off:

  ```sh
  systemctl disable --now xfs_scrub_all.timer
  ```

### 3.5 SMART

On the reference guest, OpenMediaVault's SMART monitoring is enabled for the three drives
(by-id): check interval 1800 s, power mode "never", temperature limit 55 C, and a weekly
short self-test on Sundays at 06:00 (`smartd` schedule `S/../../7/06`). This was set up on the
same drives during an earlier build of the pool. SMART works through the passed-through
controller as on any SATA controller:

```sh
smartctl -H -A /dev/sdb
smartctl -l selftest /dev/sdb
```

The metrics script exports overall health and temperature (`Hc680SmartFailed`,
`Hc680DriveHot`). It also emits `hc680_smart_health_known` for every detected host-managed
drive: `0` means health could not be read (including SMART disabled, invalid JSON or a
device not answering), and fires `Hc680SmartUnknown` after 30 minutes. In that case there
is no `hc680_smart_ok` or temperature sample for the drive. It does not pass `-n standby`,
so it would wake a drive that had spun down.
The reference drives never spin down.

After a drive replacement, add the new drive's by-id to OMV's SMART settings and check that
both health gauges are `1` (2.3). This gauge covers detected drives; a drive missing from
`lsblk` is handled by the pool/array alerts, not `Hc680SmartUnknown`.

### 3.6 Keep the key material current

- Make a new LUKS header backup after every keyslot change
  ([03, step 7f](03-guest-storage-stack.md#7f-back-up-the-luks-header)). Old header backups
  still open the data with keyslots you have since removed. Guard them like keys.
- Keep the keyfile or a passphrase, and a header backup, somewhere off the pool and off the
  guest. If you lose the keyfile and every passphrase, the data is gone.

### 3.7 Replacing a drive (tested 2026-09-28)

> **Tested once.** On 2026-09-28 a healthy member was pulled hot while reads ran, put back
> into a different bay, re-formatted, and rebuilt with the steps below. Pulling a member of
> a healthy array is the realistic stand-in for a failed drive, but it is one run on one
> machine. Read every step before you start, and keep the backup of the pool's contents
> current: RAID5 survives exactly one failure, and a second problem during the rebuild
> loses the array.
>
> **Plan for the time.** Without a cache device the rebuild took **about 10 days**
> ([08, section 2](08-caching.md#2-what-a-member-rebuild-costs-without-a-cache)), all of it
> without redundancy. With a cache device for the new member it takes 2-3 days
> ([08, section 3](08-caching.md#3-dm-zoned-cache-devices)).

**What changes compared with the old design.** In the SnapRAID design a dead drive took the
whole pool offline, and the rebuild restored file contents but not ownership or permissions.
md works on blocks: a degraded RAID5 keeps serving data, and a rebuild restores everything,
ownership included. What carries over is the dangerous moment. The old test showed that the
recovery command is exactly where an operator can point at the wrong target. With md, the
wrong target is a **surviving member**.

1. **Find the failed member.**

   ```sh
   cat /proc/mdstat
   mdadm --detail /dev/md/hc680
   dmsetup ls
   lsblk -o NAME,SERIAL,MODEL,ZONED
   cat /etc/zonedpool/dmzoned.conf                  # by-id path (with serial) -> dzN
   ```

   If the drive is healthy and only its mapper is missing, for example after a late drive at
   boot, re-create the mapper and put it back instead of replacing anything:

   ```sh
   /usr/local/sbin/zonedpool-dmzassemble            # creates only the missing mappers
   mdadm /dev/md/hc680 --re-add /dev/mapper/dzN
   ```

   If md refuses `--re-add`, `--add` works too but rebuilds the whole member. A lab test of
   dm-zoned under md showed that a member that arrives late, after md has started the array
   degraded, needs `--re-add`. On the final stack this is untested. **Without a write-intent
   bitmap, `--re-add` of a member that md has already failed does not work: the other members'
   event count has moved on, so it is `--add` and a full rebuild.** The reference array has no
   bitmap ([03, Step 5](03-guest-storage-stack.md#step-5---create-the-raid5)).

   **After a hot pull and re-insert, the old mapper is still there.** md keeps `dzN` open and
   `dzN` still points at the vanished device, so the drive comes back under a **new** kernel
   name (`sdd` became `sdg` in the test). The by-id link follows the drive, but the mapper does
   not: remove it (step 3) before you re-create it.

2. **Reduce writes.** Pause the Hyper Backup task and stop rsync pushes. Every write while
   degraded runs without redundancy, and writes slow down the rebuild.

3. **Remove the failed member from the array**, if md has not already done so, and remove its
   mapper:

   ```sh
   mdadm /dev/md/hc680 --fail /dev/mapper/dzN --remove /dev/mapper/dzN
   dmsetup remove dzN
   ```

   A member that is **still rebuilding** answers the remove with `hot remove failed ...
   Device or resource busy` until md has stopped the recovery thread. The `--fail` has
   worked by then; repeat the `--remove` a few seconds later.

   If the mapper has already disappeared, `mdadm /dev/md/hc680 --remove failed` (or
   `--remove detached`) removes md's leftover entry.

4. **Swap the drive.** Hot-swapping on the passed-through 9235 worked in the test, with one
   side effect: **every hot-plug event freezes all drives behind the same port multiplier.**
   libata's error handling resets the multiplier's control port and every port on it. Measured
   with reads running: pulling a member froze the two others for **12 s**, inserting a drive
   froze them for **25 s** (the new drive was slow to spin up). In both cases the other members
   logged 0 errors: their commands waited and then completed. The DX1222 has three bays per
   port multiplier, so plugging a drive into a bay next to the pool's members freezes the pool
   for that long. If you run anything with short timeouts on the pool, stop it first. The
   conservative route still exists: shut the guest down cleanly, swap the drive, start the
   guest; the watcher re-attaches the controller. Remember that starting a guest that carries
   the controller is the situation the NAS panic was correlated with
   ([01, 7.1](01-requirements-and-risks.md#71-nas-kernel-panic-in-dsms-own-storage-driver)).

   On the NAS: while a drive is missing, or if the new drive is a different model, the
   watcher's model census no longer matches (`ZONED_COUNT`, `ZONED_MODEL`). While the
   controller is still on `vfio-pci` (attached earlier), the watcher keeps using the address it
   recorded. After a NAS reboot the controller is back on `ahci`, and the watcher refuses to
   take it from DSM without a matching census: set `ZONED_COUNT` / `ZONED_MODEL` to the drives
   actually present. If you change the config, restart the
   watcher ([02](02-synology-controller-passthrough.md#after-editing-the-config-restart-the-watcher)).

5. **Identify the new drive** in the guest, as in
   [03, step 0](03-guest-storage-stack.md#step-0---check-what-the-guest-sees): host-managed,
   the expected `nr_zones`, and a serial that is **not** in `dmzoned.conf`.

   ```sh
   ls -l /dev/disk/by-id/ | grep WSH722870 | grep -v -- -part
   ```

6. **Format the new drive for dm-zoned.**

   > **DESTRUCTIVE.** `dmzadm --format` resets every zone. On a degraded RAID5, formatting a
   > **surviving** member destroys the array. Compare the serial three times with step 5.

   ```sh
   dmzadm --format /dev/disk/by-id/ata-WDC_WSH722870ALE604_<NEW_SERIAL>
   ```

7. **Point the config at the new drive**, keeping the old mapper name, and create the mapper:

   ```sh
   editor /etc/zonedpool/dmzoned.conf              # replace the old by-id line, keep "dzN"
   /usr/local/sbin/zonedpool-dmzassemble
   lsblk -o NAME,SIZE,ZONED /dev/mapper/dzN        # ~24.6T, ZONED none
   ```

   > **Why run the script and not `systemctl restart zonedpool-dmzassemble`:** the array,
   > LUKS and mount units `Require` that unit. Restarting it restarts them too, which means
   > unmounting the pool and closing LUKS under whatever is using it. The script on its own
   > only creates missing mappers.

8. **Add it to the array and let it rebuild:**

   ```sh
   mdadm /dev/md/hc680 --add /dev/mapper/dzN
   cat /proc/mdstat                                # "recovery = ..."
   ```

   The rebuild writes the entire member, about 24.6 TiB, through dm-zoned. **Measured:**
   80-93 MB/s for about 55 minutes while the new member's own buffer fills, then 26-30 MB/s,
   because every chunk goes through that buffer and reclaim on the same drive. md estimated
   **about 10 days**. With a cache device formatted together with the new drive
   (`dmzadm --format <cache> <drive>`, [08, section 3.3](08-caching.md#33-how-to-set-it-up)),
   the rebuild ran at 73-178 MB/s: 2-3 days. Keep writes low until it finishes. The
   re-format in step 6 took 12 s.

9. **Afterwards:** `mdadm --detail` shows 3 active devices and `clean`; run a `check`
   (3.2); check that the metrics show the new drive and that its reclaim worker name matches
   (2.3); add the drive to OMV's SMART monitoring (3.5). The array UUID does not change, so
   `mdadm.conf` stays as it is.

**Alternative for a drive that is failing but still readable (untested):** md can copy onto a
new member while the old one is still in the array, keeping redundancy during the copy
(`mdadm /dev/md/hc680 --add /dev/mapper/dzNEW`, then
`mdadm /dev/md/hc680 --replace /dev/mapper/dzN --with /dev/mapper/dzNEW`). That needs a fourth
drive behind the controller at the same time. The expansion unit has free slots behind the
port multipliers, but a fourth zoned drive also breaks the watcher's census until you update
`ZONED_COUNT`.

---

## 4. Recovery playbook

A general rule from the author's operation: **avoid unnecessary restarts of the guest that
carries the controller.** When the pool has a problem, try to fix it in place (remount,
re-run a unit) before you restart the guest. If you must restart, prefer a reboot inside the
guest, which keeps the controller attached, over a VMM power cycle.

### 4.1 Pool not mounted after boot: walk the chain

**Symptom:** `Hc680PoolDown`, `findmnt /srv/hc680` prints nothing, shares and the backup
target are unavailable.

First give it time. After a VMM power cycle the drives appear only minutes into the guest's
boot, and the chain waits for them. Follow it live:

```sh
journalctl -b -t zonedpool -f
```

If it is really stuck, walk the chain from the bottom up. Stop at the first layer that is
wrong.

1. **Does the guest see the drives?**

   ```sh
   lsblk -d -o NAME,SIZE,MODEL,ZONED
   lspci -nn | grep 1b4b:9235
   ```

   No controller: go to [4.4](#44-controller-not-attached). Controller but no drives after
   3 minutes: check the real links with `dmesg | grep -E 'ata[0-9]+\.0[0-4]'`, and the
   expansion unit's power and cable.

2. **Mappers:**

   ```sh
   systemctl status zonedpool-dmzassemble --no-pager
   journalctl -b -t zonedpool                      # "appeared after", "still absent", "FAILED"
   dmsetup ls
   cat /etc/zonedpool/dmzoned.conf
   ls -l /dev/disk/by-id/ | grep WSH722870 | grep -v -- -part
   ```

   A by-id path in the config that does not exist (a replaced drive, a typo) leaves that
   mapper out. `start condition unmet` means `/etc/zonedpool/dmzoned.conf` is missing.

3. **Array:**

   ```sh
   systemctl status zonedpool-mdassemble --no-pager
   cat /proc/mdstat
   mdadm --examine /dev/mapper/dz1 | grep -E 'Array UUID|Name'
   grep '^ARRAY' /etc/mdadm/mdadm.conf
   ```

   `start condition unmet` means `/etc/mdadm/mdadm.conf` is missing; systemd skipped the
   unit because `ConditionPathExists` was not met. If the file exists, the two UUIDs must
   be the same.

   > **Why compare UUIDs:** after a rebuild of the array, and again after the NAS crash
   > (4.5), `mdadm.conf` still held the old array's UUID. `mdadm --assemble --scan` then finds
   > nothing to assemble. Read the right line from the members, not from the kernel
   > (`mdadm --detail --scan` only lists arrays that are running):
   >
   > ```sh
   > mdadm --examine /dev/mapper/dz1 /dev/mapper/dz2 /dev/mapper/dz3 | grep 'Array UUID'   # all the same?
   > mdadm --examine --scan /dev/mapper/dz1 /dev/mapper/dz2 /dev/mapper/dz3
   > ```
   >
   > Replace only this pool's `ARRAY` line in `/etc/mdadm/mdadm.conf` with that output and run
   > `update-initramfs -u`.

   If `/proc/mdstat` shows `md127 : inactive ...`, the array was started incomplete. Once
   all three mappers exist and carry the pool's Array UUID (above), release it and assemble
   it explicitly. `systemctl start zonedpool-mdassemble` alone may do nothing: the oneshot
   unit is still `active (exited)` from its earlier run.

   ```sh
   mdadm --stop /dev/md127                         # only for an INACTIVE array, never a mounted one
   mdadm --assemble /dev/md/hc680 /dev/mapper/dz1 /dev/mapper/dz2 /dev/mapper/dz3
   cat /proc/mdstat                                # expect [3/3] [UUU]
   ```

   Then continue with the LUKS layer (`systemctl restart zonedpool-cryptopen`) and the mount.

   If the array runs degraded (`[UU_]`), see [3.7](#37-replacing-a-drive-tested-2026-09-28),
   step 1.

4. **LUKS:**

   ```sh
   systemctl status zonedpool-cryptopen --no-pager
   cryptsetup status hc680crypt
   ls -l /etc/zonedpool/hc680.key
   cryptsetup luksDump /dev/md/hc680 | head -20
   ```

   `start condition unmet` means the keyfile is missing: restore it, or unlock by hand with a
   passphrase (`cryptsetup open /dev/md/hc680 hc680crypt`). If `luksDump` says the device is
   not a valid LUKS device although the array is assembled correctly, go to
   [4.3](#43-luks-header-restore).

   **With the volume cache of [08, section 4](08-caching.md#4-a-volume-cache-between-the-raid-and-luks)**
   there is one more link before LUKS: `systemctl status zonedpool-volcache` and
   `dmsetup status hc680cache`. LUKS must then be opened on `/dev/mapper/hc680cache`, **never**
   on `/dev/md/hc680`, including a manual unlock with a passphrase. Opening it on the raw array
   bypasses data that is still dirty in the cache. If `hc680cache` is missing, check the volume
   group first (`vgs hc680ssd`, `lvs hc680ssd`; `vgchange -ay hc680ssd`), then
   `systemctl start zonedpool-volcache`.

5. **Filesystem:**

   ```sh
   systemctl status srv-hc680.mount --no-pager
   journalctl -b -u srv-hc680.mount
   blkid -s UUID -o value /dev/mapper/hc680crypt
   grep /srv/hc680 /etc/fstab
   dmesg | grep -i xfs | tail
   ```

   The UUID in fstab (or in OMV's mount entry) must be the filesystem's UUID. After a rebuild
   and after the NAS crash, fstab still pointed at the old filesystem.

6. **Bring it up.** After fixing the cause, start the mount. It pulls in every unit of the
   chain that is not running yet:

   ```sh
   systemctl reset-failed
   systemctl start srv-hc680.mount
   findmnt /srv/hc680
   findmnt /export/media
   exportfs -ra
   ```

   If the NFS bind mount is missing, `systemctl start export-media.mount` (the unit name
   follows the path, see [04](04-openmediavault-and-synology-integration.md)). DSM does not
   retry its NFS remote folder by itself: re-mount it in File Station
   ([04, section 11](04-openmediavault-and-synology-integration.md#11-nfs-remote-folder-in-dsm-file-station)).

> **Do not restart `zonedpool-dmzassemble` on a running pool.** Everything after it in the
> chain `Requires` it, so a restart also restarts the array, LUKS and mount units: the pool is
> unmounted and LUKS closed under whatever is using it.
>
> **Do not run `omv-salt deploy run fstab` while the stack is unhealthy.** The deploy mounts
> as a side effect. During the stuck-worker incident the author deliberately avoided it
> ([04](04-openmediavault-and-synology-integration.md)).

### 4.2 Stuck reclaim worker

**Symptom:** `Hc680ReclaimWorkerStuck` or `Hc680ZoneWriteWorkerStuck`, or writes to the pool
hang, or the pool did not mount after a restart and a `dmz_rwq_*` worker is in D.

1. **Make sure it is a hang, not busy reclaim.** Use the commands in
   [1.5](#15-reclaim-workers-in-d-state-busy-is-not-hung). A hang is D state with the drive's
   `iodone_cnt` and sectors frozen over minutes. Rising context switches and completed
   commands mean it is working.

2. **Save the evidence** before anything else. The script writes it automatically if all
   drives stopped completing commands:

   ```sh
   ls -lt /var/log/hc680-dmz-evidence/ | head
   ```

   If there is nothing, capture by hand:

   ```sh
   f=/root/dmz-hang-$(date +%Y%m%d-%H%M%S).txt
   {
     uname -r; date -Is
     ps -eLo stat,tid,comm | awk '$1 ~ /^D/'
     for t in $(ps -eLo stat=,tid= | awk '$1 ~ /^D/ {print $2}'); do
       echo "--- $t $(cat /proc/$t/comm)"; cat /proc/$t/stack
     done
     for m in dz1 dz2 dz3; do dmsetup status $m; done
     cat /proc/mdstat
     dmesg | tail -100
   } > "$f" 2>&1
   echo w > /proc/sysrq-trigger       # adds a list of blocked tasks with stacks to dmesg
   dmesg | tail -200 >> "$f"
   ```

3. **Look for a cause below dm-zoned:** ATA errors or link resets on the real ports in
   `dmesg` (`ataN.00` to `.04`). Port-multiplier error recovery would point at the
   controller or the link rather than at dm-zoned.

4. **Give it some time** if nothing depends on the pool right now. One of the two incidents
   cleared by itself within about an hour.

5. **If it does not clear:** stop the writers (pause Hyper Backup in DSM, stop rsync pushes),
   then reboot the guest from inside:

   ```sh
   systemctl reboot
   ```

   The pool reassembles, unlocks and mounts by itself. A reboot inside the guest keeps the
   controller attached. If the reboot hangs because the stuck device blocks the shutdown,
   the remaining option is a power off and start from VMM. That is a guest start with the
   controller, the situation the NAS panic was correlated with, and the watcher has to
   re-attach the controller. How the guest was restarted in the incident that needed it was
   not recorded.

6. **After the reboot:** check `cat /proc/mdstat` and let any resync finish, then run a
   `check` (3.2). Watch for the worker again for a while.

7. **Keep the evidence.** No upstream report or fix exists for this. dm-zoned is maintained
   in the Linux device-mapper tree, and the evidence file is what a report would need.

> **Why not simply switch to an older kernel:** after the first incidents the author moved
> the guest to Debian's 6.12 for stability. The re-seed that followed ran at about 25 MB/s.
> On 7.2.6, Hyper Backup alone wrote about 68 MB/s and the stress test took 116-143 MB/s.
> The guest went back to 7.2.6 with this monitoring instead
> ([06](06-alternatives-and-lessons.md)).

### 4.3 LUKS header restore

**Symptom:** the array is assembled and healthy, but `cryptsetup luksDump /dev/md/hc680`
reports that it is not a valid LUKS device, or every key and passphrase is rejected.

First rule out the layers below. An array assembled from the wrong members, or in the wrong
order, also looks like a broken header. Check `mdadm --detail /dev/md/hc680` and 4.1 step 3.

1. **Check the backup** you kept off the guest. Substitute the directory that holds your
   verified copy for `/path/to/verified` throughout this procedure; the header file is then
   `/path/to/verified/header.img`. Keep the copied names `header.img` and `header.img.sha256`,
   because `sha256sum -c` looks for that name.

   Both `header.img` and `header.img.sha256` must exist from a completed backup run
   ([03, step 7f](03-guest-storage-stack.md#7f-back-up-the-luks-header)). A directory missing
   either file, or containing only `header.img.unverified`, is from a failed run; do not
   restore from it. Stop if either check below fails.

   ```sh
   ( cd /path/to/verified && sha256sum -c header.img.sha256 )
   cryptsetup luksDump /path/to/verified/header.img # keyslots as they were at backup time
   ```

2. **Test it without writing anything (not tried by the author).** cryptsetup can open the
   device with a detached header, read-only:

   ```sh
   cryptsetup open --readonly --header /path/to/verified/header.img \
     --key-file /etc/zonedpool/hc680.key /dev/md/hc680 hc680test
   mkdir -p /mnt/hc680test
   mount -o ro,norecovery /dev/mapper/hc680test /mnt/hc680test
   ls /mnt/hc680test
   umount /mnt/hc680test
   cryptsetup close hc680test
   ```

   Use a passphrase instead of `--key-file` if the keyfile is gone. `norecovery` stops XFS
   from replaying its log, which would write to the device.

3. **Restore the header.**

   > **DESTRUCTIVE.** This overwrites the LUKS header on the array with the backup. Keyslots
   > added after the backup was taken are lost; keyslots removed since then come back. Using
   > the wrong file makes the data unreadable.

   ```sh
   cryptsetup luksHeaderRestore /dev/md/hc680 --header-backup-file /path/to/verified/header.img
   ```

4. **Open and mount as usual:** `systemctl start srv-hc680.mount` (4.1 step 6). Then check
   the keyslots with `cryptsetup luksDump /dev/md/hc680`, re-add any that were missing from
   the backup, and take a **new** header backup.

### 4.4 Controller not attached

**Symptom, in the guest:** no HC680s in `lsblk`, and `lspci -nn | grep 1b4b:9235` prints
nothing. `journalctl -b -t zonedpool` shows `still absent after ...s - skipping`.

On DSM, as root:

```sh
/usr/local/etc/rc.d/S99zoned-attach.sh status
sh /volume1/zoned-attach/synology-zoned-attach.sh status
tail -n 30 /volume1/zoned-attach/attach.log
/usr/local/bin/virsh list --all
```

`status` shows whether the watcher is armed and running, the recorded controller address, the
guest's state and how many host devices it has. Look up any `REFUSE`, `CONFIG ERROR` or
`FAILED` line in the troubleshooting table of
[02](02-synology-controller-passthrough.md#troubleshooting). The causes the author actually
hit or designed for:

| Cause | Fix |
|---|---|
| `attach.conf` was edited, but the watcher still runs with the old values | `/usr/local/etc/rc.d/S99zoned-attach.sh restart`. This cost the author two controller moves. |
| The watcher did not start at NAS boot | Look for `zoned-attach` in the system log, then `S99zoned-attach.sh start`. |
| The guest was re-created, so its domain UUID changed | Put the new UUID in `DOM=`, restart the watcher. |
| A drive died or was added, so the census no longer matches | Until the next NAS reboot the watcher keeps using the recorded address (the controller is still on `vfio-pci`). After a reboot it refuses; fix `ZONED_COUNT` / `ZONED_MODEL` and restart the watcher. |
| The guest is not running | Start it in VMM. The watcher attaches within about 15 s of `running`. |

DSM 7 has no `pgrep`. Both published `status` commands instead match the exact shell,
installed script path and `watch` arguments in `/proc/*/cmdline`. The boot hook's `status`
prints the matching PIDs and returns nonzero when no watcher matches. The script's `status`
reports `watcher=stopped` and exits 0 after successfully loading its config. If it is absent,
check both `attach.log` (including watcher stderr) and the
system log: startup checks the new PID after 2 seconds, and a failed `restart` returns
nonzero without replacing a watcher that has not finished stopping.

Stop uses a wall-clock deadline of about 60 seconds, plus scan overhead. On a timeout,
leave the lock intact and wait until the hook prints `watcher NOT running`, then start
and check again:

```sh
while /usr/local/etc/rc.d/S99zoned-attach.sh status; do sleep 3; done
/usr/local/etc/rc.d/S99zoned-attach.sh start
sleep 5
/usr/local/etc/rc.d/S99zoned-attach.sh status
```

If the log makes no progress and a `virsh` child is hung, use the PIDs and the
[02 timeout procedure](02-synology-controller-passthrough.md#after-editing-the-config-restart-the-watcher)
to inspect and terminate the child before killing its watcher. Do not restart while that
child can still act on the controller, or remove `attach.lock` by hand. Start/stop/restart
and manual `once` calls are serialized by a separate PID-owned lifecycle lock. It is
released on normal exit; after a hard kill, the next call recovers it if its owner PID is
gone. See [02, lifecycle-lock recovery](02-synology-controller-passthrough.md#recovering-a-stale-lifecycle-lock)
if the lock still prevents a call.

After the attach, the drives take 1 to 3 minutes to appear in the guest. If the chain has
already given up, start it again in the guest with `systemctl start srv-hc680.mount`
(4.1 step 6).

### 4.5 After a NAS crash

A NAS crash takes the guest down without a clean shutdown. After the author's 2026-09-24
panic, the NAS was back a few minutes later, the guest was running again, the watcher
re-attached the controller, and the chain reassembled the mappers and the array by itself.
The pool still did not mount: edits to `/etc/fstab` and `/etc/mdadm/mdadm.conf` made shortly
before the panic were gone, so both still held the old UUIDs, and one reclaim worker was
stuck.

1. **On the NAS:** check DSM's own storage first (Storage Manager, or `cat /proc/mdstat` on
   DSM). After the panic, DSM's arrays came back clean. If you capture the NAS kernel log
   remotely (netconsole), save the lines from before the reset now: DSM itself keeps nothing
   from before a panic ([01](01-requirements-and-risks.md)).

2. **Check that the controller came back:** 4.4. At NAS boot the watcher is started by the rc.d
   hook and attaches the controller once VMM has started the guest. Whether VMM starts the
   guest automatically depends on the guest's autostart setting.

3. **In the guest, check recent configuration changes:**

   ```sh
   ls -l --time-style=long-iso /etc/fstab /etc/crypttab /etc/mdadm/mdadm.conf /etc/zonedpool/
   ```

   Anything you changed shortly before the crash may be back to its old version. Compare the
   UUIDs in `mdadm.conf` and fstab with the real ones (4.1 steps 3 and 5). The mechanism of
   that loss was not investigated. Running `sync` after editing files that matter for boot is
   a cheap precaution, but it was not tested against this failure.

4. **Walk the chain** (4.1) and **check for a stuck reclaim worker** (4.2). Both incidents of
   a stuck worker came right after a power event on the NAS.

5. **Prefer fixing in place over restarting the guest.** In the 2026-09-24 incident the
   author deliberately did not restart the guest at first, because restarting a guest that
   carries the controller is the correlated trigger.

6. **md:** `cat /proc/mdstat`. A `repair` or `check` that was running can come back as a
   `resync` from its checkpoint (seen after the NAS was shut down during a repair). Let it
   finish, then run a `check` if you want a trustworthy mismatch
   count (3.2). `mdadm --detail /dev/md/hc680 | grep -i bitmap` shows whether the array has a
   write-intent bitmap, which limits a resync after an unclean stop to the dirty regions.

7. **XFS** replays its log at mount. The author's pool mounted without further action. If it
   refuses to mount, read `dmesg` first. `xfs_repair -n /dev/mapper/hc680crypt` on the
   unmounted filesystem only reports and changes nothing. It was never needed here.

8. **Backups that were running during the crash:** run Hyper Backup's integrity check on the
   task in DSM. In an earlier incident with the old design, that check was what found
   damaged index files.

---

## 5. Pitfalls at a glance

| Pitfall | What happened | What to do |
|---|---|---|
| Treating reclaim in D state as a hang | Busy reclaim sits in D for long periods; a watch raised false alarms | Look at completed commands, not D state (1.5, 2.6) |
| Reading `iodone_cnt` with awk | Hex values read as 0, "no progress" on busy drives | Shell arithmetic or `printf %d` |
| One malformed metrics line | node_exporter dropped the whole file, all pool metrics vanished | Check `node_textfile_scrape_error` after every change (2.3) |
| Backup copies in the rules directory | Every alert fired three times | Keep backups elsewhere (2.4) |
| Alerting nobody reads | 1,884 notifications went into an unread cache | Test delivery end to end (2.4) |
| `--assume-clean` without a repair | 752 parity mismatches | Full `repair`, then a `check` (3.2) |
| Assuming a newer kernel is faster | Zabbly 7.2.7 reached less than half of Ubuntu 7.2.6 on one test | Benchmark every kernel change (3.3) |
| Falling back to an old kernel for safety | The re-seed ran at about 25 MB/s | Monitor and capture evidence instead (4.2) |
| `xfs_scrub_all.timer` on a kernel with online scrub | A full media scan at a fixed time each month | Decide, and disable if unwanted (3.4) |
| Writing to an unmounted mount point | Filled a test machine's root disk | `mountpoint -q` guard before any bulk write (3.3) |
| Restarting `zonedpool-dmzassemble` | Would restart the whole chain and unmount the pool | Run the script directly (3.7, 4.1) |
| Old UUIDs after a rebuild or crash | The array or filesystem did not come up | Compare UUIDs (4.1) |
| Editing `attach.conf` without restarting the watcher | The controller went to the old guest | Restart the watcher (4.4) |
| Formatting the wrong drive during a replacement | Would destroy a degraded array | Check the serial three times (3.7) |
| Trusting the idle drain on 7.2.6 | Buffers stayed two thirds full for hours on an idle pool | Install the reclaim-kick timer (1.2.1) |
| Creating the array with `--run` | mdadm skipped its bitmap question and created no write-intent bitmap | A brief member drop-out costs a full rebuild; see [03, Step 5](03-guest-storage-stack.md#step-5---create-the-raid5) |
| `mdadm-last-resort` with a slow mapper | 30 s after a partial incremental assembly it tried to start the array without the late member | Mask it for this array ([03, Step 5](03-guest-storage-stack.md#step-5---create-the-raid5)) |
| Removing a member that is still rebuilding | `hot remove failed ... Device or resource busy` | Repeat `--remove` a few seconds after `--fail` (3.7) |
| Hot-plugging a drive next to the pool | All drives on that port multiplier froze for 12-25 s | Expect it; stop latency-sensitive work first (3.7) |
| Editing a script while it runs | bash reads scripts as it executes; an in-place edit can make a running job execute shifted bytes | Install changed scripts with `mv` (new inode), never overwrite in place |
| Opening LUKS on the raw array under a write-back cache | Would bypass dirty cache blocks | Open only on `/dev/mapper/hc680cache` ([08, section 4](08-caching.md#4-a-volume-cache-between-the-raid-and-luks)) |

## Files

| File | Installed as |
|---|---|
| [scripts/guest/zoned-pool-metrics](../scripts/guest/zoned-pool-metrics) | `/usr/local/sbin/zoned-pool-metrics` (0755), plus the timer in 2.2 |
| [monitoring/prometheus-rules.yml](../monitoring/prometheus-rules.yml) | a file in your Prometheus rules directory |
| [scripts/guest/zonedpool-reclaim-kick](../scripts/guest/zonedpool-reclaim-kick) | `/usr/local/sbin/zonedpool-reclaim-kick` (0755) |
| [systemd/zonedpool-reclaim-kick.service](../systemd/zonedpool-reclaim-kick.service), [.timer](../systemd/zonedpool-reclaim-kick.timer) | `/etc/systemd/system/`, timer enabled (1.2.1) |
| [scripts/guest/zonedpool-volcache](../scripts/guest/zonedpool-volcache), [systemd/zonedpool-volcache.service](../systemd/zonedpool-volcache.service), [systemd/zonedpool-cryptopen.service.d/volcache.conf](../systemd/zonedpool-cryptopen.service.d/volcache.conf) | optional volume cache, [08, section 4](08-caching.md#4-a-volume-cache-between-the-raid-and-luks) |
| [scripts/nas/flashcache-seq-skip.sh](../scripts/nas/flashcache-seq-skip.sh) | DSM Task Scheduler, boot-up, root ([08, section 5](08-caching.md#5-synology-make-the-ssd-cache-take-the-cache-disks-io)) |

## Other pages

[01 - Requirements and risks](01-requirements-and-risks.md) ·
[02 - Synology controller passthrough](02-synology-controller-passthrough.md) ·
[03 - Guest storage stack](03-guest-storage-stack.md) ·
[04 - OpenMediaVault and Synology integration](04-openmediavault-and-synology-integration.md) ·
[06 - Alternatives and lessons](06-alternatives-and-lessons.md) ·
[07 - Prior art](07-prior-art.md) ·
[08 - Caching](08-caching.md)
