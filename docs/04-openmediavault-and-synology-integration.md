# 04 - OpenMediaVault and Synology integration

This guide takes the encrypted XFS filesystem from
[03-guest-storage-stack.md](03-guest-storage-stack.md) and makes it useful to the Synology:

- OpenMediaVault (OMV) manages the mount, but the mount still waits for the late
  assembly chain.
- Shared folders, an NFS export, an SMB share and two rsync daemon modules sit on top of it.
- DSM uses the pool in three ways. **Hyper Backup** writes to one rsync module. A **shell
  rsync push** copies media into the other. File Station mounts the NFS export as a
  **remote folder**.

DSM never sees the drives themselves. Everything goes over the network into the guest.

> [!WARNING]
> **Tested on one setup only:** a DS3622xs+ (DSM 7.4) with a DX1222 expansion unit,
> 3 x WD Ultrastar HC680 27 TB, and a Debian 13 / OpenMediaVault 8.5.9 guest on kernel
> `7.2.6-070206-generic`. The guest gets the **whole SATA controller** the zoned drives sit
> behind, so the approach depends on that controller being one that DSM does not use for its
> own disks. It will not work where the zoned drives would share the controller DSM boots
> and runs from, for example on a DS1821+ in this layout. The NAS kernel panic from
> 2026-09-24 is still unexplained. Read
> [01-requirements-and-risks.md](01-requirements-and-risks.md) before you build this, and
> keep backups.

