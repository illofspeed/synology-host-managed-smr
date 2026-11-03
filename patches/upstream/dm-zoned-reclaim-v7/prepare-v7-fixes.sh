#!/bin/bash
# dm-zoned v7 fix series ([PATCH v7 0/2]): prepare it with the CURRENT git identity, run the send gates and,
# with the argument "send", mail it. Run by the human submitter on home-pc WSL `ai`. This script adds the
# submitter's Signed-off-by because the submitter runs it; an AI must never run it for real, and the stored
# patches carry no Signed-off-by (Documentation/process/coding-assistants.rst).
#
#   bash prepare-v7-fixes.sh         prepare + gates; nothing is sent
#   bash prepare-v7-fixes.sh send    prepare + gates again, then git send-email after typing SEND
#
# Gates (patches/upstream/README.md in the public guide; implemented here since 2026-11-02):
#   1 tree + replies   send_gates.py (mainline, linux-dm, patchwork) + a human read of lore before sending
#   2 review stamp     SHA256SUMS verifies, and REVIEW-STAMP names this exact SHA256SUMS
#   3 evidence         EVIDENCE-rc1.md is stamped and names the tested kernel and source hash
#   4 all copies       what would be mailed equals the stamped package, and builds the tested source
#   5 24 h pacing      send_gates.py (patchwork) + the local stamp
#   6 one owner        OWNER file + a lock; refuses a second send
set -euo pipefail

PKG=$(cd "$(dirname "$0")/.." && pwd)
W=${W:-$HOME/kernel-patches}
TREE=${TREE:-$W/linux}
OUT=$W/out-v7-fixes
SENT=$W/.v7-fixes-sent
PKG_SENT=$PKG/.sent
BASE_TAG=v7.4-rc1
BASE_SHA=6628e7d4c6b25c8d18f1345e3a20d21829aae7e4
TESTED_SRC=b2714ccfc7efe11e607b3a159e7a040a519d4321d13078375273db7372f33df1
EXPECT_MAIL=${EXPECT_MAIL:-illofspeed@gmail.com}
ORIGIN=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
LORE='https://lore.kernel.org/dm-devel/?q=dm-zoned'
TO=dm-devel@lists.linux.dev
CC=(mpatocka@redhat.com snitzer@kernel.org agk@redhat.com bmarzins@redhat.com
    dlemoal@kernel.org hare@kernel.org hare@suse.de linux-kernel@vger.kernel.org)

die() { echo "!!! STOP: $* - nothing sent"; exit 1; }
gate() { echo "=== gate $*"; }

NAME=$(git config --global user.name || true); MAIL=$(git config --global user.email || true)
[ -n "$NAME" ] && [ -n "$MAIL" ] || die "set git user.name and user.email first"
[ "$MAIL" = "$EXPECT_MAIL" ] || die "git user.email is $MAIL, expected $EXPECT_MAIL"
echo "=== identity for v7: $NAME <$MAIL>"
command -v python3 >/dev/null || die "python3 missing"

mkdir -p "$W"
gate "6: one owning session"
exec 9>"$W/.v7-fixes.lock"
flock -n 9 || die "another prepare/send of v7 is running"
for s in "$SENT" "$PKG_SENT"; do
    if [ -e "$s" ]; then
        echo "!!! STOP: a send of v7 was already started: $(cat "$s")"
        echo "    Do not rerun. Read lore; if messages are missing, send only those with --in-reply-to."
        echo "    Remove $s by hand only if lore shows that nothing arrived."
        exit 1
    fi
done
grep -q '^Owning session: ' "$PKG/OWNER" || die "OWNER names no owning session"
cat "$PKG/OWNER"

