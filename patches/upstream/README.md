# Patches as prepared for upstream submission

The combined `patches/dm-zoned-reclaim.patch` contains v5 patches 1–4 with
v6’s corrected error-path comment; applying it gives the same source as v6.
It applies to the identical reclaim source in 7.2.6/7.2.10. The reference
deployment is a separate 7.2.10 in-tree v3 + zonenas-0004 variant, not this
exact combined patch. The libahci copy retains the info print dropped in
v4; the dmzadm copy has the same code as its submitted fix.

Historical mail series are retained unchanged: `dm-zoned-reclaim/` (v1/v2),
`dm-zoned-reclaim-v3/` (accepted, then replaced), `dm-zoned-reclaim-v4/`
(applied, then reverted), `dm-zoned-reclaim-v5/` (sent), and
`dm-zoned-reclaim-v6/` (**prepared, not sent**). The old covers describe
what was known when prepared, including superseded in-tree status. They
are historical artifacts, not current send instructions. libahci v4 was
applied to libata for-7.4; dmzadm v3 was under review at the October 13 handover.

**Sending remains on hold:** wait until 7.4-rc1, split bugfixes (Fixes and
Cc: stable) from the polling enhancement, and require maintainer-tree and
unanswered-reply checks, a SHA-256 review stamp, evidence file, all-copies
check, 24-hour pacing and a single owning session. These gates are proposed,
not implemented by the old SHA-only prepare script. The owner sends mail;
publishing this guide does not authorize or perform a kernel submission.

`Signed-off-by` is added by the submitter at send time; AI assistance is disclosed with `Assisted-by`, as
`Documentation/process/coding-assistants.rst` requires.

## Status

Checked 2026-10-15: linux-dm `dm-7.4` and `for-next` both point to
`334714e4bdf8868c17a7650a7502ba1c90a8721f`; their reclaim source lacks the busy-loop
correction. [Evidence](../../docs/evidence/dm-zoned-idle-2026-10-13/README.md).

