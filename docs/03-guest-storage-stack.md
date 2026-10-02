# 03 - Guest storage stack: dm-zoned, md RAID5, LUKS2, XFS

This guide builds the storage inside the Debian 13 / OpenMediaVault 8 guest. You start with
three raw host-managed SMR drives and end with one encrypted XFS filesystem at `/srv/hc680`
that comes back on its own after every reboot.

> **Before you start**
>
> - The guest must already see the drives through the passed-through controller
>   ([02-synology-controller-passthrough.md](02-synology-controller-passthrough.md)).
> - This has been tested on exactly one setup: a DS3622xs+ with a DX1222 expansion unit and
>   3 x WD Ultrastar HC680 27 TB, Debian 13, OpenMediaVault 8.5.9 and kernel
>   `7.2.6-070206-generic`. Nothing else has been tested. The approach only works when the
>   zoned drives sit on a controller that DSM does not use for its own disks. That rules out,
>   for example, a DS1821+ in this layout. See
>   [01-requirements-and-risks.md](01-requirements-and-risks.md), including the NAS kernel
>   panic that is still unexplained.
> - Several steps **destroy data** and are marked **DESTRUCTIVE**. Back up anything that is
>   on these drives before you start.

## The stack

```
/srv/hc680                  XFS            su=512k, sw=2
 /dev/mapper/hc680crypt     LUKS2          aes-xts-plain64, 512-bit key, 4096-byte sectors, argon2id
  /dev/md/hc680 (md127)     md RAID5       3 members, 512K chunk            49.1 TiB
   /dev/mapper/dz1..dz3     dm-zoned       one per drive, zoned=none        ~24.6 TiB each
    /dev/sdX                HC680          host-managed, 256 MiB zones      ~24.6 TiB each
```

Why the layers are in this order:

- **dm-zoned sits at the bottom** because RAID5 cannot run directly on host-managed drives.
  The author tested this in a lab. `mdadm --create` succeeds, and the array even reports
  `zoned=host-managed`. Then the first filesystem writes fail with I/O errors on every
  member, because parity lands at arbitrary sectors and the drives only accept sequential
  writes. A successful create proves nothing. dm-zoned makes each drive look like an ordinary
  block device (`zoned=none`), so no layer above it ever sees a zone.
- **md RAID5** lets one drive fail while the array keeps running.
- **One LUKS2 container sits on top of the whole array**, which is how DSM's volume
  encryption works too. There is one key and one unlock.
- **XFS** allocates inodes dynamically and formats instantly. With ext4's default inode ratio,
  inode tables alone would have used about 380 GB per drive, and formatting crawled
  through dm-zoned.

Names used throughout this guide. You can change them, but the scripts, units and examples
refer to these exact names:

| Object | Name |
|---|---|
| dm-zoned mappers | `dz1`, `dz2`, `dz3` |
| md array | `/dev/md/hc680` (kernel name `md127`) |
| LUKS mapping | `hc680crypt` |
| Mount point | `/srv/hc680` (systemd unit `srv-hc680.mount`) |
| Config and keyfile | `/etc/zonedpool/dmzoned.conf`, `/etc/zonedpool/hc680.key` |
| Units | `zonedpool-dmzassemble`, `zonedpool-mdassemble`, `zonedpool-cryptopen` |

The `zonedpool-*` unit names date from an earlier design. The fstab line refers to them
through `x-systemd.requires=`. If you rename a unit, change the fstab line at the same time,
or the mount ordering breaks without any error.

Package versions on the as-built guest: `mdadm 4.4-11`, `cryptsetup 2:2.7.5-2`,
`xfsprogs 6.13.0-2+deb13u1`, `dm-zoned-tools 2.2.2-1+b1`, `openmediavault 8.5.9-1`.

All commands below run as root inside the guest.

---

## Step 0 - Check what the guest sees

```sh
lsblk -d -o NAME,SIZE,MODEL,ZONED
for d in /sys/block/sd*; do
  printf '%s zoned=%s nr_zones=%s max_open=%s\n' "${d##*/}" \
    "$(cat "$d/queue/zoned")" "$(cat "$d/queue/nr_zones")" "$(cat "$d/queue/max_open_zones")"
done
ls -l /dev/disk/by-id/ | grep WSH722870 | grep -v -- -part
```

Each HC680 should report `24.6T`, `host-managed`, `nr_zones=100584` (1,006 conventional
plus 99,578 sequential-write-required zones) and `max_open=128`. Write down the three by-id
names. You need them in steps 3 and 4.

The drives appear about 2 to 3 minutes after the controller is attached. During that time,
`dmesg` shows `failed to IDENTIFY` lines for port `.05` of each port multiplier. These come
from a phantom port and are harmless. See
[02-synology-controller-passthrough.md](02-synology-controller-passthrough.md).

---

## Step 1 - Install the packages

```sh
apt update
apt install dm-zoned-tools mdadm cryptsetup systemd-cryptsetup xfsprogs
```

> **Why these names:** `dmzadm` comes in the package `dm-zoned-tools`. There is no package
> called `dmzadm`. Debian 13 moved the crypttab generator into its own package,
> `systemd-cryptsetup`. In the final design (step 8) the unit it generates is not started at
> boot, but the as-built guest has the package installed.

---

## Step 2 - Choose and pin the kernel

The kernel makes a large difference to throughput. Every kernel below ran the same stack on
the same guest with the same two tests, on the finished encrypted pool: a 60-second
sequential `O_DIRECT` write with 1 MiB blocks from one writer, and a buffered write from
4 writers (including the final sync).

| Kernel | Source | 1 writer, O_DIRECT 1 MiB | 4 writers, buffered |
|---|---|---|---|
| `6.12.107+deb13` | Debian 13 stock | 24.6 MiB/s | not measured |
| `7.1.8` | Debian trixie-backports | 24.7 MiB/s | 34.4 MiB/s |
| `7.2.6-070206-generic` | Ubuntu mainline | **165.4 MiB/s** | **261.4 MiB/s** |
| `7.2.7-zabbly+` | Zabbly | 58-69 MiB/s (3 runs) | 210.7 MiB/s |

