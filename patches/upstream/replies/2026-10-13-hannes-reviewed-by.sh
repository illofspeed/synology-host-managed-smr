#!/bin/bash
# Plain-text reply to Hannes Reinecke's Reviewed-by on "[PATCH 1/3] dm zoned: back off when reclaim finds no
# destination zone" (v1, reviewed 2026-10-13). Patch 1 is unchanged in v3 (code identical), and patchwork shows
# the v3 series as accepted; the reply lets the maintainer carry the tag over.
# No argument: write the reply to ~/kernel-patches/replies-hannes/ and show it.   "send": send it with git send-email.
# The sign-off name is taken from `git config user.name` (your kernel identity).
set -euo pipefail
D=${W:-$HOME/kernel-patches}/replies-hannes; mkdir -p "$D"
NAME=$(git config user.name); [ -n "$NAME" ] || { echo "git config user.name is empty"; exit 2; }
CC=(--cc=mpatocka@redhat.com --cc=dm-devel@lists.linux.dev --cc=dlemoal@kernel.org --cc=agk@redhat.com
    --cc=snitzer@kernel.org --cc=bmarzins@redhat.com --cc=linux-kernel@vger.kernel.org)
IRT="<b2a6b9f6-53a8-4250-aae6-a0837f0f598d@suse.de>"

{ echo "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001"
  echo "Subject: Re: [PATCH 1/3] dm zoned: back off when reclaim finds no destination zone"
  echo
  cat <<'EOF'
Hannes Reinecke wrote:
> Reviewed-by: Hannes Reinecke <hare@kernel.org>

Thank you, Hannes.

Mikulas: this patch is unchanged in v3 (only the author name and address
changed), which patchwork shows as accepted:
https://lore.kernel.org/dm-devel/20261011175450.952-2-illofspeed@gmail.com/
In case it is not too late, Hannes's Reviewed-by applies to it as well.

EOF
  echo "$NAME"
} > "$D/1.txt"

case "${1:-show}" in
  show) echo "===== $D/1.txt (in reply to $IRT)"; cat "$D/1.txt"; echo
        echo "Nothing sent. To send: run this script again with the argument: send";;
  send) git send-email --to=hare@suse.de "${CC[@]}" --suppress-cc=all --in-reply-to="$IRT" "$D/1.txt";;
  *) echo "usage: $0 [show|send]"; exit 2;;
esac
