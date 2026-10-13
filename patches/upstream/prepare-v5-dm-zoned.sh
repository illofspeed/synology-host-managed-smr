#!/bin/bash
# Prepare (and, with the argument "send", send) v5 of the dm-zoned series with the CURRENT git identity.
# v5 = v4 (patches 1-3 unchanged, Reviewed-by from Damien Le Moal on patch 3) + patch 4: no idle reclaim
# busy loop when no zone needs reclaim (Fixes 90a9b8693f1b). Based on mainline master (7.3-rc7 tested).
# No argument: prepare and show (nothing is sent).   "send": prepare again, then git send-email.
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/dm-zoned-reclaim-v5
W=${W:-$HOME/kernel-patches}
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v5: $NAME <$MAIL>"
P="v5-0001-dm-zoned-back-off-when-reclaim-finds-no-destinati.patch
v5-0002-dm-zoned-do-not-reclaim-a-random-zone-into-anothe.patch
v5-0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-re.patch
v5-0004-dm-zoned-do-not-busy-loop-idle-reclaim-when-no-zone.patch"
mkdir -p "$W/v5in" && cd "$W"
for f in v5-0000-cover-letter.patch $P; do curl -fsSL -o "v5in/$f" "$B/$f"; done
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B dm-zoned-reclaim-v5 FETCH_HEAD
echo "=== base: $(git log --oneline -1)"
for f in $P; do git am -q -3 "../v5in/$f"; done
git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' HEAD~4
git rebase -q --signoff HEAD~4
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~4..HEAD | grep -E "^total:" || true; }
rm -rf ../out-v5-dm-zoned && mkdir -p ../out-v5-dm-zoned
git format-patch -q -v5 -o ../out-v5-dm-zoned HEAD~4
python3 - "$NAME <$MAIL>" ../v5in/v5-0000-cover-letter.patch ../out-v5-dm-zoned/v5-0000-cover-letter.patch <<'PY'
import sys
ident, src, dst = sys.argv[1:]
head, body = open(src).read().split("\n\n", 1)
head = "\n".join(("From: " + ident) if l.startswith("From: ") else l for l in head.split("\n"))
if not head.startswith("From "):   # mbox separator line, as in git format-patch output
    head = "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n" + head
body = body.replace("illofspeed (4):", ident.split(" <")[0] + " (4):")
open(dst, "w").write(head + "\n\n" + body)
PY
cd ..
echo "=== ready (nothing sent yet):"; ls -1 out-v5-dm-zoned
echo "=== From / Signed-off-by lines (must all show $MAIL):"
grep -h -E "^(From|Signed-off-by): " out-v5-dm-zoned/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v5-dm-zoned/*.patch | grep -v -F "<$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $MAIL - do not send"; exit 1; fi
grep -h "^Subject:" out-v5-dm-zoned/*.patch
grep -q -F "$NAME (4):" out-v5-dm-zoned/v5-0000-cover-letter.patch || { echo "!!! cover letter shortlog not rewritten - do not send"; exit 1; }
if [ "${1:-}" = send ]; then
  git send-email --to=dm-devel@lists.linux.dev \
    --cc=mpatocka@redhat.com --cc=snitzer@kernel.org --cc=agk@redhat.com --cc=bmarzins@redhat.com \
    --cc=dlemoal@kernel.org --cc=hare@suse.de --cc=linux-kernel@vger.kernel.org \
    --suppress-cc=all out-v5-dm-zoned/*.patch
else
  echo "Nothing sent. Read out-v5-dm-zoned/*.patch, then run this script again with the argument: send"
fi
