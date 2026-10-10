#!/bin/bash
# Prepare the libahci FBS patch for sending (does NOT send anything). Run in Linux/WSL as yourself, after
# prepare-dm-zoned-series.sh (same git identity; reuses its kernel tree in ~/kernel-patches/linux).
set -euo pipefail
U=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/libahci-fbs
P=0001-ata-libahci-re-enable-FBS-after-error-handling-on-a-.patch
W=${W:-$HOME/kernel-patches}
git config user.name >/dev/null && git config user.email >/dev/null || { echo "set git user.name and user.email first"; exit 2; }
mkdir -p "$W/in" "$W/out-libahci" && cd "$W"
curl -fsSL -o "in/$P" "$U/$P"
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B libahci-fbs FETCH_HEAD
git am -3 "../in/$P"
git rebase -q --signoff HEAD~1
git notes add -f -m "The controller is passed through (VFIO) to a KVM guest; the tested kernel is the
guest's. The two earlier occurrences without the patch were on ata8 and ata10 of the
same controller; this test was on ata7." HEAD
echo "=== checkpatch (\"Unknown commit id\" for the Fixes: tag is expected in a shallow clone)"
./scripts/checkpatch.pl --git HEAD~1..HEAD || true
rm -f ../out-libahci/*.patch
git format-patch -q --notes -o ../out-libahci HEAD~1
echo "=== recipients (get_maintainer)"; ./scripts/get_maintainer.pl --norolestats ../out-libahci/*.patch 2>/dev/null || true
echo "=== ready to send:"; ls -1 ../out-libahci
git log --format='%h %an <%ae> | %s' -1
grep -h "^Signed-off-by" ../out-libahci/*.patch