gate "2: review stamp"
SUMS=$(sha256sum "$PKG/SHA256SUMS" | cut -d' ' -f1)
verify_pkg() {
    ( cd "$PKG" && sha256sum -c --quiet --strict SHA256SUMS ) || die "package files differ from SHA256SUMS"
    [ "$(sha256sum "$PKG/SHA256SUMS" | cut -d' ' -f1)" = "$SUMS" ] || die "SHA256SUMS changed during this run"
}
verify_pkg
grep -qx "sha256-of-SHA256SUMS: $SUMS" "$PKG/REVIEW-STAMP" || die "REVIEW-STAMP does not name this SHA256SUMS ($SUMS)"
grep -q '^review: ' "$PKG/REVIEW-STAMP" || die "REVIEW-STAMP names no review"
sed -n 's/^review: /  reviewed by: /p' "$PKG/REVIEW-STAMP"
echo "  SHA256SUMS: $SUMS (must equal the hash the preparing session reported)"
[ "$(cd "$PKG" && find fixes send -type f -not -name '*.pyc' | sort)" = "$(cd "$PKG" && sed -n 's/^[0-9a-f]\{64\}  \(fixes\/\|send\/\)/\1/p' SHA256SUMS | sort)" ] \
    || die "fixes/ or send/ holds files that SHA256SUMS does not list"
for f in fixes/0001-dm-zoned-back-off-when-reclaim-cannot-make-progress.patch \
         fixes/0002-dm-zoned-do-not-reclaim-a-random-zone-into-another-r.patch \
         cover-fixes.txt EVIDENCE-rc1.md OWNER send/prepare-v7-fixes.sh send/send_gates.py; do
    grep -q "  $f\$" "$PKG/SHA256SUMS" || die "$f is not in SHA256SUMS"
done

gate "3: evidence"
grep -q '^kernel: 7\.4\.0-rc1-dmzlab$' "$PKG/EVIDENCE-rc1.md" || die "evidence does not name the tested kernel"
grep -q "$TESTED_SRC" "$PKG/EVIDENCE-rc1.md" || die "evidence does not name the tested source hash"
[ "$(grep -c '^result:' "$PKG/EVIDENCE-rc1.md")" = 1 ] && grep -qx 'result: PASS' "$PKG/EVIDENCE-rc1.md" \
    || die "evidence does not end in one 'result: PASS' line"
