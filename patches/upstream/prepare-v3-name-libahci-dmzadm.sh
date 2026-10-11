#!/bin/bash
# Prepare v3 of the libahci and dmzadm patches with the CURRENT git identity (does NOT send anything).
# v3 = the v2 code unchanged; only the author name in From/Signed-off-by changes (handle -> full name).
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream
W=${W:-$HOME/kernel-patches}
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v3: $NAME <$MAIL>"
NOTE="v3: no code changes. From and Signed-off-by now carry my full name
instead of the GitHub handle \"illofspeed\" used for v2 (same author)."
mkdir -p "$W/v3in" && cd "$W"
curl -fsSL -o v3in/libahci.patch "$B/libahci-fbs/0001-ata-libahci-re-enable-FBS-after-error-handling-on-a-.patch"
curl -fsSL -o v3in/dmzadm.patch "$B/dm-zoned-tools/0001-dmz-check-do-not-use-the-write-pointer-of-convention.patch"
reauthor() { git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' "HEAD~$1"; git rebase -q --signoff "HEAD~$1"; }

echo "=== 1/2 libahci (kernel tree)"
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B libahci-fbs-v3 FETCH_HEAD
git am -q -3 ../v3in/libahci.patch
reauthor 1
git notes add -f -m "$NOTE

The controller is passed through (VFIO) to a KVM guest; the tested kernel is the
guest's. The two earlier occurrences without the patch were on ata8 and ata10 of the
same controller; this test was on ata7." HEAD
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~1..HEAD | grep -E "^total:" || true; }
rm -rf ../out-v3-libahci && mkdir -p ../out-v3-libahci
git format-patch -q -v3 --notes -o ../out-v3-libahci HEAD~1
cd ..

echo "=== 2/2 dmzadm (dm-zoned-tools)"
[ -d dm-zoned-tools ] || git clone -q https://github.com/westerndigitalcorporation/dm-zoned-tools.git
cd dm-zoned-tools
git fetch -q origin master && git checkout -q -B dmz-check-conv-zones-v3 FETCH_HEAD
git am -q -3 ../v3in/dmzadm.patch
reauthor 1
git notes add -f -m "$NOTE

The addresses in README.md are out of date (wdc.com, dm-devel@redhat.com),
hence this goes to dlemoal@kernel.org and dm-devel@lists.linux.dev." HEAD
rm -rf ../out-v3-dmzadm && mkdir -p ../out-v3-dmzadm
git format-patch -q -v3 --notes --subject-prefix="PATCH dm-zoned-tools" -o ../out-v3-dmzadm HEAD~1
cd ..

echo "=== ready to send (nothing was sent):"; ls -1 out-v3-libahci out-v3-dmzadm
echo "=== From / Signed-off-by lines (must all show $NAME <$MAIL>):"
grep -h -E "^(From|Signed-off-by): " out-v3-libahci/*.patch out-v3-dmzadm/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v3-libahci/*.patch out-v3-dmzadm/*.patch | grep -v -F "$NAME <$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $NAME <$MAIL> - do not send"; exit 1; fi
grep -h "^Subject:" out-v3-libahci/*.patch out-v3-dmzadm/*.patch
