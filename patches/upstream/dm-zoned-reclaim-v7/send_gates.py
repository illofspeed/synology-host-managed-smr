#!/usr/bin/env python3
"""Send gates for dm-zoned v7 that a script can decide; prepare-v7-fixes.sh calls this. Everything fails closed.

Default mode, gates 1 and 5:
  - mainline and linux-dm still hold the dm-zoned sources the patches were made and tested on;
  - patchwork shows no reply or dm-zoned series newer than the last human check (REPLIES-CHECKED);
  - at least 24 h since the submitter's newest posting on dm-devel.
--all-copies, gate 4: the prepared mails equal the stamped package and build the tested source.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from urllib.parse import quote

PATCHWORK = "https://patchwork.kernel.org/api"
SERIES = [1182929, 1182940, 1183039, 1183040, 1183414, 1183416, 1184722, 1184850]   # every posted dm-zoned series
SOURCES = {   # drivers/md files in 7.3-rc7 and 7.4-rc1 (identical); the patches apply to and were tested on these
    "dm-zoned-reclaim.c": "84dcc60bcbb3c424b653b282c1c0c9e3411354381f65225ab502c7901bfcad6b",
    "dm-zoned-target.c": "eedd543d91ad27cb789f4f255043b8246aa452507a459db8419d59811d6918d2",
    "dm-zoned-metadata.c": "802c6e788477aa6d141de773bf318a92c107598c7812d77eb05194ee56c95082",
    "dm-zoned.h": "5bb5b3a7b74ec48603e98c6e01a9ab5474ba5674862d4593cf7ec6071298fbe9",
}
LINUX_DM = "https://git.kernel.org/pub/scm/linux/kernel/git/device-mapper/linux-dm.git"
MAINLINE_RAW = "https://raw.githubusercontent.com/torvalds/linux/master/drivers/md/"
FORBIDDEN = re.compile(r"Assisted-by|noreply|TESTING-PENDING|\*\*\* (SUBJECT|BLURB)|@@[A-Z_0-9]+@@")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "dm-zoned-v7-send-gates"})
    with urllib.request.urlopen(req, timeout=40) as r:
        return r.read(), r.headers


def api(path):
    """All pages of a patchwork list, or one object."""
    url, items = PATCHWORK + path, []
    while url:
        body, headers = fetch(url)
        data = json.loads(body)
        if not isinstance(data, list):
            return data
        items += data
        m = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", "") or "")
        url = m.group(1) if m else None
    return items


def when(s):
    return dt.datetime.fromisoformat(s.replace("Z", "")).replace(tzinfo=None)


def stamp(raw):
    """REPLIES-CHECKED, written with date -u +%FT%TZ. Patchwork dates are naive UTC."""
    d = dt.datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
    if d.tzinfo is None:
        raise ValueError("REPLIES-CHECKED needs a zone; write it with date -u +%FT%TZ")
    d = d.astimezone(dt.timezone.utc).replace(tzinfo=None)
    if d > dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(minutes=5):
        raise ValueError("REPLIES-CHECKED is in the future")
    return d


def check_trees():
    """True if the sources are unchanged in mainline and in every current linux-dm branch."""
    ok = True
    for name, want in SOURCES.items():
        try:
            got = hashlib.sha256(fetch(MAINLINE_RAW + name)[0]).hexdigest()
        except (urllib.error.URLError, OSError) as e:
            print(f"STOP mainline {name}: cannot read it ({e})")
            ok = False
            continue
        if got != want:
            print(f"STOP mainline master changed {name}: read the change; rebase and re-test if it matters")
            ok = False
    try:
        heads = subprocess.run(["git", "ls-remote", "--heads", LINUX_DM], check=True, capture_output=True,
                               text=True, timeout=120).stdout
    except (subprocess.SubprocessError, OSError) as e:
        print(f"STOP linux-dm: cannot list the branches ({e})")
        return False
    # Branches for released kernels may differ; only 7.4 onwards and for-next can hold new dm-zoned work.
    current = {b for b in re.findall(r"refs/heads/(dm-7\.\d+)$", heads, re.M) if int(b.split(".")[1]) >= 4}
    if "dm-7.4" not in current:
        print("STOP linux-dm: no dm-7.4 branch, the tree layout changed; check it in a browser")
        return False
    branches = ["for-next"] + sorted(current)
    for branch in branches:
        for name, want in SOURCES.items():
            url = f"{LINUX_DM}/plain/drivers/md/{name}?h={branch}"
            try:
                got = hashlib.sha256(fetch(url)[0]).hexdigest()
            except (urllib.error.URLError, OSError) as e:
                print(f"STOP linux-dm {branch} {name}: cannot read it ({e}); check it in a browser")
                ok = False
                continue
            if got != want:
                print(f"STOP linux-dm {branch} changed {name} (or cgit refused the read): {url}")
                ok = False
    print(f"  trees: mainline and linux-dm {', '.join(branches)} checked")
    return ok


def check_replies(checked_at, own_mail):
    """True if nobody wrote since the last human check, and return the newest own posting."""
    ok, newest_own = True, None
    new_series = api(f"/series/?project=dm-devel&since={checked_at.isoformat()}&per_page=100&order=-date")
    ids = list(SERIES)
    for s in new_series:
        text = " ".join([s.get("name") or ""] + [p.get("name") or "" for p in s.get("patches", [])]).lower()
        if "zoned" in text or "dmz" in text:
            ids.append(s["id"])
            who = (s.get("submitter") or {}).get("email", "")
            if who != own_mail:
                print(f"STOP new dm-zoned series {s['id']} from {who}, {s['date']}: {s.get('name')}")
                ok = False
    for s in api(f"/series/?project=dm-devel&submitter={quote(own_mail)}&per_page=100&order=-date"):
        d = when(s["date"])
        newest_own = max(newest_own, d) if newest_own else d
        if (s.get("version") or 0) >= 7 and "zoned" in (s.get("name") or "").lower():
            print(f"STOP your v{s['version']} is already on patchwork: series {s['id']}, {s['date']}")
            ok = False
    for sid in sorted(set(ids)):
        s = api(f"/series/{sid}/")
        if (s.get("submitter") or {}).get("email") == own_mail:
            d = when(s["date"])
            newest_own = max(newest_own, d) if newest_own else d
        items = [("patches", p["id"], p["name"]) for p in s["patches"]]
        if s.get("cover_letter"):
            items.append(("covers", s["cover_letter"]["id"], s["cover_letter"]["name"]))
        for kind, item, name in items:
            for c in api(f"/{kind}/{item}/comments/"):
                if when(c["date"]) > checked_at and c["submitter"].get("email") != own_mail:
                    print(f"STOP new reply {c['date']} from {c['submitter'].get('name')} on {name}: "
                          f"https://patchwork.kernel.org/project/dm-devel/{'cover' if kind == 'covers' else 'patch'}/{item}/")
                    ok = False
    print(f"  replies: {len(set(ids))} series checked, newer than {checked_at.isoformat()}")
    return ok, newest_own


def check_pacing(newest_own, sent_stamp):
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    times = [newest_own] if newest_own else []
    if sent_stamp and os.path.exists(sent_stamp):
        times.append(dt.datetime.fromtimestamp(os.path.getmtime(sent_stamp), dt.timezone.utc).replace(tzinfo=None))
    if not times:
        print("STOP pacing: found no earlier posting, which cannot be right")
        return False
    age = now - max(times)
    if age < dt.timedelta(hours=24):
        print(f"STOP pacing: the last posting was {age} ago, wait for 24 h")
        return False
    print(f"  pacing: last posting {max(times).isoformat()}, {age.days} days ago")
    return True


def body(text):
    """A format-patch mail without what legitimately differs: mbox and author headers, blob ids, sign-off, git version."""
    head, _, rest = text.partition("\n\n")
    subject = re.search(r"^Subject: (.*(?:\n .*)*)", head, re.M).group(1)
    rest = rest.rpartition("\n-- \n")[0]
    rest = re.sub(r"^Signed-off-by: .*\n", "", rest, flags=re.M)
    rest = re.sub(r"^index [0-9a-f]+\.\.[0-9a-f]+", "index", rest, flags=re.M)
    return subject + "\n\n" + rest


def all_copies(a):
    ok = True
    def bad(msg):
        nonlocal ok
        print("STOP " + msg)
        ok = False
    stored = sorted(os.listdir(os.path.join(a.pkg, "fixes")))
    mails = sorted(f for f in os.listdir(a.out) if f.endswith(".patch"))
    allowed = ("From ", "From:", "Date:", "Subject:", "Message-ID:", "In-Reply-To:", "References:",
               "MIME-Version:", "Content-Type:", "Content-Transfer-Encoding:", " ")
    if len(stored) != 2 or len(mails) != 3 or not mails[0].startswith("v7-0000-cover-letter"):
        bad(f"unexpected files: stored {stored}, mails {mails}")
        return False
    for s, m in zip(stored, mails[1:]):
        one = open(os.path.join(a.pkg, "fixes", s)).read()
        two = open(os.path.join(a.out, m)).read()
        if body(one) != body(two):
            bad(f"{m} differs from fixes/{s}")
        sob = re.findall(r"^Signed-off-by: (.*)$", two, re.M)
        if sob != [f"{a.own_name} <{a.own_mail}>"]:
            bad(f"{m}: Signed-off-by lines are {sob}")
        if re.search(r"^Signed-off-by:", one, re.M):
            bad(f"stored fixes/{s} carries a Signed-off-by")
    who = "^From: " + re.escape(f"{a.own_name} <{a.own_mail}>") + "$"
    for m in mails:
        two = open(os.path.join(a.out, m)).read()
        if not re.search(who, two, re.M):
            bad(f"{m}: From is not the submitter")
        for line in two.partition("\n\n")[0].split("\n"):
            if not line.startswith(allowed):
                bad(f"{m}: unexpected mail header {line!r} (user git config?)")
        if not re.search(r"\n-- \n\d[\w.-]*\n*$", two):
            bad(f"{m}: the mail does not end in the plain git version signature (format.signature?)")
        hit = FORBIDDEN.search(two)
        if hit and m != mails[0]:
            bad(f"{m}: forbidden text {hit.group(0)!r}")
    cover = open(os.path.join(a.pkg, "cover-fixes.txt")).read()
    subject, _, text = cover.partition("\n\n")
    subject, text = subject.split("Subject: ", 1)[1].strip(), text.rstrip("\n")
    gen = open(os.path.join(a.out, mails[0])).read()
    if "[PATCH v7 0/2] *** SUBJECT HERE ***" not in gen or "*** BLURB HERE ***" not in gen:
        bad("the generated cover letter has no placeholders to fill")
    gen = gen.replace("[PATCH v7 0/2] *** SUBJECT HERE ***", subject, 1).replace("*** BLURB HERE ***", text, 1)
    # The cover letter may name the Assisted-by removal it follows; no mail may carry the tag itself.
    hit = re.search(r"\*\*\* |@@[A-Z_0-9]+@@|TESTING-PENDING|noreply|^Assisted-by:", gen, re.M)
    if hit:
        bad(f"cover letter: forbidden text {hit.group(0)!r}")
    if "base-commit: " not in gen:
        bad("cover letter has no base-commit trailer")
    open(os.path.join(a.out, mails[0]), "w").write(gen)
    src = hashlib.sha256(open(os.path.join(a.tree, "drivers/md/dm-zoned-reclaim.c"), "rb").read()).hexdigest()
    if src != a.tested_src:
        bad(f"the prepared tree builds dm-zoned-reclaim.c {src}, the tested one is {a.tested_src}")
    if ok:
        print("  all copies: mails = stamped package, sources = tested sources")
    return ok


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--all-copies", action="store_true")
    p.add_argument("--checked-file")
    p.add_argument("--sent-stamp")
    p.add_argument("--own-mail", required=True)
    p.add_argument("--own-name")
    p.add_argument("--pkg")
    p.add_argument("--out")
    p.add_argument("--tested-src")
    p.add_argument("--tree")
    a = p.parse_args()
    if a.all_copies:
        return 0 if all_copies(a) else 1
    try:
        checked_at = stamp(open(a.checked_file).read())
        trees = check_trees()
        replies, newest_own = check_replies(checked_at, a.own_mail)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        print(f"STOP cannot complete the check ({e}); this gate fails closed")
        return 1
    pacing = check_pacing(newest_own, a.sent_stamp)
    return 0 if trees and replies and pacing else 1


if __name__ == "__main__":
    sys.exit(main())
