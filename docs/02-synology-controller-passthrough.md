# 02 — Passing the zoned drives' controller to a VMM guest (NAS side)

This page covers everything that happens on the Synology itself:

- finding the right controller;
- creating the Virtual Machine Manager (VMM) guest;
- installing the watcher that hands the controller to that guest after every guest start;
- checking that it worked;
- moving the controller between guests, and taking it back out.

The guest side (dm-zoned, RAID5, LUKS2, XFS) is in
[03-guest-storage-stack.md](03-guest-storage-stack.md).

Files used on this page:

| File in this repository | Installed on the NAS as |
|---|---|
| [`scripts/nas/synology-zoned-attach.sh`](../scripts/nas/synology-zoned-attach.sh) | `/volume1/zoned-attach/synology-zoned-attach.sh` |
| [`scripts/nas/attach.conf.example`](../scripts/nas/attach.conf.example) | `/volume1/zoned-attach/attach.conf` |
| [`scripts/nas/S99zoned-attach.sh`](../scripts/nas/S99zoned-attach.sh) | `/usr/local/etc/rc.d/S99zoned-attach.sh` |

---

## Which Synology models this works on

**Tested on exactly one setup:** a **DS3622xs+** (Xeon D-1531, DSM 7.4, Linux 4.4.302) with a
**DX1222** expansion unit and three WD Ultrastar DC HC680 27 TB host-managed SMR drives.
Every other model, expansion unit, controller and drive is untested. That includes add-in
controller cards.

The method hands a **whole PCI controller** to the guest. Everything behind that controller
disappears from DSM at the moment it is unbound. So it works only if all of this is true:

1. **x86 Synology with VMM, and a root shell on DSM.**
2. **Working IOMMU (VT-d) in DSM.** `/sys/kernel/iommu_groups` must contain groups.
3. **A controller that DSM uses for none of its own disks.** Only the zoned drives may be
   behind it. On the DS3622xs+ this is the Marvell 88SE9235 behind the expansion connector
   the DX1222 is plugged into. DSM's 12 internal bays use a different controller, a Marvell
   88SE1475 with Synology's `mv14xx` driver.
4. **That controller alone in its own IOMMU group.**
5. **Zoned drive models that differ from DSM's drive models**, so the watcher's model census
   can tell them apart.

> [!IMPORTANT]
> **This does not work where the zoned drives would share the controller that DSM boots and
> runs from.** Unbinding such a controller takes DSM's own disks with it. The author's
> example: this layout will **not** run on a **DS1821+**. Do not try to work around this
> by passing through a controller that DSM also uses.

