#!/bin/bash
# Prepare v3 of the dm-zoned series with the CURRENT git identity (does NOT send anything).
# v3 = patch 2 reworked after Damien Le Moal's review; patches 1 and 3 as in v2.
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/dm-zoned-reclaim-v3
W=${W:-$HOME/kernel-patches}
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v3: $NAME <$MAIL>"
P="v3-0001-dm-zoned-back-off-when-reclaim-finds-no-destinati.patch
v3-0002-dm-zoned-do-not-reclaim-a-random-zone-into-anothe.patch
v3-0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-re.patch"
mkdir -p "$W/v3in" && cd "$W"
for f in v3-0000-cover-letter.patch $P; do curl -fsSL -o "v3in/$f" "$B/$f"; done
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B dm-zoned-reclaim-v3 FETCH_HEAD
for f in $P; do git am -q -3 "../v3in/$f"; done
git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' HEAD~3
git rebase -q --signoff HEAD~3
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~3..HEAD | grep -E "^total:" || true; }
rm -rf ../out-v3-dm-zoned && mkdir -p ../out-v3-dm-zoned
git format-patch -q -v3 -o ../out-v3-dm-zoned HEAD~3
python3 - "$NAME <$MAIL>" ../v3in/v3-0000-cover-letter.patch ../out-v3-dm-zoned/v3-0000-cover-letter.patch <<'PY'
import sys
ident, src, dst = sys.argv[1:]
head, body = open(src).read().split("\n\n", 1)
head = "\n".join(("From: " + ident) if l.startswith("From: ") else l for l in head.split("\n"))
open(dst, "w").write(head + "\n\n" + body)
PY
cd ..
echo "=== ready to send (nothing was sent):"; ls -1 out-v3-dm-zoned
echo "=== From / Signed-off-by lines (must all show $MAIL):"
grep -h -E "^(From|Signed-off-by): " out-v3-dm-zoned/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v3-dm-zoned/*.patch | grep -v -F "<$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $MAIL - do not send"; exit 1; fi
grep -h "^Subject:" out-v3-dm-zoned/*.patch