The exact benchmark command lines were not recorded, so treat these numbers as a comparison
between kernels on this stack, not as a target to reproduce.

What is known:

- md RAID5 hands dm-zoned 4 KiB writes on **every** kernel. md's stripe size is fixed at
  4096 bytes on x86, and dm-zoned is bio-based, so nothing merges the writes. Kernel 7.2
  simply gets through far more of them: during the test, one member received about 21,000
  writes/s on 7.2.6 compared with about 3,200/s before.
- **Nobody knows why 7.2 is faster.** It is not the zoned block layer: `block/blk-zoned.c` is
  byte-identical in 7.1.8 and 7.2.x. Do not attribute the speed-up to zone write plugging.
- The gap between the Ubuntu and Zabbly 7.2 builds is not caused by code changes. 7.2.7 and
  7.2.8 contain no changes to dm-zoned, md/raid5, dm-crypt, dm core, blk-zoned,
  mq-deadline, libata/ahci/port multipliers or sd/sd_zbc. The difference is probably build
  configuration or compiler: full vs lazy preemption, gcc 14.2 vs 15.2, or `max_sectors_kb`
  4096 on Zabbly vs 1280 on Ubuntu. This is unproven.
- Debian's stock 6.12 kernel ran the stack correctly with no errors. It is only slow.

**The author runs Ubuntu mainline 7.2.6, pinned in GRUB.** Know what that costs you:

- The kernel is installed by hand, so apt delivers no security updates for it. You have to
  watch <https://kernel.ubuntu.com/mainline/> yourself and re-test before you move.
- Kernels 7.2.0 to 7.2.6 contain a SLUB freelist race that 7.2.7 fixes (commit
  `570a6aaf6b52`). The only known trigger is a deliberate exploit, so the author rates the
  risk as low. The plan is to move to the first 7.2.7-or-later build that is as fast as 7.2.6.
- On 7.2.6, a dm-zoned reclaim worker got stuck in D state twice. Both times it happened
  right after the array was reassembled following a power event on the host. Once it needed a
  guest reboot, and once it cleared by itself. No upstream report or fix exists. It has only
  been seen on 7.2.6, but the other kernels never ran long enough under the same conditions to
  rule them out. The mitigation is monitoring, evidence capture and a reboot
  ([05-operations-monitoring-performance.md](05-operations-monitoring-performance.md)).
