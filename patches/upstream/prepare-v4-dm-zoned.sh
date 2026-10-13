#!/bin/bash
# Prepare (and, with the argument "send", send) v4 of the dm-zoned series with the CURRENT git identity.
# v4 = after Damien Le Moal's review of v3: Fixes tag on patch 1, Reviewed-by tags (Hannes Reinecke on 1,
# Damien Le Moal on 1 and 2), patch 3 moved into dmz_schedule_reclaim() as he suggested; based on 7.3-rc7.
# No argument: prepare and show (nothing is sent).   "send": prepare again, then git send-email.
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/dm-zoned-reclaim-v4
W=${W:-$HOME/kernel-patches}
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v4: $NAME <$MAIL>"
P="v4-0001-dm-zoned-back-off-when-reclaim-finds-no-destinati.patch
v4-0002-dm-zoned-do-not-reclaim-a-random-zone-into-anothe.patch
v4-0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-re.patch"
mkdir -p "$W/v4in" && cd "$W"
for f in v4-0000-cover-letter.patch $P; do curl -fsSL -o "v4in/$f" "$B/$f"; done
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B dm-zoned-reclaim-v4 FETCH_HEAD
echo "=== base: $(git log --oneline -1)"
for f in $P; do git am -q -3 "../v4in/$f"; done
git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' HEAD~3
git rebase -q --signoff HEAD~3
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~3..HEAD | grep -E "^total:" || true; }
rm -rf ../out-v4-dm-zoned && mkdir -p ../out-v4-dm-zoned
git format-patch -q -v4 -o ../out-v4-dm-zoned HEAD~3
python3 - "$NAME <$MAIL>" ../v4in/v4-0000-cover-letter.patch ../out-v4-dm-zoned/v4-0000-cover-letter.patch <<'PY'
import sys
ident, src, dst = sys.argv[1:]
head, body = open(src).read().split("\n\n", 1)
head = "\n".join(("From: " + ident) if l.startswith("From: ") else l for l in head.split("\n"))
body = body.replace("illofspeed (3):", ident.split(" <")[0] + " (3):")
open(dst, "w").write(head + "\n\n" + body)
PY
cd ..
echo "=== ready (nothing sent yet):"; ls -1 out-v4-dm-zoned
echo "=== From / Signed-off-by lines (must all show $MAIL):"
grep -h -E "^(From|Signed-off-by): " out-v4-dm-zoned/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v4-dm-zoned/*.patch | grep -v -F "<$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $MAIL - do not send"; exit 1; fi
grep -h "^Subject:" out-v4-dm-zoned/*.patch
if [ "${1:-}" = send ]; then
  git send-email --to=dm-devel@lists.linux.dev \
    --cc=mpatocka@redhat.com --cc=snitzer@kernel.org --cc=agk@redhat.com --cc=bmarzins@redhat.com \
    --cc=dlemoal@kernel.org --cc=hare@suse.de --cc=linux-kernel@vger.kernel.org \
    --suppress-cc=all out-v4-dm-zoned/*.patch
else
  echo "Nothing sent. Read out-v4-dm-zoned/*.patch, then run this script again with the argument: send"
fi
