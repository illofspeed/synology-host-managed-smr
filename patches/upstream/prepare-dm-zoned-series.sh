#!/bin/bash
# Prepare the dm-zoned series for sending (does NOT send anything). Run in Linux/WSL as yourself, after
#   git config --global user.name  <your name>      and      git config --global user.email <your email>
# It downloads the patches, makes a shallow kernel clone, applies them, adds YOUR Signed-off-by (only the human
# submitter may add it), runs checkpatch and writes the final files to ~/kernel-patches/out-dm-zoned/.
set -euo pipefail
B=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/dm-zoned-reclaim
W=${W:-$HOME/kernel-patches}
P="0001-dm-zoned-back-off-when-reclaim-finds-no-destination-.patch
0002-dm-zoned-do-not-reclaim-a-random-zone-into-another-r.patch
0003-dm-zoned-keep-polling-for-idle-reclaim-after-a-recla.patch"
git config user.name >/dev/null && git config user.email >/dev/null || { echo "set git user.name and user.email first"; exit 2; }
mkdir -p "$W/in" "$W/out-dm-zoned" && cd "$W"
for f in 0000-cover-letter.patch $P; do curl -fsSL -o "in/$f" "$B/$f"; done
[ -d linux ] || git clone --depth 200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch -q --depth 200 origin master && git checkout -q -B dm-zoned-reclaim FETCH_HEAD
git am -3 ../in/000[1-3]-*.patch
git rebase -q --signoff HEAD~3
echo "=== checkpatch (\"Unknown commit id\" for the Fixes: tags is expected in a shallow clone)"
./scripts/checkpatch.pl --git HEAD~3..HEAD || true
rm -f ../out-dm-zoned/*.patch
git format-patch -q -o ../out-dm-zoned HEAD~3
cp ../in/0000-cover-letter.patch ../out-dm-zoned/
echo "=== ready to send:"; ls -1 ../out-dm-zoned
git log --format='%h %an <%ae> | %s' HEAD~3..HEAD
grep -h "^Signed-off-by" ../out-dm-zoned/000[1-3]*.patch | sort -u