- On 7.2.6, dm-zoned's idle buffer drain does not always restart after a busy period, so the
  write buffer can stay about two thirds full on an idle pool. Install the reclaim-kick timer
  ([05, 1.2.1](05-operations-monitoring-performance.md#121-the-idle-drain-can-stall-kernel-726-install-the-reclaim-kick)).
- Debian enables `xfs_scrub_all.timer` by default. On kernels built with XFS online scrub
  (Debian's 7.1.8 and Zabbly's 7.2.7, for example), it runs a real full-media scan of the
  pool once a month. Ubuntu's 7.2.6 is built without online scrub, so there the timer does
  nothing. If you use a kernel with online scrub, decide whether you want that scan
  ([05-operations-monitoring-performance.md](05-operations-monitoring-performance.md)).

### 2a. Install the Ubuntu mainline 7.2.6 kernel

The author installed the image and modules packages, verified them against Ubuntu's signed
`CHECKSUMS` file, and installed `wireless-regdb` because the modules package needs it. The
exact download commands were not recorded. The commands below do the same thing. First
check the file names against the directory listing at
<https://kernel.ubuntu.com/mainline/v7.2.6/>.

```sh
mkdir -p /root/kernel-7.2.6 && cd /root/kernel-7.2.6
base=https://kernel.ubuntu.com/mainline/v7.2.6/amd64
wget "$base/CHECKSUMS" "$base/CHECKSUMS.gpg" \
  "$base/linux-image-unsigned-7.2.6-070206-generic_7.2.6-070206.202609141300_amd64.deb" \
  "$base/linux-modules-7.2.6-070206-generic_7.2.6-070206.202609141300_amd64.deb"

# Verify the signature on CHECKSUMS, then the packages against it.
# The key's user ID is "Kernel PPA <kernel-ppa@canonical.com>" (see note below)
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 60AA7B6F30434AE68E569963E50C6A0917C622B0
gpg --verify CHECKSUMS.gpg CHECKSUMS
grep -E '^[0-9a-f]{64} ' CHECKSUMS | sha256sum --check --ignore-missing
```

Continue only if you get `Good signature` and both `.deb` files report `OK`.

> **The fingerprint has no independent reference right now.** The page that used to list it,
> <https://wiki.ubuntu.com/Kernel/MainlineBuilds> (still linked from the mainline directory),
> returned 404 on 2026-09-28. A `Good signature` from a key fetched from a keyserver proves
> the files match that key, not who owns it. Without an official page to compare against,
> you are trusting the fingerprint printed here. If you find a current official reference,
> check the fingerprint against it.

Then install:

```sh
apt install wireless-regdb
dpkg -i linux-modules-7.2.6-070206-generic_*.deb linux-image-unsigned-7.2.6-070206-generic_*.deb
ls /boot/initrd.img-7.2.6-070206-generic || update-initramfs -c -k 7.2.6-070206-generic
update-grub
```

> **Why `wireless-regdb`:** on a headless install that lacked it, the first `dpkg -i`
> stopped at the configure stage.
>
> **Why `update-grub` by hand:** in the author's scripted install, the package did not
> regenerate `grub.cfg` in the same run, so the first reboot came back up on 6.12.

The image is unsigned. If Secure Boot is enforced in the guest firmware, the guest will not
boot it. Keep Debian's own kernel installed as a fallback.

### 2b. Boot the new kernel once before you pin it

List the GRUB entry ids:

```sh
awk -F"'" '/^[[:space:]]*(menuentry|submenu) / {print $4 "    " $2}' /boot/grub/grub.cfg
```

You will see lines like these. `<ROOT_FS_UUID>` is your root filesystem's UUID:

```
gnulinux-advanced-<ROOT_FS_UUID>    Advanced options for Debian GNU/Linux
gnulinux-7.2.6-070206-generic-advanced-<ROOT_FS_UUID>    Debian GNU/Linux, with Linux 7.2.6-070206-generic
```

Boot that entry once. The path is the submenu id, then `>`, then the entry id:

```sh
grub-reboot 'gnulinux-advanced-<ROOT_FS_UUID>>gnulinux-7.2.6-070206-generic-advanced-<ROOT_FS_UUID>'
systemctl reboot
# after the reboot:
uname -r
```

The one-time entry normally clears itself. On a host where `/boot/grub` lives on LVM, GRUB
cannot write its environment block, so the "one-time" entry stays in place. The author saw
this on a different machine in this project. To clear it:
`grub-editenv /boot/grub/grubenv unset next_entry`.

### 2c. Pin the kernel by entry id

Back up `/etc/default/grub`, then set:

```sh
GRUB_DEFAULT="gnulinux-advanced-<ROOT_FS_UUID>>gnulinux-7.2.6-070206-generic-advanced-<ROOT_FS_UUID>"
```

Then run `update-grub`.

> **Why pin by id instead of `GRUB_DEFAULT=0`:** entry 0 is the newest installed version.
> Any higher-versioned kernel that turns up later (from backports, or a forgotten custom
> build) silently becomes the pool's kernel. This happened to the author: an old custom
> build sorted above the intended kernel. With a pinned id, the kernel only changes when you
> change the pin.

The as-built guest also has `libata.force=7.05:norst,8.05:norst,9.05:norst,10.05:norst` in
`GRUB_CMDLINE_LINUX_DEFAULT` to cut down the phantom-port probing. The ata port numbers
depend on your guest. See
[02-synology-controller-passthrough.md](02-synology-controller-passthrough.md) before you
copy it.

### 2d. Check that the kernel has what the stack needs

```sh
grep -E '^CONFIG_(BLK_DEV_ZONED|DM_ZONED|MD_RAID456|DM_CRYPT|XFS_FS)=' /boot/config-$(uname -r)
modprobe dm_zoned && echo dm_zoned OK
```

Each option must be `=y` or `=m`.

---

## Step 3 - Format each drive for dm-zoned

> [!WARNING]
> **DESTRUCTIVE.** `dmzadm --format` resets every zone on the drive and writes new dm-zoned
> metadata. Everything on the drive is gone. Check each by-id path twice against step 0.

If you are rebuilding on drives that already carry this stack, first stop Hyper Backup,
rsync pushes and any other clients or local jobs using the pool. Then stop the guest's
sharing services, unmount the NFS bind mount, and stop the assembly chain before removing
its devices. Run this only for an existing or partly built stack; the block skips absent
layers. **Stop if stopping an existing layer fails; do not format a drive still in use.**

```sh
(
  set -e
  for u in nfs-server.service smbd.service rsync.service; do
    if systemctl cat "$u" >/dev/null 2>&1; then systemctl stop "$u"; fi
  done
  if mountpoint -q /export/media; then umount /export/media; fi
  for u in srv-hc680.mount zonedpool-cryptopen.service zonedpool-mdassemble.service zonedpool-dmzassemble.service; do
    if systemctl cat "$u" >/dev/null 2>&1; then systemctl stop "$u"; fi
  done
  # A partial build may have mounted the pool by hand, without a unit.
  if mountpoint -q /srv/hc680; then umount /srv/hc680; fi
  # cryptopen's ExecStop normally closes this; close it here if still open.
  if cryptsetup status hc680crypt >/dev/null 2>&1; then cryptsetup close hc680crypt; fi
  if [ -e /dev/md/hc680 ]; then mdadm --stop /dev/md/hc680; fi
  for m in dz1 dz2 dz3; do
    if dmsetup info "$m" >/dev/null 2>&1; then dmsetup remove "$m"; fi
  done
)
```

> **Why stop the services too:** the assembly units have `RemainAfterExit=yes`. Removing
> their devices leaves them marked active, so `enable --now` would not run assembly again.
> Step 4 starts dm-zoned assembly after formatting; continue through the remaining steps to
> rebuild the upper layers before restarting shares or clients.
> If you reuse the old array and filesystem UUIDs (`--uuid` in Step 5, `-m uuid=` in Step 9)
> and keep the same paths, mdadm.conf, fstab and OMV's mount entry, shared folders and shares
> stay valid. After Step 10, recreate only the shared-folder directories
> ([04, section 4, step 4](04-openmediavault-and-synology-integration.md#4-service-users-and-directories))
> and bring up the bind mount and exports (04, section 6, step 3) before the Step 11 reboot
> test. If the UUIDs changed, first follow [04, section 3a](04-openmediavault-and-synology-integration.md#3a-only-when-rebuilding-remove-the-old-pools-omv-objects-first)
> to remove the old pool's OMV objects. Then register and deploy the new mount (04, sections
> 3b–3c), recreate the directories (04, section 4, step 4) and recreate the shares and
> modules (04, sections 5–9). Keep the existing service accounts; do not import them again.
> Until the directories exist, the `/export/media` bind mount and NFS fail at boot.
> Restart sharing services and clients only after those paths and exports have been checked.

After a successful teardown (or on new, unused drives), format each drive:

```sh
dmzadm --format /dev/disk/by-id/ata-WDC_WSH722870ALE604_<SERIAL_1>
dmzadm --format /dev/disk/by-id/ata-WDC_WSH722870ALE604_<SERIAL_2>
dmzadm --format /dev/disk/by-id/ata-WDC_WSH722870ALE604_<SERIAL_3>
```

The author ran the three formats in parallel. Read any prompt or warning from `dmzadm`
before you answer it.

dm-zoned keeps a label in its metadata. On the as-built drives the label is
`dmz-<drive serial>`, and it shows up in the reclaim worker's thread name
(`dmz_rwq_dmz-<SERIAL>`). The monitoring in
[05-operations-monitoring-performance.md](05-operations-monitoring-performance.md) relies on
that naming.

---

## Step 4 - Create the mappers at boot, by by-id

dm-zoned mappings do not persist. Nothing in Debian recreates them at boot, so a small
script does it from a config file.

**On a rebuild, keep your existing `/etc/zonedpool/dmzoned.conf`:** reformatting does not
change the by-id names. If the script and unit are already installed, skip the installation,
`cp` and editor lines below and run only `systemctl enable --now zonedpool-dmzassemble.service`.

The paths below are relative to your checkout of this repository. Step 2 left the shell in
`/root/kernel-7.2.6`; go back first (adjust the path to where you cloned it):

```sh
cd /root/synology-host-managed-smr
test -f examples/dmzoned.conf.example && echo ok
```

```sh
mkdir -p /etc/zonedpool
cp examples/dmzoned.conf.example /etc/zonedpool/dmzoned.conf
editor /etc/zonedpool/dmzoned.conf           # put in your three by-id names
install -m 0755 scripts/guest/zonedpool-dmzassemble /usr/local/sbin/
install -m 0644 systemd/zonedpool-dmzassemble.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now zonedpool-dmzassemble.service
```

The config has one line per drive, in the form `<by-id path> <mapper name>`
([examples/dmzoned.conf.example](../examples/dmzoned.conf.example)). The script
([scripts/guest/zonedpool-dmzassemble](../scripts/guest/zonedpool-dmzassemble)) waits for
each device, then runs `dmsetup create <name> --table "0 <sectors> zoned <device>"`. It logs
through syslog with the tag `zonedpool`.

Check the result:

```sh
lsblk -o NAME,SIZE,TYPE,ZONED /dev/mapper/dz1 /dev/mapper/dz2 /dev/mapper/dz3
dmsetup status dz1
journalctl -b -t zonedpool
```

Each mapper should be about 24.6 TiB with `ZONED none`. The status line has this form:

```
0 <length> zoned 100584 zones 0/0 cache <free>/998 random <free>/99562 sequential
```

`<free>/<total> random` counts the conventional zones that dm-zoned uses as its write buffer:
998 per HC680, about 250 GiB. `sequential` counts the data zones. `0/0 cache` means there is
no separate cache device. Right after a format, the free counts should be at or close to the
totals. On the as-built drives, after the RAID and filesystem were created, the counts
were 961/998 and 99,560/99,562.

> **Why by-id and not `/dev/sdX`:** kernel names change when the controller enumerates in a
> different order.
>
> **Why the script waits:** the first version gave up as soon as a device was missing. The
> drives behind the passed-through controller take about 100 s to appear after an attach,
> and longer after a VMM power cycle. So on a real boot, the pool came up completely
> unassembled. The script now waits up to `ZP_DMZ_WAIT` seconds per drive (default 600).
>
> **Why `After=local-fs.target`** rather than early in boot: a slow or missing drive then
> cannot stall the rest of the guest's boot.
>
> **Why one unit builds all mappers before md sees any of them:** in a lab test with only two
> of three members present, Debian's mdadm "last resort" timer started the array degraded,
> and the late member then had to be added back with `mdadm --re-add`.

What happens when a drive never appears follows from the unit files, but the author never
exercised it on the final stack:

- The script waits, logs `still absent`, and exits 1.
- The later units `Require` it, so they do not run: the pool is not unlocked or mounted.
  (udev may still assemble the md array on its own from the members that exist.)
- If no drive appears at all, the per-drive waits add up to more than the unit's 15-minute
  start timeout, and systemd fails the unit.

In both cases the rest of the guest boots normally, because the mount is `nofail` (step 10).

---

## Step 5 - Create the RAID5

> **DESTRUCTIVE** for anything on `dz1..dz3`.

```sh
mdadm --create /dev/md/hc680 --level=5 --raid-devices=3 --chunk=512K \
  --metadata=1.2 --name=hc680 --assume-clean --run \
  /dev/mapper/dz1 /dev/mapper/dz2 /dev/mapper/dz3
cat /proc/mdstat
```

The result is `md127`, 49.1 TiB, `[UUU]`.

For a rebuild, the author also passed `--uuid=<MD_UUID>` to reuse the old array
UUID so that existing references stayed valid. Leave that out on a first build.

> **Pitfall: `--assume-clean` is not free.** It skips md's initial parity pass. The reasoning
> was that freshly reset dm-zoned space reads back as zeros, and the parity of zeros is zero.
> But the first repair pass on such an array found **752** parity mismatches
> (`mismatch_cnt`). The cause is unknown. The rule that follows is simple: **if you use
> `--assume-clean`, you must run the full repair pass in step 6.** Until that pass finishes,
> a drive failure can rebuild wrong data. If you leave out `--assume-clean`, md runs its own
> initial resync instead. The author never built the array that way, so that route is
> untested here. A resync of this array later ran at about 195-205 MB/s, similar to the
> repair.

> **Pitfall: no write-intent bitmap.** Without `--bitmap`, mdadm (4.4 on the reference
> guest) asks *"To optimize recovery speed, it is recommended to enable write-intent bitmap,
> do you want to enable it now?"*, but **only without `--run`**. With `--run`, as in the
> command above, it skips the question and creates none (`mdadm.c`, create mode:
> `c.runstop != 1 && ask(...)`, otherwise `BitmapNone`). The reference array has none
> (`mdadm --detail` shows no "Intent Bitmap").
> Without a bitmap, a member that drops out even briefly (a pulled cable, a slow drive at
> boot) cannot be re-added with a quick catch-up resync. It needs a **full rebuild**, which
> on this stack takes about 10 days without a cache device
> ([08, section 2](08-caching.md#2-what-a-member-rebuild-costs-without-a-cache)).
> `--bitmap=internal` at create time, or `mdadm --grow --bitmap=internal` later on an idle
> array, adds one. Its write overhead on dm-zoned, where the bitmap updates become small
> random writes into the buffer zones, **has not been measured yet**.

### mdadm.conf

```sh
mdadm --detail --scan
```

Add the resulting `ARRAY` line to `/etc/mdadm/mdadm.conf`, replacing any older line for this
array ([examples/mdadm.conf.example](../examples/mdadm.conf.example)). Then run:

```sh
update-initramfs -u
```

> **Why:** the assemble unit runs `mdadm --assemble --scan`, which finds arrays by the UUID
> in this file. After one rebuild, both `mdadm.conf` and `fstab` still held the old UUIDs,
> and the author had to fix them by hand. After any rebuild, check both files.

The initramfs cannot assemble this array anyway, because its members only exist after
`zonedpool-dmzassemble` has run. Either udev assembles it incrementally as the mappers
appear, or the unit below does.

> **Pitfall: `mdadm-last-resort` can start the array without a slow member.** When udev has
> added some members incrementally, Debian's `mdadm-last-resort@md127.timer` fires 30 s
> later and starts the array with whatever is there. dm-zoned mappers do not always appear
> quickly: creating one took 30 s to 2 min on the reference guest (usually about 7 s). On a
> healthy array that means md starts **degraded** without the slow member, and without a
> bitmap that member then needs a full rebuild. On 2026-09-29 the timer fired while a
> member was still missing. It failed only because another member was itself still
> rebuilding. The half-assembled array then blocked the late member ("ADD_NEW_DISK not
> supported") and the assemble unit ("already active"). Mask the timer for this array, so
> md waits until all members are there:
>
> ```sh
> systemctl mask mdadm-last-resort@md127.timer mdadm-last-resort@md127.service
> ```
>
> Verified at the next reboot: a member was again 30 s late, and the array waited for it.
> If the name is not `md127` on your system, use yours. If the array ends up inactive
> anyway, [05, section 4.1](05-operations-monitoring-performance.md#41-pool-not-mounted-after-boot-walk-the-chain)
> shows how to stop it and assemble it explicitly.

### stripe_cache_size

```sh
md=$(basename "$(readlink -f /dev/md/hc680)")     # md127
echo 8192 > /sys/block/$md/md/stripe_cache_size
cat /sys/block/$md/md/stripe_cache_size
```

The as-built value is 8192. The kernel default is 256. It costs page size x members x value
in RAM, here 4 KiB x 3 x 8192 = 96 MiB. The sources contain no benchmark comparing values.
The author once lowered it to 4096 by mistake and then restored 8192.

This is a runtime setting, and the as-built files do not show how it survives a reboot. One
way to make it persistent is a drop-in for the assemble unit. This is **untested** here:

```ini
# /etc/systemd/system/zonedpool-mdassemble.service.d/stripe-cache.conf   (untested suggestion)
[Service]
ExecStartPost=/bin/sh -c 'echo 8192 > /sys/block/$(basename $(readlink -f /dev/md/hc680))/md/stripe_cache_size'
```

### The assemble unit

```sh
install -m 0644 systemd/zonedpool-mdassemble.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable zonedpool-mdassemble.service
```

The unit ([systemd/zonedpool-mdassemble.service](../systemd/zonedpool-mdassemble.service))
has `Requires=` and `After=` on `zonedpool-dmzassemble.service`. It does the following:

1. Runs `dmsetup mknodes` and waits up to 5 minutes for each of `/dev/mapper/dz1..dz3`.
2. Runs `mdadm --assemble --scan`, and if that fails, assembles the array by naming the
   members.
3. Judges success only by whether `/dev/md/hc680` exists, because udev may already have
   assembled the array.

The mapper and array names are hard-coded in the unit.

---

## Step 6 - Run a full parity repair (mandatory after `--assume-clean`)

```sh
echo repair > /sys/block/md127/md/sync_action
cat /proc/mdstat                              # progress and speed
cat /sys/block/md127/md/mismatch_cnt          # mismatches found and fixed so far
```

What to expect, as measured on this setup:

- On an idle array the pass runs at about 173-205 MB/s. A full pass takes roughly 33-40
  hours. On the reference pool it took 40.5 hours and found **0 mismatches**, with
  3.19 TB written into the pool during it.
- dm-zoned answers reads of never-written regions from its metadata without touching the
  disks, so the drives do almost no physical I/O on those parts.
- The pass gives way to real I/O. Under heavy writes it dropped to about 10 MB/s, which was
  the minimum sync speed on this guest (see `/sys/block/md127/md/sync_speed_min` and
  `/proc/sys/dev/raid/speed_limit_min`).
- You can go on with steps 7 to 11 while it runs, and even start using the pool. The
  author wrote backups into the pool during the repair, accepting the risk described in
  step 5.

If the pass is interrupted, it can come back as a `resync` rather than a `repair`. That
happened when the NAS was shut down in the middle of one. The kernel's md documentation
counts mismatches for `check` and `repair`, and only "possibly" for `resync`. If you need a
reliable number afterwards, run:

```sh
echo check > /sys/block/md127/md/sync_action
```

The array's state, sync progress and `mismatch_cnt` are exported to monitoring in
[05-operations-monitoring-performance.md](05-operations-monitoring-performance.md).

---

## Step 7 - LUKS2 encryption

The model is DSM's volume encryption:

- The container unlocks automatically at boot from a keyfile stored on the system.
- A recovery passphrase and a header backup are kept somewhere else.

This protects the data on drives that leave the box (RMA, resale, theft of the drives). It
does **not** protect against someone who has the guest's root disk, because the keyfile is
on it. In the author's setup, the guest's virtual disk sits on the NAS's own encrypted
volume.

**If you lose the keyfile and every passphrase, the data is gone.** The drives alone cannot
be read.

### 7a. Create the keyfile

```sh
( umask 077; dd if=/dev/urandom of=/etc/zonedpool/hc680.key bs=4096 count=1 )
chmod 0400 /etc/zonedpool/hc680.key
```

This gives 4096 random bytes, readable by root only.

### 7b. Format the container

> **DESTRUCTIVE** for anything on `/dev/md/hc680`. `cryptsetup` asks you to type `YES`.

```sh
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
  --sector-size 4096 --pbkdf argon2id --label hc680crypt \
  /dev/md/hc680 /etc/zonedpool/hc680.key
```

The keyfile becomes keyslot 0. The 4096-byte encryption sector matches the layers below:
dm-zoned exposes 4 KiB logical sectors, and so does the md array built on it.

Encryption is not the bottleneck. `cryptsetup benchmark` in the guest measured aes-xts with a
512-bit key at about 950 MiB/s encrypt and 1020 MiB/s decrypt on a single thread, far more
than this pool can write.

### 7c. First open, with the flags stored in the header

```sh
cryptsetup open --key-file /etc/zonedpool/hc680.key \
  --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent \
  /dev/md/hc680 hc680crypt
cryptsetup luksDump /dev/md/hc680 | grep -i flags
```

`--persistent` writes these flags into the LUKS2 header. Every later open picks them up
automatically, including the plain `cryptsetup open --key-file ...` in the unit from step 8.
**Discards on this stack (measured 2026-10-02): keep them off in normal use.**

- md RAID5 silently drops discards unless `raid456.devices_handle_discard_safely=Y` is set
  (dm-zoned returns zeros for discarded blocks, so Y is correct here).
- With Y, md processes discards in 4 KiB stripe units with its raid5 thread at 100 % CPU:
  about 49 GiB/min, so a full `fstrim` of ~45 TiB free space takes ~17 h (projected from the rate).
- The discards are queued ahead of normal writes. During that whole trim the XFS log could not
  write (its log worker stuck in `xlog_wait_on_iclog` for hours): the pool took no writes,
  only reads.
- XFS re-trims all free space on every `fstrim`, and dm-zoned does not free a sequential zone
  that discards have emptied. So discards gain nothing in daily use; online `discard` would
  freeze writes during every large delete.
- They help only before converting a cached member back to a plain one (emptied chunks can
  then be dropped). Trim then in slices (`fstrim -o <offset> -l <length>`) at a quiet time.
- Exclude the pool from the distribution's weekly `fstrim.timer`.

To find the container's UUID, which you need for crypttab, run
`cryptsetup luksUUID /dev/md/hc680`.

### 7d. Add a recovery passphrase (keyslot 1)

The author used a 32-character random passphrase. How it was generated was not recorded.
This is one way:

```sh
( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > /root/hc680.rkey )
cryptsetup luksAddKey --key-file /etc/zonedpool/hc680.key /dev/md/hc680 /root/hc680.rkey
cryptsetup -v open --test-passphrase --key-slot 1 /dev/md/hc680     # type or paste it
```

The last command should print `Key slot 1 unlocked.` The file must not end with a newline,
and `head -c` guarantees that. `cryptsetup` reads a key file byte for byte, so a trailing
newline would become part of the key, and typing the passphrase later would fail.

Store the passphrase outside the guest, for example in a password manager or on paper. Then
delete `/root/hc680.rkey`.

### 7e. Add your own passphrase (keyslot 2)

This step matters if anyone besides you set up the system or saw the recovery passphrase:
a helper, a script log, a chat transcript. Add a passphrase that only you know. **Type it
yourself**, on the guest's console or in your own SSH session, so it never passes through
anyone else:

```sh
cryptsetup luksAddKey --key-file /etc/zonedpool/hc680.key /dev/md/hc680
# asks twice for the new passphrase
cryptsetup -v open --test-passphrase --key-slot 2 /dev/md/hc680
```

Expected output: `Key slot 2 unlocked.` The keyslots are now:

- 0: keyfile, used for the boot unlock
- 1: recovery passphrase
- 2: your passphrase

All three use argon2id. Check with `cryptsetup luksDump /dev/md/hc680`.

Adding a passphrase does not retire one that was exposed. To remove a keyslot, use
`cryptsetup luksKillSlot /dev/md/hc680 <slot>`. Removing a keyslot does not change the
volume key. If key material leaked while the pool is still empty, the clean fix is to redo
step 7b, which creates a new volume key. This option was considered for the as-built pool
but not used.

### 7f. Back up the LUKS header

```sh
(
  set -e
  umask 077
  header_dir=$(mktemp -d /root/hc680-luks-header.XXXXXXXX)
  header=$header_dir/header.img.unverified
  printf 'Unverified header path (until all checks pass): %s\n' "$header"
  cryptsetup luksHeaderBackup /dev/md/hc680 --header-backup-file "$header"
  cryptsetup luksDump "$header"
  cryptsetup open --test-passphrase --header "$header" \
    --key-file /etc/zonedpool/hc680.key /dev/md/hc680
  checksum=$(sha256sum "$header")
  printf '%s  header.img\n' "${checksum%% *}" > "$header_dir/header.img.sha256"
  mv "$header" "$header_dir/header.img"
  header=$header_dir/header.img
  cat "$header.sha256"
  printf 'Copy this verified header off the guest: %s\n' "$header"
)
```

The backup is 16 MiB. Each run uses a new private directory and preserves existing backups.
Only `header.img` together with `header.img.sha256` marks a verified run. A directory without
either file is from a failed or interrupted run; do not use it for recovery. The printed
`.unverified` path identifies any incomplete backup. Copy both verified files off the pool
and off the guest, then run `sha256sum -c header.img.sha256` in the copied directory.
Only after that succeeds should you deliberately retire older
copies. **Make a new backup after every keyslot change**: the author refreshed it after
adding keyslot 2.

A header backup holds the keyslots as they were when you took it. Any passphrase that was
valid then still opens the data through that backup, even after you remove its keyslot from
the live header. Guard header backups like keys.

### Recovery reference

```sh
# Unlock by hand with any passphrase, or with the keyfile
cryptsetup open /dev/md/hc680 hc680crypt
cryptsetup open --key-file /etc/zonedpool/hc680.key /dev/md/hc680 hc680crypt
```

> [!WARNING]
> **DESTRUCTIVE if you use the wrong file.** Only when the header is damaged, restore it from
> the verified backup. Substitute its actual path below:

```sh
cryptsetup luksHeaderRestore /dev/md/hc680 --header-backup-file /path/to/verified/header.img
```

---

## Step 8 - Unlock late, with the pool's own unit (crypttab must be `noauto`)

```sh
install -m 0644 systemd/zonedpool-cryptopen.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable zonedpool-cryptopen.service
```

The unit ([systemd/zonedpool-cryptopen.service](../systemd/zonedpool-cryptopen.service)) has
`Requires=` and `After=` on `zonedpool-mdassemble.service`. It waits up to 5 minutes for
`/dev/md/hc680`, then runs `cryptsetup open --key-file /etc/zonedpool/hc680.key`, unless the
container is already open. On stop it closes the container.

The `/etc/crypttab` line must carry `noauto`
([examples/crypttab.example](../examples/crypttab.example)):

```
hc680crypt UUID=<LUKS_UUID> /etc/zonedpool/hc680.key luks,noauto,discard,no-read-workqueue,no-write-workqueue
```

> **Why `noauto`: the first reboot test failed without it.**
>
> The first design used a normal crypttab entry, with the mount requiring the generated
> `systemd-cryptsetup@hc680crypt.service`. That generated unit runs **early**: it is ordered
> before `cryptsetup.target`, which the boot must pass before ordinary services start. It
> waits for `/dev/md/hc680`. But the RAID only exists after `zonedpool-dmzassemble` and
> `zonedpool-mdassemble`, and both of those are `After=local-fs.target`. So each side
> waited for the other.
>
> The crypt unit gave up after its 15-minute device timeout (`Dependency failed` at 968 s).
> Only then did the assembly run. The RAID came up, but the container stayed closed and the
> pool stayed unmounted.
>
> The fix: `noauto`, so nothing starts the generated unit at boot, plus this separate unit
> ordered after the RAID assembly. The second reboot test passed.

With `noauto`, the crypttab entry stays in the file but no longer starts anything at boot.

---

## Step 9 - Create the XFS filesystem

> **DESTRUCTIVE** for anything inside the container.

```sh
mkfs.xfs -d su=512k,sw=2 /dev/mapper/hc680crypt
```

`su` is the md chunk size (512K). `sw` is the number of data members: a 3-member RAID5 has 2.
Once the filesystem is mounted, `xfs_info /srv/hc680` should show `sunit=128 swidth=256 blks`
and `sectsz=4096`.

For a rebuild, the author also used `-f` to overwrite the old filesystem, and
`-m uuid=<XFS_UUID>` to keep the old filesystem UUID so that fstab and OpenMediaVault's
references stayed valid. Leave both out on a first build.

After mounting, `df` shows about 1 TB used on the empty 50 TB filesystem. That space is XFS
metadata reserved across the 50 allocation groups. It is a one-time cost, not ongoing waste:
over 90 s of writing, used space grew by 13 GiB for 13 GiB of data (ratio 1.04).

---

## Step 10 - The fstab line

```sh
blkid -s UUID -o value /dev/mapper/hc680crypt       # -> <XFS_UUID>
mkdir -p /srv/hc680
```

This is the as-built line
([examples/fstab.example](../examples/fstab.example)):

```
/dev/disk/by-uuid/<XFS_UUID>  /srv/hc680  xfs  defaults,noatime,inode64,nofail,x-systemd.requires=zonedpool-mdassemble.service,x-systemd.requires=zonedpool-cryptopen.service,x-systemd.device-timeout=15min  0 2
```

| Option | Why |
|---|---|
| `x-systemd.requires=zonedpool-mdassemble.service`, `x-systemd.requires=zonedpool-cryptopen.service` | Pulls in the late chain and orders the mount after it. |
| `x-systemd.device-timeout=15min` | The decrypted device appears minutes into the boot. The default wait is 90 s, after which systemd gives up and the pool stays unmounted. |
| `nofail` | Boot neither waits for the pool nor fails without it. It is also structurally required. Without `nofail`, systemd orders the mount before `local-fs.target`, while the assembly units run after `local-fs.target`. That is an ordering cycle. |
| `noatime,inode64` | As built. |

**On OpenMediaVault**, OMV owns the block between `# >>> [openmediavault]` and
`# <<< [openmediavault]` and rewrites it. Either register the filesystem in OMV with these
options in its `opts` field, which is what the as-built guest does and what OMV's shared
folders need, or write the line by hand outside OMV's block. A lab test confirmed that OMV
leaves hand-written lines alone. That also means OMV does not remove your hand-written line
when you register the filesystem later: delete it then
([04, section 3b](04-openmediavault-and-synology-integration.md#3b-create-the-mount-entry)). The details are in
[04-openmediavault-and-synology-integration.md](04-openmediavault-and-synology-integration.md).

Mount it now:

```sh
systemctl daemon-reload
systemctl start srv-hc680.mount
findmnt /srv/hc680
```

---

## Step 11 - Enable the chain and test a full reboot

```sh
systemctl enable zonedpool-dmzassemble.service zonedpool-mdassemble.service zonedpool-cryptopen.service
```

The boot chain now looks like this:

```
guest boots
 -> controller attached by the NAS watcher, drives enumerate (docs/02)
 -> zonedpool-dmzassemble   waits <= 600 s per drive, creates dz1..dz3
 -> zonedpool-mdassemble    assembles /dev/md/hc680
 -> zonedpool-cryptopen     opens hc680crypt with the keyfile
 -> srv-hc680.mount         XFS by UUID, nofail, waits <= 15 min for the device
 -> shares / NFS bind mount (docs/04)
```

Do not put data on the pool until this test passes.

**Test 1: reboot inside the guest, with a marker file.**

```sh
date > /srv/hc680/.reboot-test && sync
systemctl reboot
```

After the reboot:

```sh
systemctl --failed
systemctl status zonedpool-dmzassemble zonedpool-mdassemble zonedpool-cryptopen srv-hc680.mount --no-pager
journalctl -b -t zonedpool
systemd-analyze critical-chain srv-hc680.mount
cat /proc/mdstat
findmnt /srv/hc680 && cat /srv/hc680/.reboot-test
```

A pass looks like this: no failed units, `md127` shows `[UUU]`, `/srv/hc680` is mounted from
`/dev/mapper/hc680crypt`, and the marker file is intact. In the author's passing run:

| Unit | Finished at |
|---|---|
| dmzassemble | ~84 s |
| mdassemble | ~86 s |
| cryptopen | ~89 s |
| mount | ~90 s |

NFS, SMB and rsync were active right after.

**Test 2: power-cycle the guest from VMM** (shut it down, then start it). A reboot inside the
guest keeps the controller attached, so it does not test late drive enumeration. After a
power cycle, VMM regenerates the domain. The NAS watcher re-attaches the controller only
after the guest has started, and the drives appear about 2 to 3 minutes later
([02-synology-controller-passthrough.md](02-synology-controller-passthrough.md)). Run the
same checks. `journalctl -b -t zonedpool` should show `... appeared after <N>s` for each
drive.

Observed boot times:

| Situation | Pool ready after |
|---|---|
| Reboot inside the guest | ~100 s |
| VMM power cycle | ~100 s plus the ~2.5-minute controller re-attach |
| One early test | 11 minutes waiting for the drives |

That spread is why the timeouts are generous. Everything that depends on the pool must
tolerate it coming up late: shares, the NAS's NFS remote folder, Hyper Backup
([04-openmediavault-and-synology-integration.md](04-openmediavault-and-synology-integration.md)).

---

## What healthy looks like

```
$ lsblk -o NAME,SIZE,TYPE,MODEL,ZONED
NAME               SIZE TYPE  MODEL               ZONED
sdb               24.6T disk  WDC WSH722870ALE604 host-managed
└─dz3             24.6T dm                        none
  └─md127         49.1T raid5                     none
    └─hc680crypt  49.1T crypt                     none
sdc               24.6T disk  WDC WSH722870ALE604 host-managed
└─dz1             24.6T dm                        none
  └─md127         49.1T raid5                     none
    └─hc680crypt  49.1T crypt                     none
sdd               24.6T disk  WDC WSH722870ALE604 host-managed
└─dz2             24.6T dm                        none
  └─md127         49.1T raid5                     none
    └─hc680crypt  49.1T crypt                     none
```

The `sdX` letters do not have to match the `dzN` numbers. The by-id config keeps them
straight.

A `dmsetup status` line taken during heavy writing:

```
0 52722401280 zoned 100584 zones 0/0 cache 24/998 random 99046/99562 sequential
```

Only 24 of the 998 buffer zones are free, so the buffer is nearly full. The buffer only
drains while the pool is idle, and write throughput depends on how full it is. What to
expect, and how to monitor it, is covered in
[05-operations-monitoring-performance.md](05-operations-monitoring-performance.md).

Busy dm-zoned reclaim workers (`dmz_rwq_*`) legitimately sit in D state for long periods. D
state only means a hang when the drives also stop completing commands. See docs/05.

---

## Pitfalls in this build, at a glance

| Pitfall | What happened | What to do |
|---|---|---|
| RAID5 directly on host-managed drives | Creation succeeded, then the first writes failed with I/O errors on all members | Put dm-zoned underneath (step 3) |
| Boot script that did not wait for the drives | Pool came up unassembled after every boot | Wait per drive, with a bound (step 4) |
| `mdadm --create --assume-clean` | 752 parity mismatches on the first repair | Always run a full `repair` (step 6) |
| Stale UUIDs after a rebuild | mdadm.conf and fstab pointed at the old array and filesystem | Update both after any rebuild (steps 5 and 10) |
| crypttab entry without `noauto` | Early crypt unit and late assembly waited for each other; pool locked after a 15-minute stall | `noauto` plus `zonedpool-cryptopen.service` (step 8) |
| `GRUB_DEFAULT=0` | A different installed kernel sorted first | Pin the entry id (step 2c) |
| Recovery passphrase file with a newline | Not hit here, but the typed passphrase would not match the stored key | Write it without a newline, then test it (step 7d) |
| Old LUKS header backups | Still open the data with keyslots you have removed | Refresh after changes; guard like keys (step 7f) |

## Files used in this guide

| File | Installed as |
|---|---|
| [scripts/guest/zonedpool-dmzassemble](../scripts/guest/zonedpool-dmzassemble) | `/usr/local/sbin/zonedpool-dmzassemble` (0755) |
| [systemd/zonedpool-dmzassemble.service](../systemd/zonedpool-dmzassemble.service) | `/etc/systemd/system/` |
| [systemd/zonedpool-mdassemble.service](../systemd/zonedpool-mdassemble.service) | `/etc/systemd/system/` |
| [systemd/zonedpool-cryptopen.service](../systemd/zonedpool-cryptopen.service) | `/etc/systemd/system/` |
| [examples/dmzoned.conf.example](../examples/dmzoned.conf.example) | `/etc/zonedpool/dmzoned.conf` |
| [examples/mdadm.conf.example](../examples/mdadm.conf.example) | lines in `/etc/mdadm/mdadm.conf` |
| [examples/crypttab.example](../examples/crypttab.example) | line in `/etc/crypttab` |
| [examples/fstab.example](../examples/fstab.example) | line in `/etc/fstab` (or OMV's filesystem entry) |

Next: [04-openmediavault-and-synology-integration.md](04-openmediavault-and-synology-integration.md)
covers shares, NFS for DSM and the Hyper Backup target.
[06-alternatives-and-lessons.md](06-alternatives-and-lessons.md) explains why this stack
replaced the earlier zoned btrfs + mergerfs + SnapRAID design, and why it was chosen over a
nested DSM VM.
[08-caching.md](08-caching.md) covers optional cache layers: a cache device per dm-zoned
member and a volume cache between the RAID and LUKS.
