#!/bin/bash
# Prepare (and, with the argument "send", send) v6 of the dm-zoned series with the CURRENT git identity.
# v6 = v5 with patch 4 folded into patch 1 (Damien Le Moal's request); patches 2-3 have the code that is in
# dm-7.4. Final code identical to v5. Based on mainline master (7.3-rc7 tested).
# No argument: prepare and show (nothing is sent).   "send": prepare again, then git send-email.
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/dm-zoned-reclaim-v6
W=${W:-$HOME/kernel-patches}
H=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/dm-zoned-reclaim-v6   # the reviewed files next to this script
NAME=$(git config user.name || true); MAIL=$(git config user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || { echo "set git user.name and user.email first"; exit 2; }
echo "=== identity for v6: $NAME <$MAIL>"
P="v6-0001-dm-zoned-back-off-when-reclaim-cannot-make-progre.patch
v6-0002-dm-zoned-do-not-reclaim-a-random-zone-into-anothe.patch
v6-0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-re.patch"
mkdir -p "$W/v6in"
cd "$W"
for f in v6-0000-cover-letter.patch $P; do
  if [ -f "$H/$f" ]; then cp "$H/$f" "v6in/$f"; else curl -fsSL -o "v6in/$f" "$B/$f"; fi
done
( cd v6in && sha256sum -c --quiet - ) <<SUMS || { echo "!!! patch files differ from the reviewed ones (git pull, or wait 5 min for GitHub) - nothing sent"; exit 1; }
ca24ff731a5dbe938293e196ee2c70f17510d58960344f9541fecda5dcff8906  v6-0000-cover-letter.patch
dc76679215d6483413a0e8b0b6e3597e03e7c3b5058363175d0fa7a2d55bce6f  v6-0001-dm-zoned-back-off-when-reclaim-cannot-make-progre.patch
412dbbafc8eb54a13fe54fee07d9781450b4b03d96c65f25707480ee06ae8a22  v6-0002-dm-zoned-do-not-reclaim-a-random-zone-into-anothe.patch
cf374f5cde294b814a3e1a8bda9ada3c4823474ce6c2170979ed921f16457217  v6-0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-re.patch
SUMS
echo "=== patch files match the reviewed sha256 sums"
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master
git checkout -q -B dm-zoned-reclaim-v6 FETCH_HEAD
echo "=== base: $(git log --oneline -1)"
for f in $P; do git am -q -3 "../v6in/$f"; done
git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' HEAD~3
git rebase -q --signoff HEAD~3
[ -x scripts/checkpatch.pl ] && { ./scripts/checkpatch.pl --git HEAD~3..HEAD | grep -E "^total:" || true; }
rm -rf ../out-v6-dm-zoned
mkdir -p ../out-v6-dm-zoned
git format-patch -q -v6 -o ../out-v6-dm-zoned HEAD~3
python3 - "$NAME <$MAIL>" ../v6in/v6-0000-cover-letter.patch ../out-v6-dm-zoned/v6-0000-cover-letter.patch <<'PY'
import sys
ident, src, dst = sys.argv[1:]
head, body = open(src).read().split("\n\n", 1)
head = "\n".join(("From: " + ident) if l.startswith("From: ") else l for l in head.split("\n"))
if not head.startswith("From "):   # mbox separator line, as in git format-patch output
    head = "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n" + head
body = body.replace("illofspeed (3):", ident.split(" <")[0] + " (3):")
open(dst, "w").write(head + "\n\n" + body)
PY
cd ..
echo "=== ready (nothing sent yet):"; ls -1 out-v6-dm-zoned
echo "=== From / Signed-off-by lines (must all show $MAIL):"
grep -h -E "^(From|Signed-off-by): " out-v6-dm-zoned/*.patch | sort | uniq -c
if grep -h -E "^(From|Signed-off-by): " out-v6-dm-zoned/*.patch | grep -v -F "<$MAIL>" >/dev/null; then
  echo "!!! some From/Signed-off-by lines do not use $MAIL - do not send"; exit 1; fi
grep -h "^Subject:" out-v6-dm-zoned/*.patch
grep -q -F "$NAME (3):" out-v6-dm-zoned/v6-0000-cover-letter.patch || { echo "!!! cover letter shortlog not rewritten - do not send"; exit 1; }
if [ "${1:-}" = send ]; then
  git send-email --to=dm-devel@lists.linux.dev \
    --cc=mpatocka@redhat.com --cc=snitzer@kernel.org --cc=agk@redhat.com --cc=bmarzins@redhat.com \
    --cc=dlemoal@kernel.org --cc=hare@suse.de --cc=linux-kernel@vger.kernel.org \
    --suppress-cc=all out-v6-dm-zoned/*.patch
else
  echo "Nothing sent. Read out-v6-dm-zoned/*.patch, then run this script again with the argument: send"
fi
