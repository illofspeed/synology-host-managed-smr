#!/bin/bash
# Prepare v2 of all three upstream submissions with the CURRENT git identity (does NOT send anything).
# v2 = the v1 patches unchanged; only the author / Signed-off-by address changes.
# Run in Linux/WSL after: git config --global user.email <new address>   (user.name stays)
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream
W=${W:-$HOME/kernel-patches}
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v2: $NAME <$MAIL>"
NOTE="v2: no code changes. The only change is my author address: v1 went out on
2026-10-10 from my previous address. Please apply this version instead of v1."
DZ="0001-dm-zoned-back-off-when-reclaim-finds-no-destination-.patch
0002-dm-zoned-do-not-reclaim-a-random-zone-into-another-r.patch
0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-recla.patch"
mkdir -p "$W/v2in" && cd "$W"
for f in 0000-cover-letter.patch $DZ; do curl -fsSL -o "v2in/$f" "$B/dm-zoned-reclaim/$f"; done
curl -fsSL -o v2in/dmzadm.patch "$B/dm-zoned-tools/0001-dmz-check-do-not-use-the-write-pointer-of-convention.patch"
curl -fsSL -o v2in/libahci.patch "$B/libahci-fbs/0001-ata-libahci-re-enable-FBS-after-error-handling-on-a-.patch"

reauthor() {  # last $1 commits: author := current identity, then add its Signed-off-by
  git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' "HEAD~$1"
  git rebase -q --signoff "HEAD~$1"
}
fresh() { rm -rf "$1" && mkdir -p "$1"; }

echo "=== 1/3 dm-zoned series (kernel tree)"
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B dm-zoned-reclaim-v2 FETCH_HEAD
for f in $DZ; do git am -q -3 "../v2in/$f"; done
reauthor 3
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~3..HEAD | grep -E "^total:" || true; }
fresh ../out-v2-dm-zoned
git format-patch -q -v2 -o ../out-v2-dm-zoned HEAD~3
python3 - "$NAME <$MAIL>" "$NOTE" ../v2in/0000-cover-letter.patch ../out-v2-dm-zoned/v2-0000-cover-letter.patch <<'PY'
import sys
ident, note, src, dst = sys.argv[1:]
head, body = open(src).read().split("\n\n", 1)
out = []
for l in head.split("\n"):
    if l.startswith("From: "): l = "From: " + ident
    if l.startswith("Subject: [PATCH 0/3]"): l = l.replace("[PATCH 0/3]", "[PATCH v2 0/3]", 1)
    out.append(l)
open(dst, "w").write("\n".join(out) + "\n\n" + note + "\n\n" + body)
PY

echo "=== 2/3 libahci (same kernel tree)"
git checkout -q -B libahci-fbs-v2 FETCH_HEAD
git am -q -3 ../v2in/libahci.patch
reauthor 1
git notes add -f -m "$NOTE

The controller is passed through (VFIO) to a KVM guest; the tested kernel is the
guest's. The two earlier occurrences without the patch were on ata8 and ata10 of the
same controller; this test was on ata7." HEAD
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~1..HEAD | grep -E "^total:" || true; }
fresh ../out-v2-libahci
git format-patch -q -v2 --notes -o ../out-v2-libahci HEAD~1
cd ..

echo "=== 3/3 dmzadm (dm-zoned-tools)"
[ -d dm-zoned-tools ] || git clone -q https://github.com/westerndigitalcorporation/dm-zoned-tools.git
cd dm-zoned-tools
git fetch -q origin master && git checkout -q -B dmz-check-conv-zones-v2 FETCH_HEAD
git am -q -3 ../v2in/dmzadm.patch
reauthor 1
git notes add -f -m "$NOTE

The addresses in README.md are out of date (wdc.com, dm-devel@redhat.com),
hence this goes to dlemoal@kernel.org and dm-devel@lists.linux.dev." HEAD
fresh ../out-v2-dmzadm
git format-patch -q -v2 --notes --subject-prefix="PATCH dm-zoned-tools" -o ../out-v2-dmzadm HEAD~1
cd ..

echo "=== ready to send (nothing was sent):"
ls -1 out-v2-dm-zoned out-v2-libahci out-v2-dmzadm
echo "=== From / Signed-off-by lines (must all show $MAIL):"
grep -h -E "^(From|Signed-off-by): " out-v2-*/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v2-*/*.patch | grep -v -F "<$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $MAIL - do not send"; exit 1; fi
grep -h "^Subject:" out-v2-*/*.patch
