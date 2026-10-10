# Patches as prepared for upstream submission

The same fixes as the combined patches in `patches/`, split and formatted for the mailing lists:
`dm-zoned-reclaim/` (cover letter + 3, for dm-devel), `libahci-fbs/` (1, for linux-ide, after a real hot-plug test),
`dm-zoned-tools/` (1, by mail to the maintainer and dm-devel). Based on torvalds/linux master and dm-zoned-tools master of 2026-10-08.
`Signed-off-by` is added by the submitter at send time; AI assistance is disclosed with `Assisted-by`, as
`Documentation/process/coding-assistants.rst` requires.

## Status

| Series | Sent | Where |
|---|---|---|
| `dm-zoned-reclaim/` (0/3 + 3) | 2026-10-10 to dm-devel, the device-mapper maintainers, Hannes Reinecke, Damien Le Moal, LKML | [lore](https://lore.kernel.org/dm-devel/20261010105122.398-1-volvo.mail@gmail.com/), [patchwork](https://patchwork.kernel.org/series/1182929/) |
| `libahci-fbs/` | 2026-10-10 to linux-ide, Damien Le Moal, Niklas Cassel, LKML (after the hot-plug test passed the same day) | [lore](https://lore.kernel.org/linux-ide/20261010115727.401-1-volvo.mail@gmail.com/) |
| `dm-zoned-tools/` | 2026-10-10 to Damien Le Moal, dm-devel, Hannes Reinecke (by mail, as the project's README asks; prepared by `prepare-dmzadm-patch.sh`) | [lore](https://lore.kernel.org/dm-devel/20261010110553.379-1-volvo.mail@gmail.com/) |

The series was sent as prepared by `prepare-dm-zoned-series.sh` (apply on master, sign off, checkpatch, format).
