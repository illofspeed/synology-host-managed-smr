# Journal — synology-host-managed-smr

Newest first. Changes and validation for the public guide; private host operations remain
in their owning repositories.

## 2026-10-17 — claude — libahci FBS fix: new upstream commit ID

Changed: every reference to libata commit 21d333ab now names 23eab9e8 (7 files); the upstream status row records the re-apply.
Why: Niklas Cassel re-applied the patch to libata for-7.4 on 2026-10-15 to add Damien Le Moal's Reviewed-by. Verified on git.kernel.org:
23eab9e8 is in for-7.4 with the same subject, Fixes tag and Reviewed-by; the code is unchanged.
Also corrected (found by the review of an STH reply, 2026-10-17):
- `block/blk-zoned.c` is NOT byte-identical in 7.1.8 and 7.2: stable v7.1.8 vs v7.2.6 differ in 5 hunks, all in zone write plug
  workqueue setup/teardown (alloc once, WQ_PERCPU, drain instead of destroy), none in the write path. Wording now "barely changed"
  and "an unlikely explanation" in README, docs 01, 03, 05, 06, 07.
- The fixed combined patch was published on 2026-10-15 (e22a5a9; 48b27e3 has no -EBUSY back-off), so the affected-copies cutoff
  is "obtained before October 15", not "earlier on October 13" (README, docs 03, 05, 09).
- README and doc 01 now say both NAS crashes followed a start or reset of the guest carrying the 9235 (the 2026-09-19 one
  coincided with a watchdog reset), matching doc 01's incident detail.
Second review round (Codex 20261017T083907Z-review-6dStWY + three Claude refuters, all fix-first, accepted):
- docs/07 also carried the blk-zoned claim (now fixed there too); README tree label and doc 09 section 4.2a now date the
  public fix to e22a5a9 (2026-10-15 18:37 UTC); cutoff text names that commit; doc 09 gives the grep check for the patch
  file and the srcversion check for the running module.
- libahci: 23eab9e8 is paired with its re-apply date (2026-10-15) in docs 07 and 09; the out-of-tree patch header says
  "queued" instead of "merged into Linux 7.4" / "Not needed on 7.4+".
- Crash wording: "coincided with" instead of "followed" (the 2026-09-19 order is not established).
- Privacy: the five lore.kernel.org search links (the archives show the sender address) are replaced by patchwork links,
  the applied libata commit, or plain subjects.
State: uncommitted, waiting for the owner's OK to commit and push (public repo, no-reply identity).

## 2026-10-15 — codex — correct the dm-zoned idle-loop patch and guide

Changed: combined dm-zoned patch gains the idle no-work guard/backoff; guide updates distinguish patch variants, historical benchmarks, uncertain incidents and applied-then-reverted upstream status. Original lab logs and samplers are preserved with hashes.
Why: the published patch retained the idle CPU loop; its periodic-kick advice could also trigger that loop on stock modules. The October 13 draft had factual and activation gaps identified by review.
State: parent source-equivalence check passes: corrected combined patch and prepared v6 produce byte-identical reclaim source. Local shell syntax, prose whitespace, evidence checksums and changed-page internal links pass. Unified-patch context whitespace and raw log bytes are preserved exactly. Strong Codex publication reviews completed; all findings corrected and a final read-only Codex check found no remaining blockers. No fresh compilation or host testing.
State: final review also found a CPU-sampler formula error (steal counted, IRQ omitted); CPU percentages are withdrawn from the guide table, and raw evidence is retained with this limitation. The 95-second 7.2.6 drain claim is withdrawn because the old sampler logged the wrong zone field. v6's retained evidence shows 18 requests / 30 seconds and fully free random zones by the +90-second sample.
Next: upstream mail remains held until 7.4-rc1, the bugfix/enhancement split and the documented send gates; v6 is prepared, not sent.
Refs: docs/evidence/dm-zoned-idle-2026-10-13/README.md; patches/upstream/README.md. Parent Codex integrated the correction; advisory Codex research and independent source-equivalence review supplied evidence, checked again by parent.
