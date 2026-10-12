# Patches as prepared for upstream submission

The same fixes as the combined patches in `patches/` (which keep the original 7.2.6 out-of-tree form, the versions
tested on the reference system: the libahci copy still has an info print that v4 dropped, and the dm-zoned copy keeps
the v1 condition with the redundant `dmz_nr_cache_zones()` test and the v1 comments; the dmzadm copy is identical),
split and formatted for the mailing lists:
`dm-zoned-reclaim/` (cover letter + 3, for dm-devel; v1/v2) and `dm-zoned-reclaim-v3/` (under review),
`libahci-fbs/` (1, for linux-ide; v1-v3) and `libahci-fbs-v4/` (applied to libata for-7.4 as commit 21d333ab),
`dm-zoned-tools/` (1, by mail to the maintainer and dm-devel; v3 resent with the same code). Based on torvalds/linux
master and dm-zoned-tools master of 2026-10-08.
`Signed-off-by` is added by the submitter at send time; AI assistance is disclosed with `Assisted-by`, as
`Documentation/process/coding-assistants.rst` requires.

## Status

| Series | Sent / status | Where |
|---|---|---|
| `dm-zoned-reclaim/` (0/3 + 3) | 2026-10-10 to dm-devel, the device-mapper maintainers, Hannes Reinecke, Damien Le Moal, LKML | [lore](https://lore.kernel.org/dm-devel/?q=s%3A%22dm+zoned%3A+fix+two+idle+reclaim+problems%22), [patchwork](https://patchwork.kernel.org/series/1182929/) |
| `dm-zoned-reclaim-v3/` | **sent 2026-10-11**, under review on dm-devel: after Damien Le Moal's review of v2 (patches 1 and 3 looked OK; patch 2: clearer comment, redundant test dropped; author's full name); lab: reproducer 0 MB/s, pool checksums OK | [patchwork](https://patchwork.kernel.org/series/1183414/) |
| `libahci-fbs-v4/` | **APPLIED 2026-10-12** by Niklas Cassel to libata/linux.git `for-7.4` as commit [21d333ab](https://git.kernel.org/libata/linux/c/21d333ab) (v4 after his review of v3: no info print, testing details below the `---`; that below-the-line text, the v4 changelog and hot-plug test report, is not in the stored copy: `prepare-v4-libahci.sh` adds it as a git note and `format-patch --notes` emits it) | will be in Linux 7.4; on 7.4+ no out-of-tree libahci is needed |
| `libahci-fbs/`, `dm-zoned-tools/` v3 | **sent 2026-10-11**: no code changes, author's full name instead of the handle (one identity across all fixes). dmzadm v3: under review; libahci v3: superseded by v4 (applied, row above) | dmzadm: [patchwork](https://patchwork.kernel.org/series/1183416/); libahci: linux-ide (no patchwork) |
| `libahci-fbs/` | 2026-10-10 to linux-ide, Damien Le Moal, Niklas Cassel, LKML (after the hot-plug test passed the same day) | [lore](https://lore.kernel.org/linux-ide/?q=s%3A%22re-enable+FBS+after+error+handling%22) |
| `dm-zoned-tools/` | 2026-10-10 to Damien Le Moal, dm-devel, Hannes Reinecke (by mail, as the project's README asks; prepared by `prepare-dmzadm-patch.sh`) | [lore](https://lore.kernel.org/dm-devel/?q=s%3A%22dmz%3A+check%3A+do+not+use+the+write+pointer%22) |

All three were resent as **v2** on 2026-10-10 from the submitter's new address (no code changes); the subject
searches below find both versions. Links point to a subject search in the list archives. In these copies the author address is the GitHub no-reply
address (the mails themselves went out from the submitter's own address). The stored copies also keep the GitHub
handle in the author lines and in the v3 cover letter, whose "Signed-off-by stays illofspeed" paragraph
`prepare-v3-dm-zoned.sh` replaces at send time with the full-name wording; the sent mails therefore differ from
these copies in author name and in that paragraph. The prepare scripts (v1 through v4) are kept for
reproduction; each later version was prepared in the submitter's own tree with the current git identity.

The series was sent as prepared by `prepare-dm-zoned-series.sh` (apply on master, sign off, checkpatch, format).
