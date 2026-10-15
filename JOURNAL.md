# Journal — synology-host-managed-smr

Newest first. Changes and validation for the public guide; private host operations remain
in their owning repositories.

## 2026-10-15 — codex — correct the dm-zoned idle-loop patch and guide

Changed: combined dm-zoned patch gains the idle no-work guard/backoff; guide updates distinguish patch variants, historical benchmarks, uncertain incidents and applied-then-reverted upstream status. Original lab logs and samplers are preserved with hashes.
Why: the published patch retained the idle CPU loop; its periodic-kick advice could also trigger that loop on stock modules. The October 13 draft had factual and activation gaps identified by review.
State: parent source-equivalence check passes: corrected combined patch and prepared v6 produce byte-identical reclaim source. Local shell syntax, prose whitespace, evidence checksums and changed-page internal links pass. Unified-patch context whitespace and raw log bytes are preserved exactly. Strong Codex publication reviews completed; all findings corrected and a final read-only Codex check found no remaining blockers. No fresh compilation or host testing.
State: final review also found a CPU-sampler formula error (steal counted, IRQ omitted); CPU percentages are withdrawn from the guide table, and raw evidence is retained with this limitation. The 95-second 7.2.6 drain claim is withdrawn because the old sampler logged the wrong zone field. v6's retained evidence shows 18 requests / 30 seconds and fully free random zones by the +90-second sample.
Next: upstream mail remains held until 7.4-rc1, the bugfix/enhancement split and the documented send gates; v6 is prepared, not sent.
Refs: docs/evidence/dm-zoned-idle-2026-10-13/README.md; patches/upstream/README.md. Parent Codex integrated the correction; advisory Codex research and independent source-equivalence review supplied evidence, checked again by parent.