| Series | Sent / status | Where |
|---|---|---|
| `dm-zoned-reclaim/` (0/3 + 3) | 2026-10-10 to dm-devel, the device-mapper maintainers, Hannes Reinecke, Damien Le Moal, LKML | [patchwork](https://patchwork.kernel.org/series/1182929/) |
| `dm-zoned-reclaim-v3/` | **ACCEPTED**: all three patches marked accepted in patchwork by 2026-10-13 (delegate: Mikulas Patocka); in dm-7.4 they were replaced by v4 on 2026-10-13 (row below). Hannes Reinecke: `Reviewed-by` on patch 1 (given on v1; the code is unchanged in v3, reply in `replies/`). Sent 2026-10-11 after Damien Le Moal's review of v2 (patches 1 and 3 looked OK; patch 2: clearer comment, redundant test dropped; author's full name); lab: reproducer 0 MB/s, pool checksums OK | [patchwork](https://patchwork.kernel.org/series/1183414/) |
| `dm-zoned-reclaim-v6/` | **prepared 2026-10-13, NOT SENT; sending held pending the split and gates above** (owner) after Damien Le Moal asked on v5 4/4 to fold that patch into patch 1 ("This is undoing what patch 1 does"): patch 1 now backs off on -ENOSPC and -EBUSY and reclaims on idle only when a zone holds data (subject "dm zoned: back off when reclaim cannot make progress", both Fixes tags, Reviewed-by tags dropped because it changed); patches 2-3 retain the earlier v4 code, subsequently reverted from dm-7.4. Final code identical to v5 apart from one comment. Tested on 7.3-rc7 with exactly this code: idle md RAID5 of three emulated members 18 SCSI commands in 30 s vs 5,804,292 with stock; the old sampler CPU percentage is not a valid kernel-CPU measurement (see evidence); all random zones free by the +90-second sample after a 2 GiB burst; scsi_debug reproducer 0 MB/s. Commit messages also state that libata completes TEST UNIT READY in software (the cost of the loop was CPU time). The historical `prepare-v6-dm-zoned.sh` checks file hashes only; it does not satisfy the required send gates and must not be used to send this unsplit series. | |
| `dm-zoned-reclaim-v5/` | **SENT 2026-10-13** 16:55 CEST ([patchwork series 1184850](https://patchwork.kernel.org/series/1184850/)): v4 patches 1-3 + a new patch 4 that stops an idle reclaim busy loop present since 90a9b8693f1b (made recurrent across idle periods by patch 3): on 7.3-rc7 idle stock 181,195 / v4 187,707 / v5 under 1 SCSI command/s. Its cover letter said v3 was in dm-7.4; v4 had already replaced it there at 15:36 CEST. Damien Le Moal asked to fold patch 4 into patch 1 (v6, row above). | [patchwork](https://patchwork.kernel.org/series/1184850/) |
| `dm-zoned-reclaim-v4/` | **APPLIED, THEN REVERTED 2026-10-13** by Mikulas Patocka in linux-dm `dm-7.4` / `for-next` (acce1b6ac, 60427628f, ac82aa060, replacing v3; checked 2026-10-13). Sent 2026-10-13 ([patchwork series 1184722](https://patchwork.kernel.org/series/1184722/)) after Damien Le Moal's review of v3: Fixes tag on patch 1, Reviewed-by from Hannes Reinecke (patch 1) and Damien Le Moal (patches 1-2), patch 3 moved into `dmz_schedule_reclaim()` as he suggested (with `queue_delayed_work()`, after an independent review found that `mod_delayed_work()` there could keep postponing needed reclaim). Tested on 7.3-rc7 in the lab VM: reproducer 500-660 MB/s stock vs 0 MB/s; lab pool checksums OK; idle reclaim after a write burst within 2 min without a reclaim message. The fix for an older idle busy loop (present in mainline since 2020, `90a9b8693f1b`: an idle target with nothing to reclaim requeues the reclaim work at once and issues TEST UNIT READY without pause) followed as v5 patch 4, folded into patch 1 in v6 (rows above). | [patchwork](https://patchwork.kernel.org/series/1184722/) |
| `libahci-fbs-v4/` | **APPLIED 2026-10-12** by Niklas Cassel to libata/linux.git `for-7.4` as commit [23eab9e8](https://git.kernel.org/libata/linux/c/23eab9e8) (first applied as 21d333ab; re-applied 2026-10-15 with Damien Le Moal's `Reviewed-by`, code unchanged; v4 after his review of v3: no info print, testing details below the `---`; that below-the-line text, the v4 changelog and hot-plug test report, is not in the stored copy: `prepare-v4-libahci.sh` adds it as a git note and `format-patch --notes` emits it) | queued for Linux 7.4; verify the released kernel includes this commit before omitting the out-of-tree fix |
| `libahci-fbs/`, `dm-zoned-tools/` v3 | **sent 2026-10-11**: no code changes, author's full name instead of the handle (one identity across all fixes). dmzadm v3: under review; libahci v3: superseded by v4 (applied, row above) | dmzadm: [patchwork](https://patchwork.kernel.org/series/1183416/); libahci: linux-ide (no patchwork) |
| `libahci-fbs/` | 2026-10-10 to linux-ide, Damien Le Moal, Niklas Cassel, LKML (after the hot-plug test passed the same day) | linux-ide (no patchwork); applied version: [23eab9e8](https://git.kernel.org/libata/linux/c/23eab9e8) |
| `dm-zoned-tools/` | 2026-10-10 to Damien Le Moal, dm-devel, Hannes Reinecke (by mail, as the project's README asks; prepared by `prepare-dmzadm-patch.sh`) | [patchwork](https://patchwork.kernel.org/series/1183416/) |

All three were resent as **v2** on 2026-10-10 from the submitter's new address (no code changes); the subject
searches below find both versions. Links point to patchwork where it exists (linux-ide has none) or to the applied commit. In these copies the author address is the GitHub no-reply
address (the mails themselves went out from the submitter's own address). The stored copies also keep the GitHub
handle in the author lines and in the v3 cover letter, whose "Signed-off-by stays illofspeed" paragraph
`prepare-v3-dm-zoned.sh` replaces at send time with the full-name wording; the sent mails therefore differ from
these copies in author name and in that paragraph. The prepare scripts (v1 through v6) are kept for
reproduction; each later version was prepared in the submitter's own tree with the current git identity.

The series was sent as prepared by `prepare-dm-zoned-series.sh` (apply on master, sign off, checkpatch, format).