The author's controllers, as recorded on the DS3622xs+. **Do not copy these addresses.** PCI
addresses are specific to each machine. On the tested NAS they also depend on which expansion
connector the DX1222 cable is in (see [01, section 2](01-requirements-and-risks.md#2-what-was-tested)).

| DSM address | PCI ID | Driver | IOMMU group | Behind it | Role |
|---|---|---|---:|---|---|
| `0000:07:00.0` | `1b4b:1475` (88SE1475) | `mv14xx` | 20 | 12 × WUH721818 (DSM's disks) | **Protected. Never touched.** |
| `0000:10:00.0` | `1b4b:9235` (88SE9235) | `ahci`, then `vfio-pci` | 28 | DX1222 with 3 × HC680 | Passed through to the guest |
| `0000:13:00.0` | `1b4b:9235` (88SE9235) | `ahci` | 31 | nothing | Spare, left alone |

The full read-only checklist, with a go/no-go table, is in
[01, section 5](01-requirements-and-risks.md#5-check-your-nas-before-you-build-anything-read-only).
Do not continue until every check there passes.

## Known risk: a kernel panic in DSM's own storage driver

> [!CAUTION]
> On **2026-09-24** the author's NAS kernel panicked inside Synology's `mv14xx` driver. That
> is the driver of the **production** controller with DSM's 12 disks, not the passed-through
> one. About five minutes earlier, the watcher had attached the 88SE9235 to a guest that had
> just been started. In the minutes before the panic, a RAID5 create and `mkfs.xfs` sent
> sustained writes through it. The NAS rebooted by itself, and DSM's arrays came back clean.
>
> The only earlier crash (2026-09-19) was not captured. It happened in the same second as a
> watchdog reset of a VMM guest that was carrying the same passed-through controller. So
> **2 of 2 known crashes** line up with the passthrough. **The mechanism is not proven.**
>
> Since then the setup has carried many hours of heavy I/O without the panic coming back. That
> includes a 3.5-hour, 491 GiB Hyper Backup run the same afternoon, further guest starts with
> attach, and a combined stress test on 2026-09-26.
>
> If you build this, you accept the risk on your own hardware. Keep current backups of DSM's
> own volumes. Prefer clean guest shutdowns to forced ones. Details and the author's working
> rules: [01, section 7.1](01-requirements-and-risks.md#71-nas-kernel-panic-in-dsms-own-storage-driver).

## How it works

```text
DSM boot
  └─ /usr/local/etc/rc.d/S99zoned-attach.sh start
       └─ synology-zoned-attach.sh watch          (loop, every 15 s)
            ├─ is the configured guest running?                 no  -> wait
            ├─ model census: which 1b4b:9235 has exactly N zoned
            │  drives and no DSM drive behind it?               (else: the recorded address)
            ├─ address protected / wrong ID / no IOMMU group?   yes -> refuse, log
            ├─ already attached to the guest?                   yes -> nothing to do
            ├─ unbind from ahci, bind to vfio-pci (by address, never by ID)
            └─ virsh attach-device <guest> hostdev.xml --live
Guest (Q35): PCIe hot-plug -> ahci -> port multipliers -> drives appear after 1–3 min
```

Why it is built this way:

- **DSM cannot use the drives.** Every DSM kernel is built without `CONFIG_BLK_DEV_ZONED`.
  On the DX1222's AHCI path, DSM's 4.4 kernel saw the HC680s only as SCSI generic (`sgX`)
  devices, never as disks. So
  there is no DSM block device for `scsi-block` passthrough. The `/dev/sgX` alternative is
  unverified on DSM/VMM; whole-controller passthrough is the method validated here. See
  [01, section 3](01-requirements-and-risks.md#3-why-dsm-cannot-use-these-drives-itself).
- **VMM has no PCI passthrough in its UI.** The attach is done with `virsh`, as root, outside
  VMM.
- **The attach can only be live.** VMM defines its guests transiently and builds each
  guest's definition anew whenever the guest is powered on. It ignores a persistent libvirt
  definition, so neither `virsh edit` nor `attach-device --config` survives. `virsh list
  --all` shows a VMM guest only while it runs.
- **Polling, not a hook.** DSM has no libvirt hooks directory, and installing one needs a
  `libvirtd` restart. A 15-second poll is simple, and it works.
- **The watcher never detaches.** Taking the controller away from a guest is always a
  deliberate manual step.

> [!CAUTION]
> **Rules that are never broken:**
>
> - Never unbind, reset or pass through a controller that DSM uses. The script refuses the
>   addresses in `PROTECT_PCI_HARD`, and it refuses to run while that list is empty.
> - Never bind by vendor:device ID (for example `vfio-pci.ids=1b4b:9235`). The DS3622xs+ has
>   two 9235s with the same ID. Bind by exact address only, as the script does.
> - Never use a PCI address you read inside a guest, or on someone else's NAS.

## Step 1 — Identify the controllers, drives and IOMMU groups on DSM

Apart from copying the script onto the NAS, everything in this step only reads. Enable SSH
in DSM (Control Panel > Terminal & SNMP), log in as an administrator and become root:

```sh
sudo -i
```

1. **The IOMMU must be active.**

   ```sh
   ls /sys/kernel/iommu_groups | wc -l      # must be greater than 0
   ```

   If this prints 0, stop. This guide cannot help you.

2. **List every PCI device, its driver and its IOMMU group.**

   ```sh
   for d in /sys/bus/pci/devices/*; do
     g=$(readlink "$d/iommu_group"); drv=$(readlink "$d/driver")
     echo "${d##*/} $(cat "$d/vendor"):$(cat "$d/device") class=$(cat "$d/class") driver=${drv##*/} group=${g##*/}"
   done
   ```

   `lspci -nnk` shows the same devices with names, if it is available on your DSM.
   Storage controllers have a class starting with `0x01`.

3. **Find out which drives sit behind which controller: the model census.** The watcher
   script has a read-only `census` mode for this. Copy the script to the NAS first (Step 3,
   items 1–2), then run:

   ```sh
   sh /volume1/zoned-attach/synology-zoned-attach.sh census
   ```

   For every PCI device that has drives behind it, or that matches the controller ID in the
   config, it prints:

   - the address, PCI ID, driver and IOMMU group;
   - the other members of that IOMMU group;
   - the model of every drive DSM sees behind it.

   It reads the same sysfs paths the watcher uses
   (`/sys/bus/pci/devices/<address>/ata*/host*/target*/*/model` for AHCI controllers and
   `.../host*/target*/*/model` for SCSI HBAs such as `mv14xx`). You can also check one
   controller by hand:

   ```sh
   cat /sys/bus/pci/devices/<CANDIDATE>/ata*/host*/target*/*/model
   ```

   The `census` mode was written for this public version. It reads only, but the author did
   not run it on the NAS. The paths it reads are the ones the as-built watcher reads.

4. **Check the candidate's IOMMU group.** The group must contain only the candidate:

   ```sh
   ls /sys/bus/pci/devices/<CANDIDATE>/iommu_group/devices/
   ```

5. **Write down two lists.**
   - **Protected:** every address that has a DSM disk behind it. Add NVMe cache SSDs if you
     have any. These go into `PROTECT_PCI_HARD` in Step 3.
   - **Zoned:** the one controller with only your zoned drives behind it, the exact number
     of those drives, and a short model substring for them (for example `WSH722870`) and for
     DSM's drives (for example `WUH721818`).

> **Why short model substrings:** the sysfs `model` field can be shorter than the full model
> name. A substring such as `WSH722870` matches reliably.
>
> **Why the watcher counts drives instead of trusting the PCI ID:** the DS3622xs+ has two
> 88SE9235 controllers with the same ID. Which one holds the DX1222 depends on the expansion
> connector it is cabled to (see [01, section 2](01-requirements-and-risks.md#2-what-was-tested)).
> On another model, a controller with the same ID could be one that DSM needs.
>
> **Why addresses read inside a guest are useless here:** inside the author's guest, the
> passed-through card showed up as `07:00.0`. On DSM, `0000:07:00.0` is the protected
> production controller. The card's real host address was `0000:10:00.0`. Take addresses
> only from DSM.

## Step 2 — Create the VMM guest

The author's guest runs Debian 13 with OpenMediaVault 8 on 4 vCPUs. Installing the guest and
OpenMediaVault is covered in
[04-openmediavault-and-synology-integration.md](04-openmediavault-and-synology-integration.md).
Choosing its kernel is covered in [03](03-guest-storage-stack.md). On the NAS side, this is
what matters:

1. **Create a Linux guest in VMM with a normal virtual system disk.** Do not create virtual
   disks for the pool: the drives arrive through the controller. The as-built guest has a
   128 GB system disk. Keep the vCPU count modest. The Xeon D-1531 has 12 threads, and DSM
   needs some of them for its own storage work.

2. **Install the QEMU guest agent in the guest** (`qemu-guest-agent` on Debian). VMM needs it
   to shut the guest down cleanly and to show the guest's IP address.

3. **Let VMM start the guest automatically** if you want the pool back after a NAS reboot.
   The watcher attaches the controller once the guest is running.

4. **Check that the guest is a Q35 machine that can hot-plug PCIe devices.** Both VMM guests
   the author created were Q35 machines. Other machine types were not tested.

   ```sh
   # on DSM, while the guest is running
   /usr/local/bin/virsh dumpxml <GUEST_DOMAIN_UUID> | grep -o "machine='[^']*'"
   # expect machine='pc-q35-...'; on the author's VMM (QEMU 8.1.5, libvirt 10.1.0)
   # a guest ran as pc-q35-8.1

   # inside the guest
   grep CONFIG_HOTPLUG_PCI_PCIE= /boot/config-$(uname -r)    # expect =y
   ls /sys/bus/pci/slots/                                     # hot-plug slots, must not be empty
   lspci -nn | grep -i sata
   # a Q35 guest shows the ICH9 controller:
   # 00:1f.2 SATA controller [0106]: Intel Corporation 82801IR/IO/IH (ICH9R/DO/DH) 6 port SATA Controller [AHCI mode] [8086:2922] (rev 02)
   ```

   > **Why Q35:** the controller is hot-plugged into a guest that is already running. That
   > needs PCIe hot-plug slots in the guest. The as-built guest has
   > `CONFIG_HOTPLUG_PCI_PCIE=y` and 56 hot-plug slots.

5. **Find the guest's libvirt domain UUID.** VMM lists a guest in `virsh` only while it is
   running. Start the guest, then:

   ```sh
   # on DSM
   /usr/local/bin/virsh list --all --uuid

   # inside the guest: the same UUID
   cat /sys/class/dmi/id/product_uuid
   ```

   If more than one guest is running, the value from inside the guest tells you which UUID is
   yours. This UUID is the `DOM=` value in the config. It is written as `<GUEST_DOMAIN_UUID>`
   on this page.

## Step 3 — Install the watcher, its config and the boot hook

Run everything as root on DSM. If your volume is not `/volume1`, change `DIR` in the script,
in the hook and in the commands below.

1. **Create a root-only directory.** Root sources `attach.conf` as shell code, so nobody else
   may be able to write to it.

   ```sh
   mkdir -p /volume1/zoned-attach
   chmod 700 /volume1/zoned-attach
   ```

2. **Copy the three files.** Upload them to a shared folder with File Station, then copy them
   into place. `<SHARE>` is that shared folder.

   ```sh
   cp /volume1/<SHARE>/synology-zoned-attach.sh /volume1/zoned-attach/
   cp /volume1/<SHARE>/attach.conf.example      /volume1/zoned-attach/attach.conf
   cp /volume1/<SHARE>/S99zoned-attach.sh       /usr/local/etc/rc.d/S99zoned-attach.sh
   chmod 755 /volume1/zoned-attach/synology-zoned-attach.sh /usr/local/etc/rc.d/S99zoned-attach.sh
   chmod 600 /volume1/zoned-attach/attach.conf
   ```

   Keep Unix line endings if you edit the files on another computer.

3. **Hard-code DSM's own controllers in the script.** Put every protected address from
   Step 1 into `PROTECT_PCI_HARD`, space-separated, in the full form `0000:bb:ss.f`. Use
   **your** addresses. The line below shows the author's value only as an example.

   ```sh
   vi /volume1/zoned-attach/synology-zoned-attach.sh
   #   PROTECT_PCI_HARD="0000:07:00.0"
   grep -n '^PROTECT_PCI_HARD=' /volume1/zoned-attach/synology-zoned-attach.sh
   ```

   > **Why in the script and not in the config:** the value is assigned *after* the config is
   > read. A mistake in the config can add protected addresses but can never remove one. The
   > as-built script hard-codes the production address the same way. The script refuses to
   > act while `PROTECT_PCI_HARD` is empty or names an address that does not exist, which
   > catches typos such as `07:00.0` without the `0000:` prefix.

4. **Fill in the config.**

   ```sh
   vi /volume1/zoned-attach/attach.conf
   ```

   Set these values:

   - `DOM`: the guest's domain UUID from Step 2.
   - `CTRL_VENDOR` and `CTRL_DEVICE`: the controller ID. Only `0x1b4b`/`0x9235` is tested.
   - `ZONED_MODEL` and `ZONED_COUNT`: the zoned drive model substring and how many drives
     must be behind the controller.
   - `DSM_MODEL`: a model substring of **each** of DSM's drive models. This is required.
   - `WANT_NESTED`: leave it at `0` (see [Optional: nested virtualization](#optional-nested-virtualization)).

5. **Dry run.** Nothing is armed yet, so this changes nothing:

   ```sh
   sh /volume1/zoned-attach/synology-zoned-attach.sh census
   sh /volume1/zoned-attach/synology-zoned-attach.sh status
   ```

   The last lines of `census` must show `census verdict ...: <the zoned controller's
   address>`, and `protected:` must list every DSM controller. If the verdict is `NONE`, fix
   the config first. `NONE` means no controller has exactly `ZONED_COUNT` matching drives,
   more than one does, or the controller is already bound to `vfio-pci`.

6. **Arm it and run one pass by hand, with the guest running.**

   > **This step takes the controller away from DSM.** Everything behind it disappears from
   > DSM at once. Check the census verdict one last time. It must be the controller that has
   > **only** your zoned drives behind it.

   ```sh
   touch /volume1/zoned-attach/attach.enable
   sh /volume1/zoned-attach/synology-zoned-attach.sh once
   tail -n 5 /volume1/zoned-attach/attach.log      # expect: attached 0000:bb:ss.f
   ```

   `once` does nothing while the guest is not running, so start the guest first.

7. **Start the watcher through the boot hook,** the same way DSM does at boot:

   ```sh
   /usr/local/etc/rc.d/S99zoned-attach.sh start
   sleep 5
   /usr/local/etc/rc.d/S99zoned-attach.sh status              # watcher running (pid ...)
   sh /volume1/zoned-attach/synology-zoned-attach.sh status   # armed=yes watcher=running ...
   ```

   > **Why an rc.d hook:** DSM runs `/usr/local/etc/rc.d/*.sh` with `start` at boot. DSM Task
   > Scheduler boot-up tasks proved unreliable for this. The hook starts the watcher in the
   > background. It waits up to 5 minutes for `/volume1` to be mounted, because an encrypted
   > volume mounts late, and logs to the system log with the tag `zoned-attach` instead of
   > failing silently. `start` returns immediately because boot startup runs in the
   > background; its exit status cannot report that background result. The hook checks the
   > new PID after 2 seconds and logs success only if it is still the watcher; check `status`
   > and the logs as above. The hook's `status` (`S99zoned-attach.sh status`) prints the PIDs
   > and returns nonzero if the watcher is absent. The script's `status` reports
   > `watcher=stopped` and exits 0 after loading its config successfully. Both match the exact
   > shell, installed script path and `watch` arguments in `/proc/*/cmdline`, without `pgrep`.
   > A separate `mkdir` lock serializes start/stop/restart and manual `once` passes; a competing
   > invocation logs that one is already running. The hook removes a stale `attach.lock` only
   > after finding no watcher and excluding a manual pass. Watcher stderr goes to `attach.log`,
   > including shell errors that happen before the script's own logging starts.

The as-built watcher on the author's NAS has run this way since 2026-09-13. After one NAS
power-on it logged `nested: enabled` at 20:42:20, before any guest had started, and
`attached 0000:10:00.0` at 20:43:43, once VMM had started the guest.

## Step 4 — Verify

**On DSM:**

```sh
tail -n 5 /volume1/zoned-attach/attach.log
# ... attached 0000:10:00.0          (your address)

/usr/local/bin/virsh dumpxml <GUEST_DOMAIN_UUID> | grep -c '<hostdev'
# 1                                   (count any other host devices you gave the guest)

readlink /sys/bus/pci/devices/<ZONED_CONTROLLER>/driver
# ... /vfio-pci
```

**In the guest**, after 1 to 3 minutes:

```sh
lspci -nn | grep 1b4b:9235
# 07:00.0 SATA controller [0106]: Marvell Technology Group Ltd. 88SE9235 PCIe 2.0 x2 4-port SATA 6 Gb/s Controller [1b4b:9235] (rev 11)
#   (the guest's own address - it has nothing to do with the host address)

lsblk -d -o NAME,SIZE,MODEL,ZONED
# sdb   24.6T WDC WSH722870ALE604 host-managed
# sdc   24.6T WDC WSH722870ALE604 host-managed
# sdd   24.6T WDC WSH722870ALE604 host-managed

cat /sys/block/sdb/queue/nr_zones     # 100584 on an HC680
```

**The drives appear late.** After each attach, the author measured between about 60 and 170
seconds before the drives showed up in the guest. During that time `dmesg` fills with
messages about port `.05` of each port multiplier, such as `failed to resume link` and
`failed to IDENTIFY (I/O error)`. The 88SM9705 port multipliers report a port `.05` that
does not exist, and libata retries it. **These messages are harmless.** Check that your
drives' own links are clean:

```sh
dmesg | grep -E 'ata[0-9]+\.05'        # phantom-port noise: expected
dmesg | grep -E 'ata[0-9]+\.0[0-4]'    # the real links: look for errors here
```

The guest's storage stack must wait for the drives. In the as-built guest, the dm-zoned
assembly waits up to 600 s per drive, and the fstab line has a long `x-systemd.device-timeout`.
See [03](03-guest-storage-stack.md).

**`libata.force=...:norst` (optional, guest kernel command line).** The as-built guest boots
with:

```text
libata.force=7.05:norst,8.05:norst,9.05:norst,10.05:norst
```

- The port numbers are the guest's. The Q35 machine's own ICH9 AHCI controller takes `ata1`
  to `ata6`, so the four ports of the 9235 become `ata7` to `ata10`. Check yours in `dmesg`
  before you copy the line.
- This matters mostly for a **reboot inside the guest**. QEMU keeps running, so the
  controller stays attached and the drives are probed during boot. On another Linux guest
  on the same NAS, it cut drive detection from 190–213 s to 5.7 s and the whole boot from
  about 4 min 10 s to 1 min 36 s. Some `.05` IDENTIFY timeouts remain.
- Before `norst`, the OpenMediaVault guest took 5 min 17 s to boot with the controller
  attached. Its boot time with `norst` was not measured separately.
- `disable` instead of `norst` does not help. It is applied only after IDENTIFY succeeds.

**Bay placement (performance, optional).** In the DX1222 the drives reach the 9235 through
port multipliers. Two HC680s that shared one port-multiplier link reached 149 and 148 MiB/s
under concurrent load. A drive with a link to itself reached 228 MiB/s. RAID5 writes all
members in lockstep, so put each zoned drive behind its own link if you can. Inside the
guest, `readlink -f /sys/block/sdb` shows which `ataN` a drive uses. In the as-built layout
the three drives sit on `ata8`, `ata9` and `ata10`.

## The hostdev XML: only `<source>`

The watcher writes this file each time it attaches, as `/volume1/zoned-attach/hostdev.xml`.
To write it by hand, take the **host** address from DSM. For example, `0000:10:00.0` becomes
bus `0x10`, slot `0x00`, function `0x0`:

```xml
<hostdev mode='subsystem' type='pci' managed='no'>
  <source><address domain='0x0000' bus='0x10' slot='0x00' function='0x0'/></source>
</hostdev>
```

> **Why only `<source>`:** a `<hostdev>` block copied from `virsh dumpxml` of a running guest
> also carries that guest's own `<address>` (the slot inside the guest) and an `<alias>`.
> Reusing that block on another guest can fail, or land in a slot that is already taken. With
> only `<source>`, libvirt places the device itself. The author noticed this while moving
> the controller between guests, and has used the source-only XML since.
>
> **Why `managed='no'`:** the watcher binds the controller to `vfio-pci` itself, by address.
> With `managed='no'` libvirt leaves the driver binding alone. The controller stays on
> `vfio-pci` while the guest is stopped, and DSM's `ahci` driver does not take the drives
> back between guest restarts.
>
> **Why the watcher's "is it attached?" check is so narrow:** it looks only inside
> `<hostdev>…<source>` of the guest's XML. An earlier version searched the whole XML. A
> guest-side PCI address that happened to match made it believe the controller was already
> attached, and it would silently never attach. Peer review caught this before it shipped.

## After editing the config: restart the watcher

The watcher reads `attach.conf` **once, when it starts.** Editing the file changes nothing
until the watcher restarts.

`stop` sends TERM only to matching watcher PIDs, then polls those PIDs with a one-second
sleep and a wall-clock deadline of about 60 seconds; process scans and scheduling add some
overhead. A final full scan confirms no watcher remains. A pending bind or `virsh` command
may delay termination. If a watcher remains, the hook returns nonzero and leaves its
`attach.lock` intact. The separate lifecycle lock is released when the hook exits.
`restart` runs synchronously:
it starts a replacement only after `stop` succeeds, checks the new PID after 2 seconds,
and propagates either failure. Start/stop/restart and manual `once` calls share a lifecycle
lock at `/tmp/zoned-attach-hook.lock`, with an owner record named `pid.<PID>` inside it.
If another such call is in progress, wait for it to finish before retrying. If the owner
PID is gone after a hard kill, the next call removes that stale lifecycle lock and retries
acquisition. Missing or invalid owner records are refused; see the recovery procedure below.

```sh
vi /volume1/zoned-attach/attach.conf
/usr/local/etc/rc.d/S99zoned-attach.sh restart
/usr/local/etc/rc.d/S99zoned-attach.sh status
sh /volume1/zoned-attach/synology-zoned-attach.sh status
```

On a stop timeout, the hook's `status` prints the matching PIDs (DSM's `ps` hides script
arguments). Run it every few seconds until it prints `watcher NOT running`, then start
and check again. Do not remove `attach.lock` by hand:

```sh
while /usr/local/etc/rc.d/S99zoned-attach.sh status; do sleep 3; done
/usr/local/etc/rc.d/S99zoned-attach.sh start
sleep 5
/usr/local/etc/rc.d/S99zoned-attach.sh status
```

If `attach.log` makes no progress and the watcher never exits, inspect each listed PID's
children using their parent PID and full command lines. Replace `<PID>` with a watcher PID:

```sh
watcher=<PID>
for proc in /proc/[0-9]*; do
  [ "$(awk '/^PPid:/{print $2}' "$proc/status" 2>/dev/null)" = "$watcher" ] || continue
  printf 'child %s: ' "${proc##*/}"
  tr '\000' ' ' <"$proc/cmdline"; echo
done
```

Repeat with a child's PID to inspect descendants if necessary. For a confirmed hung
`virsh` child, substitute its PID in `kill -TERM <CHILD_PID>`, then
`kill -KILL <CHILD_PID>` if necessary. Wait for that child to terminate before escalating
to `kill -KILL <PID>` on a watcher that still refuses to exit. Killing only the watcher
can leave its child acting on the controller. Restart only after the child is gone and
hook `status` prints `watcher NOT running`; the hook then clears the stale `attach.lock`.
If a child remains in uninterruptible sleep even after KILL, keep the watcher stopped and
plan a NAS reboot after stopping guest I/O. If the hook or a manual `once` was killed with
`kill -9`, confirm its children have also terminated before retrying. The next call recovers
the lifecycle lock when its recorded owner PID is gone. If it still refuses, use the
troubleshooting table and manual recovery below.

> **Why this gets its own section:** it cost the author two controller moves. After `DOM=`
> was changed, the still-running watcher attached the controller to the *old* guest, which
> was shutting down at that moment. At boot the hook always starts the watcher with the
> current config.

### Recovering a stale lifecycle lock

The lifecycle lock is separate from `/volume1/zoned-attach/attach.lock`, which protects an
attach pass. Automatic recovery requires a single valid owner record and an owner PID
that no longer exists. An interrupted creation can leave no record; a reused PID can also
keep a stale lock looking busy. For those cases, inspect the record and live hook/manual
`once` command lines (including the default invocation without a mode argument):

```sh
for owner in /tmp/zoned-attach-hook.lock/pid.*; do
  [ -f "$owner" ] || continue
  printf '%s: ' "$owner"; cat "$owner"
done
for c in /proc/[0-9]*/cmdline; do
  { tr '\000' ' ' <"$c"; } 2>/dev/null
  echo
done | grep -E -e 'S99zoned-attach[.]sh' -e 'synology-zoned-attach[.]sh( once( |$)| *$)'
```

If any hook or manual `once` is still running, wait for it. Only if the scan prints no
such process, any children left by the killed call have terminated (use the timeout
procedure above), and no other administrator is starting a call, remove the lifecycle
lock's owner record and empty directory:

```sh
for owner in /tmp/zoned-attach-hook.lock/pid.*; do
  [ -f "$owner" ] || continue
  rm "$owner" || break
done
rmdir /tmp/zoned-attach-hook.lock
```

Stop if `rmdir` fails; inspect the directory instead of removing it recursively. Retry
`S99zoned-attach.sh restart`, then check `status`. Do not remove `attach.lock` by hand;
the hook clears a stale pass lock only after confirming no watcher or manual pass is active.

## Moving the controller to another guest

Examples: rebuilding the guest, or testing a different guest on the same drives.

> [!WARNING]
> **Pulling the controller out from under a mounted pool causes I/O errors and can damage
> data.** Release the pool in the old guest first. The panic of 2026-09-24 followed this
> kind of move (controller moved, guest started, heavy writes within minutes). Move the
> controller only when you have to.

1. **In the old guest,** stop everything that writes to the pool. Then either shut the guest
   down cleanly, or release the stack by hand in reverse order: unmount the filesystem, close
   LUKS, stop the md array, remove the dm-zoned mappers. See [03](03-guest-storage-stack.md).

2. **On DSM, stop the watcher,** so it cannot re-attach the controller to the old guest:

   ```sh
   /usr/local/etc/rc.d/S99zoned-attach.sh stop
   ```

3. **If the old guest is still running, detach the controller live** with the source-only XML:

   ```sh
   /usr/local/bin/virsh detach-device <OLD_GUEST_DOMAIN_UUID> /volume1/zoned-attach/hostdev.xml --live
   # Device detached successfully
   /usr/local/bin/virsh dumpxml <OLD_GUEST_DOMAIN_UUID> | grep -c '<hostdev'    # 0
   ```

   If the old guest is powered off, skip this. Powering a guest off drops the attach anyway.

4. **Point the config at the new guest.** Keep a copy of the old config so the move is easy to
   undo:

   ```sh
   cp /volume1/zoned-attach/attach.conf /volume1/zoned-attach/attach.conf.<OLD_GUEST_NAME>
   vi /volume1/zoned-attach/attach.conf          # DOM="<NEW_GUEST_DOMAIN_UUID>"
   ```

   The new guest must be running to show up in `virsh list` (Step 2, item 5).

5. **Start the watcher with the new config and check the result:**

   ```sh
   /usr/local/etc/rc.d/S99zoned-attach.sh start
   sleep 20
   tail -n 3 /volume1/zoned-attach/attach.log                                    # attached ...
   /usr/local/bin/virsh dumpxml <NEW_GUEST_DOMAIN_UUID> | grep -c '<hostdev'    # 1
   ```

To move back, reverse the steps and restore the saved `attach.conf.<OLD_GUEST_NAME>`.

> **Why stop the watcher before detaching:** a running watcher still has the old `DOM=`. If
> the old guest is still running, the watcher attaches the controller to it again within
> 15 seconds of the detach.

## What happens on restarts

| Event | Effect on the controller | What brings it back |
|---|---|---|
| Reboot **inside** the guest (`systemctl reboot`) | Stays attached. QEMU keeps running. | Nothing needed. Drives are probed during the guest's boot. |
| Guest shut down and started again (VMM power cycle) | The attach is gone. VMM rebuilds the guest's definition. The binding to `vfio-pci` stays. | The watcher re-attaches within about 15 s of the guest reaching `running`. Drives appear 1–3 min later. |
| Forced stop (power off) of the guest | Same as a power cycle | Same. Avoid forced stops and resets: the 2026-09-19 crash coincided with a watchdog reset of a guest that carried the controller. |
| NAS reboot | Everything is gone. `driver_override` is a runtime setting, so DSM's `ahci` driver takes the controller again at boot. | The rc.d hook starts the watcher, VMM starts the guest, and the watcher attaches it. |

## Optional: nested virtualization

Leave `WANT_NESTED=0` unless the guest runs virtual machines itself. An OpenMediaVault guest
does not. The author needed it only for an earlier design, where the drives went to a
Proxmox VE guest inside VMM.

- VMM has no setting for nested virtualization. Exposing `vmx` to guests is a parameter of
  DSM's `kvm_intel` module. It defaults to off on DSM's 4.4 kernel and cannot be changed
  while the module is loaded. DSM has no `/etc/modprobe.d`, so the setting cannot be made
  persistent the normal way.
- With `WANT_NESTED=1` the watcher reloads the module with `insmod /lib/modules/kvm-intel.ko
  nested=1`. It does this only while **no** guest is running and the module is not in use.
  In practice that means at NAS boot, before VMM starts its guests. It keeps trying for
  about the first 20 minutes. If the reload fails, it loads the module again without the
  parameter.
- It worked on the author's NAS: `nested: enabled` was logged at boot, before any guest
  started.
- This is Intel only (`kvm_intel`). It has not been tried on AMD-based models.

## Disarming and removing

```sh
# Disarm: every pass becomes a no-op at once, without restarting anything
rm /volume1/zoned-attach/attach.enable

# Stop the watcher and do not start it at the next boot
/usr/local/etc/rc.d/S99zoned-attach.sh stop
rm /usr/local/etc/rc.d/S99zoned-attach.sh
```

To give the controller back to DSM, release the pool and shut the guest down (or detach the
controller as in [Moving the controller](#moving-the-controller-to-another-guest), step 3).
Then reboot the NAS. After the reboot, `ahci` owns the controller again, because the
`vfio-pci` binding does not survive a reboot. DSM still cannot use host-managed drives.

The author has not tested whether a DSM update keeps `/usr/local/etc/rc.d/`. After every DSM
update, check that the hook is still there and that the watcher is running.

## Troubleshooting

| What you see | What it means | What to do |
|---|---|---|
| `CONFIG ERROR: PROTECT_PCI_HARD ... is empty` | The script was not edited | Step 3, item 3 |
| `CONFIG ERROR: protected address '...' does not exist` | Typo, or the short form without `0000:` | Use the full address as shown by `census` |
| `watcher NOT started (fix the config, then restart)` | A config check failed when the watcher started | Fix the config, then `S99zoned-attach.sh restart` |
| `watcher exited immediately` in the system log | The new watcher was gone at the hook's startup check | Read `/volume1/zoned-attach/attach.log`, fix the error, then restart. If the log shows nothing new, run `sh /volume1/zoned-attach/synology-zoned-attach.sh status` in the foreground to see shell/config errors. |
| `watcher STILL running after 60s` | The wall-clock stop deadline expired (plus scan overhead); restart was aborted | Run `/usr/local/etc/rc.d/S99zoned-attach.sh status` every few seconds until `watcher NOT running`, then `start` and check `status` again. It prints the PIDs; see the timeout procedure above for a hung child. Do not remove `attach.lock` by hand. |
| `another start/stop/restart or manual once is running` (system log; `attach.log` for `once`), or a lifecycle-lock recovery error | Another call holds `/tmp/zoned-attach-hook.lock`, or its owner record is incomplete, invalid or names a reused PID | Wait for a live call. A dead owner's lock is recovered automatically on the next call. For a persistent refusal, use [Recovering a stale lifecycle lock](#recovering-a-stale-lifecycle-lock) to check processes, remove the owner record and empty lock directory, and retry. |
| `no usable controller (census empty and recorded address invalid)` | The guest is running, but no controller has exactly `ZONED_COUNT` zoned drives behind it, and there is no valid recorded address | Run `census`. Check the drive count, `ZONED_MODEL` and the expansion unit's power and cable. |
| `REFUSE <addr>: a DSM drive model is behind it` | A controller of the configured type has a DSM drive behind it | If it is one of DSM's controllers, add it to `PROTECT_PCI_HARD`. If it is the expansion unit, take the DSM drive out: this unit may hold zoned drives only. |
| `REFUSE: 2 controllers match the census - ambiguous` | Two controllers qualify | Make the config specific enough, or remove the drives from one of them. Until then the watcher uses only an address it recorded earlier, if that address still passes every check. |
| `vfio-pci driver not loaded` | `/sys/bus/pci/drivers/vfio-pci` is missing | The script does not load modules. On the tested NAS the bind worked with VMM running. Check `grep vfio /proc/modules` and that VMM is running. |
| `vfio bind FAILED` | The controller did not end up on `vfio-pci` | Check `readlink /sys/bus/pci/devices/<addr>/driver` and the IOMMU group |
| `attach FAILED` on every pass | libvirt refused the attach | Run the attach by hand to see the error: `/usr/local/bin/virsh attach-device <GUEST_DOMAIN_UUID> /volume1/zoned-attach/hostdev.xml --live`. One possible cause: the controller is still attached to another running guest. |
| `attached ...` but no drives in the guest | Enumeration takes 1–3 min | Wait. Then check `lspci` and `dmesg` in the guest. |
| Watcher not running after a NAS boot | `/volume1` was not mounted within 5 minutes (for example an encrypted volume waiting for a manual unlock) | Look for `zoned-attach` in the system log. Start it with `S99zoned-attach.sh start`. |
| `status` shows `lock present` while no pass is running | A pass was killed hard | Confirm any pending child has terminated (timeout procedure above). `S99zoned-attach.sh restart` removes the stale pass lock after confirming the watcher has stopped and excluding manual passes. If restart refuses because of the lifecycle lock, recover that lock first (row above). |

## Differences from the author's as-built script

The published script is the author's watcher (peer-reviewed v2, in use since 2026-09-13),
made configurable. These parts are new and have **not** run on the author's NAS:

- `DSM_MODEL` may list several models.
- The typo guard for protected addresses.
- Checks that the controller has an IOMMU group, that `vfio-pci` is loaded, and that no DSM
  drive sits behind a recorded address.
- The refusal when more than one controller matches.
- The read-only `census` mode.
- Exiting cleanly (and releasing the lock) when stopped in the middle of a pass.
- The boot hook is a rewrite. It keeps the as-built hook's behaviour (wait up to 60 × 5 s
  for `/volume1`, log through `logger`) and adds `stop`/`restart`/`status`, a check against
  starting a second watcher, and stale-lock cleanup. A `mkdir` lifecycle lock serializes
  start/stop/restart and manual `once` passes; its PID owner record allows stale recovery
  after a hard kill. Process detection matches exact
  `/proc/*/cmdline` arguments, without `pgrep`, using comparison strings built once;
  status prints the PIDs. Stopping polls the signalled PIDs against a 60-second wall-clock
  deadline and does a final full scan. Synchronous restart propagates errors, and startup
  checks the new PID after 2 seconds before logging success. Watcher stderr is appended
  to `attach.log`.

The script and hook were exercised locally against a simulated sysfs tree and a stand-in for
`virsh`. That covered the protection checks, the census, attaching, restarting and stopping.
They have not been run on a Synology in this exact form.

## Next

[03 — Guest storage stack](03-guest-storage-stack.md): dm-zoned, RAID5, LUKS2 and XFS inside
the guest, and the boot chain that waits for the late drives.
