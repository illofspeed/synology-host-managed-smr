# Patches as prepared for upstream submission

The same fixes as the combined patches in `patches/`, split and formatted for the mailing lists:
`dm-zoned-reclaim/` (cover letter + 3, for dm-devel), `libahci-fbs/` (1, for linux-ide, after a real hot-plug test),
`dm-zoned-tools/` (1, by mail to the maintainer and dm-devel). Based on torvalds/linux master and dm-zoned-tools master of 2026-10-08.
`Signed-off-by` is added by the submitter at send time; AI assistance is disclosed with `Assisted-by`, as
`Documentation/process/coding-assistants.rst` requires.

## Status

| Series | Sent | Where |
|---|---|---|
| `dm-zoned-reclaim/` (0/3 + 3) | 2026-10-10 to dm-devel, the device-mapper maintainers, Hannes Reinecke, Damien Le Moal, LKML | [lore](https://lore.kernel.org/dm-devel/?q=s%3A%22dm+zoned%3A+fix+two+idle+reclaim+problems%22), [patchwork](https://patchwork.kernel.org/series/1182929/) |
| `dm-zoned-reclaim-v3/` | **sent 2026-10-11** after Damien Le Moal's review of v2 (patch 2: clearer comment, redundant test dropped; author's full name); lab: reproducer 0 MB/s, pool checksums OK | [patchwork](https://patchwork.kernel.org/series/1183414/) |
| `libahci-fbs-v4/` | **APPLIED 2026-10-12** by Niklas Cassel to libata/linux.git `for-7.4` as commit [21d333ab](https://git.kernel.org/libata/linux/c/21d333ab) (v4 after his review of v3: no info print, testing details below the `---`) | will be in Linux 7.4; on 7.4+ no out-of-tree libahci is needed |
| `libahci-fbs/`, `dm-zoned-tools/` v3 | **sent 2026-10-11**: no code changes, author's full name instead of the handle (one identity across all fixes) | dmzadm: [patchwork](https://patchwork.kernel.org/series/1183416/); libahci: linux-ide (no patchwork) |
| `libahci-fbs/` | 2026-10-10 to linux-ide, Damien Le Moal, Niklas Cassel, LKML (after the hot-plug test passed the same day) | [lore](https://lore.kernel.org/linux-ide/?q=s%3A%22re-enable+FBS+after+error+handling%22) |
| `dm-zoned-tools/` | 2026-10-10 to Damien Le Moal, dm-devel, Hannes Reinecke (by mail, as the project's README asks; prepared by `prepare-dmzadm-patch.sh`) | [lore](https://lore.kernel.org/dm-devel/?q=s%3A%22dmz%3A+check%3A+do+not+use+the+write+pointer%22) |

All three were resent as **v2** on 2026-10-10 from the submitter's new address (no code changes); the subject
searches below find both versions. Links point to a subject search in the list archives. In these copies the author address is the GitHub no-reply
address (the mails themselves went out from the submitter's own address); the prepare scripts are kept for
reproduction, a v2 would be prepared in the submitter's own tree.

The series was sent as prepared by `prepare-dm-zoned-series.sh` (apply on master, sign off, checkpatch, format).
