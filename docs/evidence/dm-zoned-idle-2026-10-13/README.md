# dm-zoned idle-loop lab evidence — 2026-10-13

Archived on 2026-10-15 from the original lab-session scratch files. These are historical
captures, not a new test run or evidence of the current production host state. The files
are unmodified; `sha256sum -c SHA256SUMS` checks the preserved copies. Timestamps are
retained as recorded; their timezone was not recorded in the log headers.

- [7.2.6 comparison](dmz-726-test.log): stock, earlier guide patch, corrected guide patch
  (v5 patches 1–4 combined). It records the running kernel and each loaded module's
  `srcversion`, then a 30-second idle measurement after 60 seconds of settling.
- [7.3-rc7 v5 comparison](dmz-v5-test.log): stock, v4 and v5, with module identities.
- [7.3-rc7 v6 comparison](dmz-v6-test.log): stock and prepared v6, including the raw
  request delta. The corrected idle sample is **18 requests in 30 seconds, or 0.6/s**;
  the log's integer quotient prints zero. The first two logs store only that quotient,
  so their zeros mean **less than one request/s**, not proven zero requests.
- [Original 7.2.6 sampler](sampler-726.sh.txt) and [v6 sampler](sampler-v6.sh.txt) preserve
  the measurement method. These are archived text, **not installation/run instructions**:
  they swap modules and write to a disposable lab pool with hard-coded device names.
  The standalone v5 sampler was not preserved here; its log remains historical evidence.

Rates are totals across three emulated members, obtained from SCSI-layer
`iorequest_cnt`, not physical ATA commands. **The logs mislabel their CPU percentage:** both preserved samplers
add system + softirq + steal ticks, omitting IRQ ticks, and divide by aggregate CPU ticks
with integer rounding. This is a flawed proxy, not a valid kernel-CPU percentage. Raw
ticks were not logged, so corrected percentages cannot be recovered; the standalone
v5 sampler is unavailable here. The guide therefore omits these percentages. libata completes
TEST UNIT READY in software for SATA disks. The counters alone do not identify opcodes.

The 7.2.6 and v5 samplers accidentally selected `0/0 cache` on their three single-device
targets. Those lines cannot prove a buffer drain. The previously published draft's
**95-second 7.2.6 drain claim is withdrawn**. The v6 sampler selects `random`: following
a 2 GiB burst, all three members return to 6/6 free by the +90-second sample. This is a
sample boundary, not an exact completion timestamp. Its separate random-to-random
reproducer records zero MB/s in each ten-second sample after the fill/drain phase.

## Patch identities and source checks — 2026-10-15

The current combined patch differs from the tested 7.2.6 guide-new code only in v6's
corrected error-path comment. The comment does not assert that `-ENOSPC` proves no I/O
failed. The entire resulting source is byte-identical to prepared v6 patches 1–3 applied
sequentially. This was independently checked in memory and then with GNU `patch`,
`--fuzz=0`, and a byte comparison in a temporary directory. All hunks matched without
fuzz; v6's line numbers applied with the expected +2-line offset to the cached baseline.
No compilation or fresh runtime test was performed on October 15.

| Artifact | SHA-256 |
|---|---|
| Cached reclaim source labelled 7.2.6 and 7.2.10 (identical bytes) | `b46d62bf97043e8a03d047faf29f68a3da67e049ef776c9db981ecf0d940d04d` |
| Corrected `patches/dm-zoned-reclaim.patch` | `0e277ed5fe9471cb23cb4cbcea03bb0b313d71b1c35811e95d91c6a1f681badb` |
| Result from combined patch or sequential v6 | `e02b36fed27034d1eb331c2611de0fde21577903bf4c5490100a80496c1e9bc3` |
| v6 patch 1 | `dc76679215d6483413a0e8b0b6e3597e03e7c3b5058363175d0fa7a2d55bce6f` |
| v6 patch 2 | `412dbbafc8eb54a13fe54fee07d9781450b4b03d96c65f25707480ee06ae8a22` |
| v6 patch 3 | `cf374f5cde294b814a3e1a8bda9ada3c4823474ce6c2170979ed921f16457217` |

The cached files were named `g726/reclaim-v7.2.6.c` and `g726/reclaim-v7.2.10.c` in the
original lab scratch directory. Their byte equivalence was checked; their release-tag
provenance was not independently revalidated against signed upstream tags in this pass.
Source equivalence does not make modules built for different kernels interchangeable.
The logs' `srcversion` values are observed module identifiers, not binary SHA-256 hashes.

A fresh read of linux-dm `dm-7.4` and `for-next` on 2026-10-15 found both at
`334714e4bdf8868c17a7650a7502ba1c90a8721f`. The reclaim source there still tests total
rather than used zones and immediately reschedules on the idle no-work path: the
busy-loop correction is absent. Its source SHA-256 is
`84dcc60bcbb3c424b653b282c1c0c9e3411354381f65225ab502c7901bfcad6b`.
This records that date's tree, not a guarantee about later releases. See the
[submission history](../../../patches/upstream/README.md#status) for the distinction
between previously applied/reverted v4 and prepared, unsent v6.