Package versions in the tested guest: openmediavault 8.5.9-1, rsync 3.4.1,
nfs-kernel-server 2.8.3, samba 4.22.11.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Driving OMV: UI, RPC and deploy](#2-driving-omv-ui-rpc-and-deploy)
3. [Register the filesystem in OMV, with the ordering options](#3-register-the-filesystem-in-omv-with-the-ordering-options)
4. [Service users and directories](#4-service-users-and-directories)
5. [Shared folders](#5-shared-folders)
6. [NFS export](#6-nfs-export)
7. [SMB share](#7-smb-share)
8. [The rename trap: NFS export stuck at the old path](#8-the-rename-trap-nfs-export-stuck-at-the-old-path)
9. [rsync daemon modules](#9-rsync-daemon-modules)
10. [Hyper Backup task on DSM](#10-hyper-backup-task-on-dsm)
11. [NFS remote folder in DSM File Station](#11-nfs-remote-folder-in-dsm-file-station)
12. [Pushing data from the DSM shell with rsync](#12-pushing-data-from-the-dsm-shell-with-rsync)
13. [Verifying a copy with a dry run](#13-verifying-a-copy-with-a-dry-run)
14. [What healthy looks like](#14-what-healthy-looks-like)
15. [Pitfalls at a glance](#15-pitfalls-at-a-glance)

---

## Layout

```
DSM (the NAS)                                       Guest (Debian 13 / OMV 8)
                                                    /srv/hc680  (XFS on hc680crypt, docs/03)
Hyper Backup ---- rsync daemon, TCP 873 -------->   module hc680-backup -> /srv/hc680/backup
shell rsync push - rsync daemon, TCP 873 ------->   module hc680-media  -> /srv/hc680/media
File Station remote folder -- NFS v4 ----------->   /export/media (bind mount of /srv/hc680/media)
(Windows / other clients) --- SMB -------------->   [media] -> /srv/hc680/media
```

The names `backup`, `media`, `hc680-backup`, `hc680-media`, `hcbackup` and `hcmedia` are
examples. The as-built guest uses the same pattern, with `-v2` suffixes on the module names
left over from a rebuild.

Placeholders used below:

| Placeholder | Meaning |
|---|---|
| `<GUEST_IP>` | The guest's IP address. Give the guest a DHCP reservation or a static address, because the DSM tasks point at it. |
| `<LAN_CIDR>` | Your LAN in CIDR notation, used in `hosts allow` and the NFS client field. |
| `<XFS_UUID>` | `blkid -s UUID -o value /dev/mapper/hc680crypt` |
| `<MEDIA_UID>` | Unused UID chosen for the media service account (section 4). |
| `<MEDIA_GID>` | GID of the existing `users` group, the media account's primary group: `getent group users \| cut -d: -f3` (normally 100). |
| `<BACKUP_UID>`, `<BACKUP_GID>` | Unused numeric ids chosen for the backup account and `hcbackup` group (section 4). |
| `<SHAREDFOLDER_UUID>`, `<NFS_SHARE_UUID>` | UUIDs of OMV configuration objects, as OMV prints them. |

---

## 1. Before you start

- The pool is built and has passed both reboot tests in
  [03-guest-storage-stack.md, Step 11](03-guest-storage-stack.md#step-11---enable-the-chain-and-test-a-full-reboot).
- The LUKS container is open, and `findmnt /srv/hc680` shows `/dev/mapper/hc680crypt`. If
  you mounted the pool by hand, unmount it before section 3 (`umount /srv/hc680`). Its
  fstab line must go too; section 3b shows how.
- OMV 8 is installed in the guest and you can log in to its web UI. This guide does not
  install it: on a fresh Debian 13 guest, follow the official procedure
  <https://docs.openmediavault.org/en/stable/installation/on_debian.html> (repository and key,
  packages, `omv-confdbadm populate`, network deployment). Check that `omv-rpc`,
  `omv-confdbadm` and `omv-salt` exist. An independent reproduction used OMV 8.5.9-1.
- You have a root shell on the guest and on DSM. For DSM, enable SSH in Control Panel, log in
  as an administrator and run `sudo -i`.

---

## 2. Driving OMV: UI, RPC and deploy

Most steps below can be done in OMV's web UI. The web UI calls the same RPC methods that
`omv-rpc` calls from a root shell on the guest. The author did most of this over RPC, and
the exact calls are shown where it matters.

A change goes through two stages. First, a UI "Save" or an RPC `set` call writes the
object to OMV's configuration database. Then a **deploy** writes the real configuration
files and restarts services:

```sh
omv-salt deploy run fstab          # /etc/fstab and mounts
omv-salt deploy run nfs            # /etc/exports, nfs-server
omv-salt deploy run samba          # /etc/samba/smb.conf, smbd
omv-salt deploy run rsyncd         # /etc/rsyncd.conf, secrets files, rsync daemon
```

Things the author learned about this:

- **Changes made over RPC leave the "pending changes" banner in the UI.** Clear it the way
  the UI's Apply button does:

  ```sh
  omv-rpc -u admin Config applyChanges '{"modules":[],"force":false}'
  ```

- **`applyChanges` alone did not redeploy fstab** after a mount entry's options changed.
  Run `omv-salt deploy run fstab` explicitly.
- **The "new object" sentinel.** To create an object over RPC, you pass a fixed UUID as
  `uuid`. For NFS shares you also pass it as `mntentref`. This value is a constant defined
  by OMV, not a machine identifier. On OMV 8.5.9 it is
  `fa4b1c66-ef79-11e5-87a0-0002b3a176b4`. A different value that is sometimes quoted was
  wrong on the author's system. Check yours:

  ```sh
  grep -rs OMV_CONFIGOBJECT_NEW_UUID /etc/default/openmediavault /usr/share/php/openmediavault | head -3
  ```

- To read what OMV has stored, use the configuration database directly:

  ```sh
  omv-confdbadm read conf.system.filesystem.mountpoint | python3 -m json.tool
  omv-confdbadm read conf.system.sharedfolder        | python3 -m json.tool
  omv-confdbadm read conf.service.nfs.share          | python3 -m json.tool
  ```

- The parameter schemas of the RPC methods are in
  `/usr/share/openmediavault/datamodels/`. Two examples are `rpc.nfs.json` and
  `rpc.rsyncd.json`. If an RPC call is rejected with a validation error, compare your
  parameters with the schema there.

---

## 3. Register the filesystem in OMV, with the ordering options

OMV owns everything in `/etc/fstab` between `# >>> [openmediavault]` and
`# <<< [openmediavault]`, and it regenerates that block on every fstab deploy. OMV's shared
folders, NFS exports and rsync modules can only be created on a filesystem that OMV has a
mount entry for.

So the mount entry must live in OMV's database. It must also carry the options that make it
wait for the late assembly chain. If they are missing, systemd waits the default 90 s for
`/dev/mapper/hc680crypt`, which appears minutes into the boot. Then it gives up, and a
`nofail` mount that has timed out is never retried. The pool stays unmounted.

The options (explained in [03, Step 10](03-guest-storage-stack.md#step-10---the-fstab-line)):

```
defaults,noatime,inode64,nofail,x-systemd.requires=zonedpool-mdassemble.service,x-systemd.requires=zonedpool-cryptopen.service,x-systemd.device-timeout=15min
```

**Why the RPC and not the UI's Mount dialog:** the dialog chooses its own mount point
(`/srv/dev-disk-by-uuid-<UUID>`). The author registered the entry through the `FsTab` RPC so
that the mount point (`/srv/hc680`) and the options are exactly the ones above.

### 3a. Only when rebuilding: remove the old pool's OMV objects first

Skip this on a fresh OMV install, or when rebuilding with the same array and filesystem
UUIDs and the same paths. For that rebuild, keep the existing OMV objects and follow the
rebuild note in [03, Step 3](03-guest-storage-stack.md#step-3---format-each-drive-for-dm-zoned).

When the author rebuilt the pool, OMV's database still described the old one: mount
entries for the destroyed filesystems, a union mount and an NFS bind mount. As a result,
**NFS failed at boot on a dependency** and the File Systems page showed errors. Rsync modules
that pointed at deleted shared folders also made `omv-salt deploy run rsyncd` fail.

Delete the objects that depend on others first: rsync modules, NFS shares, SMB shares,
shared folders, and last the old mount entries. The UI is simplest: Services › Rsync ›
Server › Modules, Services › NFS › Shares, Services › SMB/CIFS › Shares, Storage › Shared
Folders, Storage › File Systems.

> [!WARNING]
> Delete **configuration objects only**. When deleting a shared folder, do not choose to
> delete its content. Over RPC, the author's scripts called
> `ShareMgmt delete '{"uuid":"<SHAREDFOLDER_UUID>","recursive":false}'`. Check twice
> that each object belongs to the **old** pool.

### 3b. Create the mount entry

**If you wrote the fstab line by hand** ([03, Step 10](03-guest-storage-stack.md#step-10---the-fstab-line)),
remove it first. It sits outside OMV's block, and OMV keeps it, so registering adds a second
entry for `/srv/hc680`. Back up `/etc/fstab`, make sure the pool is unmounted, and delete only
that one line outside `# >>> [openmediavault]` ... `# <<< [openmediavault]`:

```sh
cp -a /etc/fstab /etc/fstab.before-omv
editor /etc/fstab            # delete the hand-written /srv/hc680 line only
```

After the deploy in 3c, check that exactly one active entry remains:

```sh
awk '$1 !~ /^#/ && $2=="/srv/hc680" {n++; print} END {exit n!=1}' /etc/fstab && echo "one entry"
```

The container must be open (`cryptsetup status hc680crypt` reports it active). Then:

```sh
blkid -s UUID -o value /dev/mapper/hc680crypt        # -> <XFS_UUID>

omv-rpc -u admin FsTab set '{
  "uuid":   "fa4b1c66-ef79-11e5-87a0-0002b3a176b4",
  "fsname": "/dev/disk/by-uuid/<XFS_UUID>",
  "dir":    "/srv/hc680",
  "type":   "xfs",
  "opts":   "defaults,noatime,inode64,nofail,x-systemd.requires=zonedpool-mdassemble.service,x-systemd.requires=zonedpool-cryptopen.service,x-systemd.device-timeout=15min",
  "freq":   0,
  "passno": 2,
  "hidden": false
}'
```

The reply contains the new entry's own `uuid`. The UI uses it for you when you pick this
filesystem later.

> [!NOTE]
> The field list above matches the as-built mount entry. The author's exact `FsTab set`
> invocation was not recorded. If OMV rejects a field or asks for another one, compare with
> an existing entry (`omv-confdbadm read conf.system.filesystem.mountpoint`) and with the
> datamodel files mentioned in section 2.

### 3c. Deploy and check

```sh
omv-salt deploy run fstab
grep -A3 '>>> \[openmediavault\]' /etc/fstab
findmnt /srv/hc680
```

The OMV block must contain the line with all the options
([examples/fstab.example](../examples/fstab.example)). `findmnt` must show **exactly one**
mount of `/srv/hc680`, from `/dev/mapper/hc680crypt`.

**Why check for one mount:** in one build, the author's hand mount and the mount done by
OMV's deploy ended up stacked on `/srv/hc680`. They had to be reduced to one. If you see
two lines, run `umount /srv/hc680` once and check again.

**Why deploy only while the container is open:** the fstab deploy also mounts the
filesystem. In one run, the deploy reported a failed state because it ran while the crypt
device did not exist yet. Run with everything open and mounted, the same deploy finished
with 0 failures.

**Do not deploy fstab while the stack is unhealthy.** The deploy mounts as a side effect.
During the incident with a stuck dm-zoned worker, the author deliberately did not run it
([05-operations-monitoring-performance.md](05-operations-monitoring-performance.md)).

### 3d. Changing the options later

The author changed options on existing entries with `FsTab set` on the existing object,
followed by `omv-salt deploy run fstab`. Print the current object:

```sh
omv-confdbadm read conf.system.filesystem.mountpoint \
  | python3 -c 'import sys,json; [print(json.dumps(m)) for m in json.load(sys.stdin) if m["dir"]=="/srv/hc680"]'
```

Pass that JSON, with the same `uuid` and the edited `opts`, to `omv-rpc -u admin FsTab set
'<json>'`. Then run `omv-salt deploy run fstab`. A running mount does not pick up new
options until it is remounted or the guest reboots.

Finally, run the reboot test from [03, Step 11](03-guest-storage-stack.md#step-11---enable-the-chain-and-test-a-full-reboot)
once more, now with OMV managing the mount.

---

## 4. Service users and directories

You need two service accounts. The Hyper Backup module writes as `hcbackup`. The media
module and the NFS export write as `hcmedia`.

1. **Pick unused UIDs for both accounts and an unused GID for `hcbackup`.** The media
   account keeps the existing `users` group; do not choose a new `<MEDIA_GID>`.
   OMV already uses low system ids.
   On the author's guest, uid 999 was `openmediavault-webgui`, uid 997 was `salt` and gid
   988 was `sambashare`. Check each id you plan to use:

   ```sh
   getent passwd 1001; getent group 1001      # no output = free
   ```

   **Why:** the author had planned to keep the ids the service accounts had on an older
   host. They collided with OMV's accounts, so new ids were chosen and the existing files
   were re-owned by exact id mapping.

2. **Create the `hcbackup` group first.** Users › Groups › Create has no GID field. To use
   the unused GID chosen in step 1, use Users › Groups › Import with the CSV line
   `hcbackup;<BACKUP_GID>;`, replacing the placeholder. Alternatively, use RPC:

   ```sh
   omv-rpc -u admin UserMgmt setGroup '{"name":"hcbackup","gid":<BACKUP_GID>,"comment":"","members":[]}'
   ```

   **Verify after either the Import or RPC route:**

   ```sh
   getent group hcbackup
   test "$(getent group hcbackup | cut -d: -f3)" = <BACKUP_GID> && echo 'OK: hcbackup GID matches' || echo 'STOP: hcbackup group missing or GID differs'
   ```

   Replace `<BACKUP_GID>` in both commands before running them. Stop if the group is missing
   or its GID differs from the one you chose.

   Read `<MEDIA_GID>` from the existing `users` group, which OMV uses as the media
   account's primary group. Keep this number for the NFS `anongid` option:

   ```sh
   getent group users | cut -d: -f3
   ```

   Stop if this prints no GID.

3. **Create the users** with a login shell of `/usr/sbin/nologin`, in Users › Users. Create
   has no UID field either: to retain the UID chosen in step 1, use Users › Users › Import
   with `hcbackup;<BACKUP_UID>;;;<PASSWORD>;/usr/sbin/nologin;;false` and an equivalent line
   for `hcmedia` with `<MEDIA_UID>`. Replace all placeholders in the import dialog. Over RPC,
   `UserMgmt setUser` **must** get an explicit `uid`, because the schema's default of 0
   breaks `useradd`. Create the users **before** any rsync module that refers to them.

   OMV gives users the primary group `users` and re-applies it whenever an account is saved.
   The media tree uses this group, including `<MEDIA_GID>` for squashed NFS clients.
   Directory group ownership comes from the setgid bit (step 4), and the rsync module
   explicitly sets its Group (section 9b).
   Check that both accounts exist and have the chosen UIDs:

   ```sh
   getent group hcbackup
   getent passwd hcbackup hcmedia
   id hcbackup; id hcmedia
   test "$(id -u hcbackup)" = <BACKUP_UID> && echo 'OK: hcbackup UID matches' || echo 'STOP: hcbackup account missing or UID differs'
   ```

   Then verify the media UID:

   ```sh
   test "$(id -u hcmedia)" = <MEDIA_UID> && echo 'OK: hcmedia UID matches' || echo 'STOP: hcmedia account missing or UID differs'
   ```

   Replace the UID placeholders before running the checks. Stop if either account or group
   is missing, or a UID differs from the one you chose.

4. **Create the directories yourself, with the owner and mode you want:**

   ```sh
   install -d -o hcbackup -g hcbackup -m 2775 /srv/hc680/backup
   install -d -o hcmedia  -g users    -m 2775 /srv/hc680/media
   ```

   These are the as-built owners and modes. Run the commands only while
   `findmnt /srv/hc680` shows the pool. Otherwise the directories end up on the guest's root
   filesystem.

   **Why:** OMV applies a shared folder's mode only when it creates the directory itself. A
   directory that already exists keeps its owner and mode. In a lab test, an existing
   `root 0755` directory let SMB users log in and list files, but every write failed with
   `NT_STATUS_ACCESS_DENIED`. The fix was `chgrp users <dir>; chmod 2775 <dir>`, or OMV's
   ACL dialog.

---

## 5. Shared folders

In Storage › Shared Folders › Create:

| Name | File system | Relative path | Used by |
|---|---|---|---|
| `backup` | the `/srv/hc680` entry from section 3 | `backup/` | rsync module `hc680-backup` only |
| `media` | the `/srv/hc680` entry from section 3 | `media/` | NFS export, SMB share, rsync module `hc680-media` |

**Choose the final names now.** OMV names the SMB share after the shared folder, and the
NFS export path is `/export/<shared-folder-name>`. Renaming a shared folder later changes
both. For NFS, it breaks the export until you recreate it (section 8).

The `backup` folder is deliberately **not** exported over NFS or SMB. Only the
authenticated rsync module reaches it.

Over RPC, `ShareMgmt set` accepts only `mode` values of 700, 750, 755, 770, 775 or 777.

If creating a shared folder fails partway, OMV can keep the database entry anyway. A retry
then reports that a shared folder with that name already exists. Delete the entry in
Storage › Shared Folders and create it again.

---

## 6. NFS export

1. **Settings.** Services › NFS › Settings: enable the server, and tick the protocol versions
   you want, including v4. The author's rehearsal enabled 3, 4, 4.1 and 4.2.

   **Why:** over RPC, `NFS setSettings` must list the versions. An empty list writes every
   version as disabled, and `mountd` then fails with "No protocol versions specified".

2. **Share.** Services › NFS › Shares › Create:

   | Field | As built |
   |---|---|
   | Shared folder | `media` |
   | Client | `<LAN_CIDR>` |
   | Privilege | read/write |
   | Extra options | `subtree_check,insecure,all_squash,anonuid=<MEDIA_UID>,anongid=<MEDIA_GID>` |

   `all_squash` with `anonuid`/`anongid` maps every NFS client, including DSM's root, to
   the media account. Files written through the export are therefore owned by `hcmedia`,
   whoever writes them. OMV adds an `fsid` option by itself.

3. **Apply and check:**

   ```sh
   omv-salt deploy run fstab nfs
   cat /etc/exports
   findmnt /export/media
   exportfs -v
   showmount -e localhost
   ```

   You should see two exports: `/export`, which is the NFS v4 root, and `/export/media`.
   `/export/media` must be a bind mount of `/srv/hc680/media`. In `/etc/fstab`, OMV writes
   it as `/srv/hc680/media/  /export/media  none  bind,nofail  0 0`.

**How OMV exports NFS.** OMV does not export `/srv/hc680/media` directly. It bind-mounts the
shared folder to `/export/<name>` and exports that. `/export` is the NFS v4 pseudo-root
(`fsid=0`). So one share has two paths:

| Protocol | Path to mount |
|---|---|
| NFS v4 | `<GUEST_IP>:/media` (relative to the v4 root) |
| NFS v3 | `<GUEST_IP>:/export/media` |

The author's first attempt used `/export/media` with v4, and it failed.

**If you use the RPC:** `NFS setShare` needs `mntentref` as well as `sharedfolderref`. For a
new share, set both `uuid` and `mntentref` to the sentinel from section 2. The NFS code
creates the bind-mount entry only while creating a new object. An update of a half-created
object cannot add it later: delete it and create it again. `extraoptions` must not be
empty.

In the passing boot test, the bind mount came up right after `/srv/hc680` was mounted, and
NFS was active right after that. Ninety seconds into the boot, the pool, the bind mount,
NFS, SMB and rsync were all up.

---

## 7. SMB share

Services › SMB/CIFS › Settings: enable. Services › SMB/CIFS › Shares › Create: shared
folder `media`. Give the users who connect over SMB read/write access in the shared folder's
Privileges. Then:

```sh
omv-salt deploy run samba
testparm -s 2>/dev/null | grep -A3 '^\[media\]'      # path = /srv/hc680/media/
```

The share is `\\<GUEST_IP>\media`. **Its name is the shared folder's name, not a name you
type.** Two consequences the author ran into:

- If you point an existing SMB share at a different shared folder, it takes that folder's
  name. When the author re-pointed the SMB share at a folder named `hc680-media`, the share
  became `\\<GUEST_IP>\hc680-media` and the old `[media]` section disappeared.
- Renaming the shared folder renames the SMB share after `omv-salt deploy run samba`.
  Existing drive mappings on clients then point at a name that no longer exists.

DSM does not need SMB in this setup. It is here for other clients.

---

## 8. The rename trap: NFS export stuck at the old path

Renaming a shared folder in OMV changes its **name**, not its directory. Here is what
happens to each service after the rename and
`omv-salt deploy run samba nfs rsyncd`:

| Service | After the rename |
|---|---|
| SMB | Follows: the share is now called after the new name. |
| rsync module | Unchanged: the module has its own name, and its path (`/srv/hc680/./media`) did not change. |
| NFS | **Broken.** `/etc/exports` now lists `/export/<newname>`, but the bind mount stays at `/export/<oldname>`. |

The NFS export's bind-mount entry is fixed when the NFS share is created. The export
directory, however, follows the shared folder's name. Symptom:

```
exportfs: Failed to stat /export/<newname>
```

Running `NFS setShare` on the existing NFS share object does **not** fix it. The fix is to
delete the NFS share and create it again.

> [!WARNING]
> Recreating the export gives it a **new `fsid`**. Any client that still has it mounted gets
> stale file handles. **Unmount the DSM remote folder (section 11) and any other NFS clients
> first**, and mount them again afterwards. Anything reading from the share, such as a media
> server scanning a library, sees it vanish for that time.

**In the UI:** Services › NFS › Shares. Note the client, privilege and extra options of the
existing share. Delete it, apply, create it again with the same values, and apply. Then
clean up on the guest:

```sh
findmnt /export/<oldname>        # must be the stale bind mount of /srv/hc680/<dir>
umount /export/<oldname>
rmdir /export/<oldname>          # rmdir only removes an empty directory
exportfs -ra
findmnt /export/<newname>
exportfs -v
```

**Over RPC, as the author did it:**

```sh
# 1. Note the existing share's fields (uuid, sharedfolderref, client, options, extraoptions).
omv-confdbadm read conf.service.nfs.share | python3 -m json.tool

# 2. Delete it.
omv-rpc -u admin NFS deleteShare '{"uuid":"<NFS_SHARE_UUID>"}'

# 3. Create it again. uuid AND mntentref = the "new object" sentinel (section 2).
#    Use the field values you noted in step 1. The NFS share model has no "readonly" property.
omv-rpc -u admin NFS setShare '{
  "uuid":            "fa4b1c66-ef79-11e5-87a0-0002b3a176b4",
  "mntentref":       "fa4b1c66-ef79-11e5-87a0-0002b3a176b4",
  "sharedfolderref": "<SHAREDFOLDER_UUID>",
  "client":          "<LAN_CIDR>",
  "options":         "rw",
  "extraoptions":    "subtree_check,insecure,all_squash,anonuid=<MEDIA_UID>,anongid=<MEDIA_GID>",
  "comment":         ""
}'

# 4. Deploy, remove the stale bind mount, re-export.
omv-salt deploy run fstab nfs
umount /export/<oldname> && rmdir /export/<oldname>
exportfs -ra
```

The easiest way to avoid all this is to not rename shared folders that are exported over
NFS. If you must rename, plan the NFS recreate and the client remounts together with it.

---

## 9. rsync daemon modules

Two modules, one per job:

- `hc680-backup` is the Hyper Backup target.
- `hc680-media` receives media pushed from the DSM shell. It exists so that big copies are
  resumable and do not depend on a mount path on the DSM side (section 12).

### 9a. Server settings

Services › Rsync › Server › Settings: enable, port 873.

### 9b. The modules

Services › Rsync › Server › Modules › Create. Create the users from section 4 first.

| Field | `hc680-backup` | `hc680-media` |
|---|---|---|
| Shared folder | `backup` | `media` |
| Name | `hc680-backup` | `hc680-media` |
| User (uid) | `hcbackup` | `hcmedia` |
| Group (gid) | `hcbackup` | `users` |
| Use chroot | yes | yes |
| Read only | no | no |
| List | **yes** | **yes** |
| Authenticate users | yes: user `hcbackup`, with a password | yes: user `hcmedia`, with a password |
| Hosts allow | `<LAN_CIDR>` | `<LAN_CIDR>` |

Then:

```sh
omv-salt deploy run rsyncd
grep -A15 '^\[hc680-media\]' /etc/rsyncd.conf
ls -l /var/lib/openmediavault/rsyncd-*.secrets
```

What to look for:

- `path = /srv/hc680/./media`. With `use chroot`, the daemon chroots into the part before
  `/./` (`/srv/hc680`).
- `auth users`, `hosts allow` and `list` as set above.
- A `secrets file` per module, at `/var/lib/openmediavault/rsyncd-<module-name>.secrets`.

**The password that matters is the module's.** The rsync daemon checks the username and
password against the module's secrets file, not against the account's system password.
When you change it, change it in the module and redeploy. Then re-authenticate every
client (section 10).

**Why `list = yes`:** Hyper Backup fills its module dropdown by asking the daemon to list
modules. With `list = no`, the dropdown was empty, you could not type a name into it, and the
task could not be created. Access is still limited by `hosts allow` and `auth users`. Only
the module **names** become visible to allowed hosts.

**Why the whole LAN in `hosts allow`:** DSM can connect **from a different address than the
one its UI shows**. In the author's setup, it connected from another of the NAS's own
addresses. If you want to allow only the NAS, first read the real source address from the
daemon's log on the guest (`journalctl -u rsync`, or the file set with `log file` in
`/etc/rsyncd.conf` if there is one). It looks like this:

```
rsync allowed access on module hc680-backup from UNKNOWN (<NAS_IP>)
```

Over RPC, the author created modules with `Rsyncd setModule` using the new-object sentinel as
`uuid`. The fields were `sharedfolderref`, `name`, `uid`, `gid`, `readonly`, `list`,
`usechroot`, `authusers`, `users` (a list of `{name, password}`) and `hostsallow`, and the
rest were filled from the datamodel defaults. The UI does the same thing and is simpler.

### 9c. Test from a LAN host, not from the guest

`hosts allow` covers the LAN only, so a test from `localhost` on the guest is refused. The
NAS is the natural test client. On DSM, as root:

```sh
umask 077
cat > /root/.hc680-media.pw      # type the module password, press Enter, then Ctrl-D
chmod 600 /root/.hc680-media.pw

rsync rsync://<GUEST_IP>/                                                            # lists the modules
rsync --list-only --password-file=/root/.hc680-media.pw rsync://hcmedia@<GUEST_IP>/hc680-media/
```

The second command must exit with status 0 and list the (possibly empty) module.
rsync refuses a password file that other users can read. That is what `chmod 600` is for.

---

## 10. Hyper Backup task on DSM

Hyper Backup's "rsync-compatible server" destination speaks the rsync **daemon** protocol.
It talks directly to TCP 873 when transfer encryption is off. With transfer encryption on,
it tunnels the same protocol over SSH. The author runs it with transfer encryption **off**,
on the LAN. The SSH variant needs an SSH login for `hcbackup` on the guest. It was not set
up or tested on OMV.

### 10a. Create the task

1. In DSM, open Hyper Backup › **+** › **Data backup task**.
2. Destination: **File Server › rsync**. Server type: **rsync-compatible server**.
3. Settings:

   | Field | Value |
   |---|---|
   | Server name or IP address | `<GUEST_IP>` |
   | Transfer encryption | off |
   | Port | 873 |
   | Username | `hcbackup` |
   | Password | the `hc680-backup` module password |
   | Backup module | `hc680-backup` (from the dropdown) |
   | Directory | a name for this task's repository. Hyper Backup creates `<name>.hbk` inside the module. |

4. Choose the source folders and applications. Then choose the schedule, compression and
   rotation as you would for any Hyper Backup task.
5. **Client-side encryption must be decided now.** You can only switch it on when the
   task is created. Turning it on later means a new task and a full new seed. If you
   enable it, export the recovery key and keep it off the NAS. Without the password or
   that key, the backup cannot be restored.

   The pool itself is LUKS-encrypted at rest ([03, Step 7](03-guest-storage-stack.md#step-7---luks2-encryption)).
   With transfer encryption off, the backup data crosses the LAN unencrypted, unless
   client-side encryption is on.

6. Start the first backup. When it has finished, run **Check integrity** on the task once.
   You can also schedule integrity checks in the task settings. The author saw Hyper
   Backup's integrity check pass against this guest on an earlier layout of the pool. Run
   your own on yours.

### 10b. Messages and traps

- **"No response from the destination server"** was a plain reachability error. In the
  author's case it was a mistyped IP address. Check the address and `hosts allow` first.
- **Empty module dropdown:** the module has `list = no`, or DSM's source address is not in
  `hosts allow` (section 9).
- **After changing the module password, use Re-authenticate** in the task. A task left on
  the old password made 50 failed login attempts overnight.
- **First-run "No such file" lines in the daemon log** mention names such as `Guard/cloud`
  or `seq_mapping.temp`. They are Hyper Backup probing for optional files on a first run.
  They are not failures.
- **An old task pointing at a rebuilt pool fails.** The daemon log shows
  `link_stat "<name>.hbk" ... No such file`, because the repository no longer exists.
  Create a new task. If the repository still exists somewhere else, relink to it instead.

> [!WARNING]
> **Deleting a Hyper Backup task can delete its repository on the destination.** This
> happened to the author on another backup target: 3.6 TB of backup data were gone and a
> full re-seed was needed. Do not delete a task just to "start fresh" while you still need
> its backups.

- **The pool comes up late.** After a guest power cycle or a NAS reboot, the pool is ready
  about 100 s after the guest boots, plus about 2.5 minutes for the controller re-attach
  ([03, Step 11](03-guest-storage-stack.md#step-11---enable-the-chain-and-test-a-full-reboot)).
  Do not schedule backups right after planned NAS reboots. While the pool is not mounted,
  the module's directory does not exist on the guest's root filesystem, so a backup that
  runs then should fail rather than write to the root disk. That is reasoned from the
  layout, not tested. Keep it that way: never create `/srv/hc680/backup` while the pool is
  unmounted.

### 10c. Throughput

How fast Hyper Backup can write depends on the guest kernel much more than on anything here.
On Debian's 6.12 kernel, the same stack managed about 9.5 MB/s for Hyper Backup alone,
during its fsync-heavy index phase. On 7.2.6, Hyper Backup wrote about 68 MB/s into the pool
with the drives about 22 % busy, so the pool was not the limit. With Hyper Backup and a
media push running together, the pool took 116 to 143 MB/s. Throughput then dropped once
dm-zoned's write buffer was full. Details and the kernel comparison are in
[05-operations-monitoring-performance.md](05-operations-monitoring-performance.md).

---

## 11. NFS remote folder in DSM File Station

This makes the pool's `media` share appear inside a DSM shared folder. File Station, and
DSM packages such as a media server, can then read it.

1. In DSM, create an **empty** folder inside an existing shared folder, for example
   `/volume1/media/pool`.
2. File Station › **Tools › Mount Remote Folder › NFS**.
3. Settings:

   | Field | Value |
   |---|---|
   | Server / folder | `<GUEST_IP>:/media` for NFS v4, or `<GUEST_IP>:/export/media` for v3 |
   | Mount to | the empty folder from step 1 |
   | NFS version | v4 (as built) |
   | Mount automatically on startup | ticked |

   **Why `/media` and not `/export/media`:** OMV's NFS v4 root is `/export`, so v4 paths
   are relative to it. The v3 path with v4 fails (section 6).

4. Check that the folder shows the share's content.

Because of `all_squash`, everything written through this mount is owned by `hcmedia` on
the guest, whichever DSM user wrote it.

**Known gap: DSM does not retry the mount.** At NAS boot, DSM tries to mount the remote
folder before the guest and its pool are up. The mount fails, and DSM does not try again.
After every NAS reboot, once the pool is up, mount the remote folder again from File
Station. The author does this by hand. A boot script on DSM that waits for the guest and then
mounts was considered but not built or tested.

**If a media server indexes the remote folder:** turn off any "empty trash automatically
after every scan" setting. In Plex, it is called *Empty trash automatically after every
scan*. Otherwise, a scan that runs while the mount is missing can drop library entries.

**Do not copy from the remote folder into the pool.** The remote folder **is** the pool.
Once media is on the pool, its path under the remote folder (for example
`/volume1/media/pool/<folder>`) is the **destination**, not a second copy of the source.
Using it as a source copies the share onto itself.

---

## 12. Pushing data from the DSM shell with rsync

For copies of hundreds of GB or more, use rsync from the DSM shell into the `hc680-media`
module. Do not use File Station or copy onto the NFS mount.

**Why:** the transfer is resumable, it can be checked with a dry run (section 13), and it
does not depend on DSM's NFS mount being present. That mount is the part that breaks at NAS
boot (section 11).

### 12a. Before you start

The password file is from section 9c. Check that no copy to this module is already running.
A job started in another SSH session does not appear in `jobs`:

```sh
ps -ef | grep '[r]sync'
```

**Why:** the author once started a copy a second time while the first one, started the
previous evening, was still running. Two identical `--append-verify` writers on the same
files did not corrupt anything, and the final dry run matched. But they doubled the reads on
the NAS and the writes into the pool. Both jobs also wrote into the same log file: the second
truncated it, the first kept writing at its old offset, and the result was hard to read. Stop
the extra job, and give every job its own log file.

### 12b. The copy

Run this on DSM as root. It **adds and resumes** files and never deletes anything on the
pool. Do not add `--delete` unless you mean it.

```sh
nohup rsync -rltD --partial --append-verify --no-perms --no-owner --no-group \
    --exclude='@eaDir' --exclude='#recycle' --exclude='.DS_Store' --exclude='Thumbs.db' \
    --stats --password-file=/root/.hc680-media.pw \
    /volume1/media/<folder>/ rsync://hcmedia@<GUEST_IP>/hc680-media/<folder>/ \
    > /volume1/<share>/media-sync-<folder>.log 2>&1 &
```

The trailing `/` on the source copies the folder's **contents** into `<folder>/` on the
pool. Putting the log inside a shared folder lets you read it from File Station too.

| Flag | Why |
|---|---|
| `-r -l -t -D` | Recursive, symlinks as symlinks, keep modification times, devices/specials. Kept times are what the next run and the dry run compare. |
| `--no-perms --no-owner --no-group` | The daemon writes as the module's user (`hcmedia`) and cannot set owners anyway. Owner and group come from the pool side (section 4). |
| `--partial` | Keep a partly transferred file when the copy is interrupted, so the next run can continue it. |
| `--append-verify` | Continue partial files by appending, and include the existing data in the file's checksum check. |
| `--exclude='@eaDir'`, `'#recycle'` | DSM's per-folder metadata/thumbnail directories and its recycle bin. |
| `--exclude='.DS_Store'`, `'Thumbs.db'` | Desktop clutter. |
| `--stats` | Summary at the end of the log. |

> [!NOTE]
> `--append` and `--append-verify` assume that files only grow or stay the same. rsync
> **skips** a file that needs updating if its copy on the pool is already as long as the
> source or longer. That is right for a one-way copy of media files. It is wrong for files
> that change in place. For those, leave out `--append-verify`.

To resume after an interruption, run the same command again. Before resuming a large copy,
the author ran a dry run (section 13) to see what was left. In one case it showed 435 of
864 entries still to send: 2.60 TB of 3.19 TB. So rsync had recognised the ~596 GB
already on the pool, and the resumed copy did not duplicate it.

### 12c. Following progress

```sh
tail -f /volume1/<share>/media-sync-<folder>.log      # on DSM; the --stats block appears at the end
```

On the guest, `df -h /srv/hc680` and the pool metrics from
[05-operations-monitoring-performance.md](05-operations-monitoring-performance.md) show the
other side. The copies the author ran were limited by the NAS side, not by the pool
(section 10c).

For an interactive run in the foreground, `--info=progress2` shows a single progress line.
Leave it out when the output goes to a log file.

---

## 13. Verifying a copy with a dry run

When the copy has finished, run the same transfer with `-n` (dry run), `-i` (itemize, one
line per difference) and `--stats`:

```sh
rsync -rltD --no-perms --no-owner --no-group -n -i --stats \
    --exclude='@eaDir' --exclude='#recycle' --exclude='.DS_Store' --exclude='Thumbs.db' \
    --password-file=/root/.hc680-media.pw \
    /volume1/media/<folder>/ rsync://hcmedia@<GUEST_IP>/hc680-media/<folder>/
```

`--partial` and `--append-verify` are left out on purpose. Without them, rsync reports any
file whose size **or** modification time differs. With `--append-verify`, a file that is
already as long on the pool would be skipped silently.

A complete copy itemizes no files, and the `--stats` block shows:

```
Number of created files: 0
Number of regular files transferred: 0
Total file size: <same number of bytes as the source>
```

The author's check after a 3.19 TB media copy listed 864 entries (667 files and 197
directories), with 0 created and 0 transferred. The total file size matched the source to
the byte.

This dry run compares size and modification time. It does not read file contents. A full
content comparison would add `-c`/`--checksum` and read every byte on both sides, which
for terabytes means many hours of reads on the NAS and the pool. The author did not run
that.

---

## 14. What healthy looks like

On the guest:

```sh
findmnt --mountpoint /srv/hc680                 # pool from /dev/mapper/hc680crypt
findmnt --mountpoint /export/media              # bind of /srv/hc680/media
systemctl is-active nfs-server smbd rsync       # active, active, active
systemctl --failed                              # 0 units
exportfs -v                                     # /export and /export/media, no "Failed to stat"
testparm -s 2>/dev/null | grep -A3 '^\[media\]' # path = /srv/hc680/media/
grep '^\[' /etc/rsyncd.conf                     # [hc680-backup] [hc680-media]
```

From DSM:

```sh
rsync rsync://<GUEST_IP>/                       # both modules listed
```

In DSM, the Hyper Backup task shows its last run as successful, and the remote folder shows
the media share.

---

## 15. Pitfalls at a glance

| Pitfall | What happens | What to do |
|---|---|---|
| Mount entry without the ordering options | systemd gives up on the late device after 90 s, and the `nofail` mount is never retried | Put the options in OMV's `opts` field (section 3) |
| Hand-written line inside OMV's fstab block | Overwritten, or duplicated, at the next deploy | Register the mount through OMV; keep one mount (section 3c) |
| `applyChanges` after an options change | fstab not redeployed | `omv-salt deploy run fstab` |
| fstab deploy while the container is closed | A failed salt state | Deploy only with the pool open and healthy |
| Old OMV objects after a rebuild | NFS fails at boot; the rsyncd deploy fails | Delete modules, shares, shared folders, then mount entries (section 3a) |
| Existing directory, OMV mode not applied | SMB login works, writes fail with `NT_STATUS_ACCESS_DENIED` | Set owner and mode yourself (section 4) |
| Service ids reused from another host | They collide with OMV's own accounts | Check with `getent` first (section 4) |
| NFS v4 with `/export/media` | Mount fails | v4 path is `/media` (section 6) |
| Renamed shared folder | SMB name changes; NFS bind stays at the old path, `exportfs: Failed to stat` | Delete and recreate the NFS share; unmount clients first (section 8) |
| `list = no` on the module | Hyper Backup dropdown empty | `list = yes` (section 9) |
| `hosts allow` set to DSM's UI address | DSM connects from another address and is refused | Allow the LAN, or read the real source from the log |
| Testing the module from the guest | Refused by `hosts allow` | Test from a LAN host, e.g. DSM (section 9c) |
| Password changed on the module | Hyper Backup keeps failing to log in | Re-authenticate in the task (section 10b) |
| Hyper Backup task deleted | Its repository can go with it | Do not delete tasks whose data you still need |
| NAS reboot | DSM's NFS remote folder is not mounted again | Mount it again by hand (section 11) |
| Two rsync pushes at once | Double load; mixed-up log | Check `ps` first; one log per job (section 12a) |
| Remote-folder path used as a copy source | The share is copied onto itself | Copy from the real DSM folders only (section 11) |

---

## Files and related pages

| File | What it is |
|---|---|
| [examples/fstab.example](../examples/fstab.example) | The OMV-generated fstab lines: pool mount with the ordering options, and the NFS bind mount |
| [systemd/zonedpool-mdassemble.service](../systemd/zonedpool-mdassemble.service), [systemd/zonedpool-cryptopen.service](../systemd/zonedpool-cryptopen.service) | The units the mount options refer to |

- Requirements and the unexplained NAS panic: [01-requirements-and-risks.md](01-requirements-and-risks.md)
- Getting the controller into the guest: [02-synology-controller-passthrough.md](02-synology-controller-passthrough.md)
- Building the pool and the boot chain: [03-guest-storage-stack.md](03-guest-storage-stack.md)
- Other approaches that were tried: [06-alternatives-and-lessons.md](06-alternatives-and-lessons.md)
- Related work by others: [07-prior-art.md](07-prior-art.md)

Next: [05-operations-monitoring-performance.md](05-operations-monitoring-performance.md) · Optional caching: [08-caching.md](08-caching.md)
