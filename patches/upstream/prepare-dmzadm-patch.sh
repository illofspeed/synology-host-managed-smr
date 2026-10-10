#!/bin/bash
# Prepare the dmzadm (dm-zoned-tools) patch for sending (does NOT send anything). Run in Linux/WSL as yourself,
# after prepare-dm-zoned-series.sh (same git identity). dm-zoned-tools takes patches by mail (README, CONTRIBUTING).
set -euo pipefail
U=https://raw.githubusercontent.com/illofspeed/synology-host-managed-smr/main/patches/upstream/dm-zoned-tools
P=0001-dmz-check-do-not-use-the-write-pointer-of-convention.patch
W=${W:-$HOME/kernel-patches}
git config user.name >/dev/null && git config user.email >/dev/null || { echo "set git user.name and user.email first"; exit 2; }
mkdir -p "$W/in" "$W/out-dmzadm" && cd "$W"
curl -fsSL -o "in/$P" "$U/$P"
[ -d dm-zoned-tools ] || git clone -q https://github.com/westerndigitalcorporation/dm-zoned-tools.git
cd dm-zoned-tools
git fetch -q origin master && git checkout -q -B dmz-check-conv-zones FETCH_HEAD
git am -3 "../in/$P"
git rebase -q --signoff HEAD~1
git notes add -f -m "The addresses in README.md are out of date (wdc.com, dm-devel@redhat.com),
hence this goes to dlemoal@kernel.org and dm-devel@lists.linux.dev.

Related kernel series (dm-zoned idle reclaim):
https://lore.kernel.org/dm-devel/20261010105122.398-1-volvo.mail@gmail.com/" HEAD
rm -f ../out-dmzadm/*.patch
git format-patch -q --notes --subject-prefix="PATCH dm-zoned-tools" -o ../out-dmzadm HEAD~1
echo "=== ready to send:"; ls -1 ../out-dmzadm
git log --format='%h %an <%ae> | %s' -1
grep -h "^Subject\|^Signed-off-by" ../out-dmzadm/*.patch