for f in "$PKG"/fixes/*.patch "$PKG/cover-fixes.txt"; do
    grep -q 'Tested on 7\.4-rc1' "$f" || die "$f has no 'Tested on 7.4-rc1'"
    ! grep -q 'Tested on 7\.3-rc' "$f" || die "$f still has a 7.3-rc test paragraph"
done

gate "1 + 5: maintainer trees, replies, pacing"
python3 -I "$PKG/send/send_gates.py" --checked-file "$PKG/REPLIES-CHECKED" --own-mail "$MAIL" --sent-stamp "$SENT" \
    || die "send_gates.py stopped the send (see above)"

echo "=== preparing the mails on $BASE_TAG"
[ -d "$TREE/.git" ] || git clone -q --depth 1 --branch "$BASE_TAG" "$ORIGIN" "$TREE"
cd "$TREE"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "$TREE has uncommitted changes"
[ ! -d .git/rebase-apply ] && [ ! -d .git/rebase-merge ] || die "$TREE has a rebase or am in progress"
git fetch -q --depth=1 origin "refs/tags/$BASE_TAG:refs/tags/$BASE_TAG"
[ "$(git rev-parse "$BASE_TAG^{commit}")" = "$BASE_SHA" ] || die "$BASE_TAG is not $BASE_SHA"
git checkout -q -B dm-zoned-v7-fixes "$BASE_SHA"
git am -q "$PKG"/fixes/0001-*.patch "$PKG"/fixes/0002-*.patch
git rebase -q --exec 'git commit -q --amend --no-edit --reset-author' "$BASE_SHA"
git rebase -q --signoff "$BASE_SHA"
[ "$(git rev-list --count "$BASE_SHA..HEAD")" = 2 ] || die "expected exactly 2 commits on the base"

CP=$(./scripts/checkpatch.pl ${CHECKPATCH_ARGS:-} --git "$BASE_SHA..HEAD" 2>&1 || true)
[ "$(grep -c '^total: ' <<<"$CP")" = 2 ] || { echo "$CP"; die "checkpatch did not finish"; }
grep '^total: ' <<<"$CP"
if grep -q '^ERROR:' <<<"$CP"; then echo "$CP"; die "checkpatch reports errors"; fi
if grep '^WARNING:' <<<"$CP" | grep -v 'Unknown commit id'; then echo "    (read the warnings above before sending)"; fi

rm -rf "$OUT"
git format-patch -q -v7 --cover-letter --base="$BASE_SHA" -o "$OUT" "$BASE_SHA..HEAD"

gate "4: all copies"
verify_pkg
python3 -I "$PKG/send/send_gates.py" --all-copies --pkg "$PKG" --out "$OUT" --own-mail "$MAIL" --own-name "$NAME" \
        --tested-src "$TESTED_SRC" --tree "$TREE" \
    || die "the prepared mails differ from the stamped package"

MAILS=("$OUT"/v7-000[012]-*.patch)
[ "${#MAILS[@]}" = 3 ] || die "expected 3 mails in $OUT"
FROZEN=$(sha256sum "${MAILS[@]}")

echo "=== ready:"; ls -1 "$OUT"
grep -h '^Subject:' "${MAILS[@]}"
grep -h -E '^(From|Signed-off-by|Reviewed-by|Fixes|Cc): ' "${MAILS[1]}" "${MAILS[2]}" | sort | uniq -c
SE=(--from="$NAME <$MAIL>" --no-to --no-cc --no-bcc --to="$TO"); for c in "${CC[@]}"; do SE+=(--cc="$c"); done; SE+=(--suppress-cc=all)
DR=$(git send-email --dry-run "${SE[@]}" "${MAILS[@]}" 2>&1) || { echo "$DR"; die "git send-email --dry-run failed"; }
grep -E '^(To|Cc|From): ' <<<"$DR" | sort -u | cut -c1-110 || true

if [ "${1:-}" != send ]; then
    echo; echo "Nothing sent. Read $OUT/*.patch, above all the tool-use paragraph of the cover letter (it speaks for you)."
    echo "Then read $LORE in a browser, and run this script again with the argument: send"
    exit 0
fi

[ -t 0 ] && [ -t 1 ] || die "sending needs a human at a terminal"
echo; echo "Gate 1, human part: open $LORE in a browser and read everything newer than $(cat "$PKG/REPLIES-CHECKED")."
read -r -p "Nothing there changes these patches? Type lore-read to go on: " a </dev/tty
[ "$a" = lore-read ] || die "lore not confirmed"
read -r -p "Type SEND to mail ${#MAILS[@]} messages to $TO: " a </dev/tty
[ "$a" = SEND ] || die "not confirmed"
python3 -I "$PKG/send/send_gates.py" --checked-file "$PKG/REPLIES-CHECKED" --own-mail "$MAIL" --sent-stamp "$SENT" \
    || die "send_gates.py stopped the send while you were reading"
verify_pkg
[ "$(sha256sum "${MAILS[@]}")" = "$FROZEN" ] || die "the prepared mails changed after gate 4"

LOG=$W/v7-fixes-send-$(date -u +%Y%m%dT%H%M%SZ).log
STARTED="started $(date -u +%FT%TZ), log $LOG (may be partial)"
echo "$STARTED" > "$SENT"; echo "$STARTED" > "$PKG_SENT"
set +e
git send-email "${SE[@]}" "${MAILS[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
OK=$(grep -c 'Result: 250' "$LOG" || true)
echo "finished $(date -u +%FT%TZ), rc=$RC, results-250=$OK, log $LOG" | tee "$SENT" > "$PKG_SENT"
if [ "$RC" != 0 ] || [ "$OK" != 3 ]; then
    echo "!!! PARTIAL OR FAILED SEND: rc=$RC, $OK of 3 accepted. Do NOT rerun this script."
    echo "    Read $LOG and lore; send only what is missing, with --in-reply-to the cover letter."
    exit 1
fi
echo "=== sent: 3 messages, log $LOG. Tell the session that prepared this, so it records the patchwork series."
