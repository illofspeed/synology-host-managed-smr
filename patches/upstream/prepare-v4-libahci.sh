#!/bin/bash
# Prepare v4 of the libahci FBS patch with the CURRENT git identity (does NOT send anything).
# v4 = Niklas Cassel's review of v3: the info print is dropped and the testing details moved below the "---".
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/libahci-fbs-v4
P=0001-ata-libahci-re-enable-FBS-after-error-handling-on-a-.patch
W=${W:-$HOME/kernel-patches}
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v4: $NAME <$MAIL>"
mkdir -p "$W/v4in" && cd "$W"
curl -fsSL -o "v4in/$P" "$B/$P"
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B libahci-fbs-v4 FETCH_HEAD
git am -q -3 "../v4in/$P"
git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' HEAD~1
git rebase -q --signoff HEAD~1
git notes add -f -m "Changes in v4 (Niklas Cassel):
- dropped the ata_port_info() print; ahci_enable_fbs() already logs
  \"FBS is enabled\"
- moved the testing details out of the commit message
Changes in v3: author name only. Changes in v2: author address only.

Tested with the patch built as an out-of-tree libahci module for 7.2.6
(the stock ahci module binds to it, symbol CRCs unchanged) on the
88SE9235 + 88SM9705 setup from the commit message, which is passed
through (VFIO) to a KVM guest. Hot-plugging a drive into a free port of
the multiplier logged \"FBS is disabled\", \"softreset failed (device not
ready)\" and a PMP hardreset, then \"FBS is enabled\" from
ahci_enable_fbs(). Afterwards two other drives behind the same
multiplier read 259 + 259 MB/s in parallel (O_DIRECT, 4 MiB blocks),
against 268 MB/s for one drive alone, so their commands overlap again.
The two earlier occurrences without the patch were on ata8 and ata10 of
the same controller; this test was on ata7." HEAD
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~1..HEAD | grep -E "^total:" || true; }
rm -rf ../out-v4-libahci && mkdir -p ../out-v4-libahci
git format-patch -q -v4 --notes -o ../out-v4-libahci HEAD~1
cd ..
echo "=== ready to send (nothing was sent):"; ls -1 out-v4-libahci
echo "=== From / Signed-off-by lines (must all show $NAME <$MAIL>):"
grep -h -E "^(From|Signed-off-by): " out-v4-libahci/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v4-libahci/*.patch | grep -v -F "$NAME <$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $NAME <$MAIL> - do not send"; exit 1; fi
grep -h "^Subject:" out-v4-libahci/*.patch; echo "ata_port_info lines in the diff (must be 0): $(grep -c "^+.*ata_port_info" out-v4-libahci/*.patch || true)"
