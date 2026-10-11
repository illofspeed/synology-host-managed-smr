#!/bin/bash
# Plain-text replies to Damien Le Moal's review of "[PATCH v2 0/3] dm zoned: fix two idle reclaim problems" (2026-10-11).
# No argument: write the replies to ~/kernel-patches/replies-v2/ and show them.   "send": send them with git send-email.
set -euo pipefail
D=${W:-$HOME/kernel-patches}/replies-v2; mkdir -p "$D"
CC=(--cc=dm-devel@lists.linux.dev --cc=agk@redhat.com --cc=snitzer@kernel.org --cc=mpatocka@redhat.com
    --cc=bmarzins@redhat.com --cc=hare@suse.de --cc=linux-kernel@vger.kernel.org)
mk() { { echo "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001"; echo "Subject: $2"; echo; cat; } > "$D/$1"; }

mk 1.txt "Re: [PATCH v2 1/3] dm zoned: back off when reclaim finds no destination zone" <<'EOF'
Damien Le Moal wrote:
> Patch looks OK, but is "ilofspeed" your full name?

illofspeed is not my legal name, but it is the name I use for all my
public work (GitHub and this series), and I understood
Documentation/process/submitting-patches.rst ("using a known identity")
to allow that. If you need a legal name in the Signed-off-by, please let
me know and I will resend.

(Resent as plain text: my first reply had an HTML part and did not reach
the lists.)

illofspeed
EOF

mk 2.txt "Re: [PATCH v2 2/3] dm zoned: do not reclaim a random zone into another random zone" <<'EOF'
Damien Le Moal wrote:
>> +	 * Without a free sequential zone, moving a cache zone into a random
>> +	 * zone of the zoned device still frees cache space. Moving a random
>> +	 * zone into another random zone gains nothing, and when the target
>> +	 * is idle it repeats forever. Only fall back for cache zones.
>
> "fall back" to what? This comment is not clear.

To a random destination zone: the switch from DMZ_ALLOC_SEQ to
DMZ_ALLOC_RND just below. v3 rewords it:

	/*
	 * If no free sequential zone is available, a cache zone can still be
	 * moved into a free random zone of the zoned device, which frees cache
	 * space. Do not do this for a random zone: moving it into another
	 * random zone frees nothing and, on an idle target, repeats forever.
	 */

>> +	if (!szone && alloc_flags == DMZ_ALLOC_SEQ && dmz_nr_cache_zones(zmd) &&
>
> Long line. Please split after "DMZ_ALLOC_SEQ &&".
> Also, is the test for dmz_nr_cache_zones() needed? dmz_is_cache(dzone) will
> never be true if there are no cache zones.

You are right: DMZ_CACHE is only set on zones of the regular device, so
the test is redundant. Without it the condition fits on one line:

	if (!szone && alloc_flags == DMZ_ALLOC_SEQ && dmz_is_cache(dzone)) {

With this change the reproducer from the cover letter still shows 0 MB/s
on the idle target. I will send v3 once the Signed-off-by question on
1/3 is settled; patches 1 and 3 stay unchanged.

illofspeed
EOF

mk 3.txt "Re: [PATCH v2 3/3] dm zoned: keep polling for idle reclaim after a reclaim pass" <<'EOF'
Damien Le Moal wrote:
> Patch looks OK to me, but same comment as patch 1 about your SoB name. Please
> confirm.

Same answer as for 1/3: illofspeed is the name I use for all my public
work. If a legal name is required, I will resend.

(Resent as plain text: my first reply had an HTML part and did not reach
the lists.)

illofspeed
EOF

IRT=([1]="<8d1ee370-2785-438d-9c5b-8363584a23aa@kernel.org>" [2]="<d4adf5de-9d72-4977-b4c0-3e1f163872a1@kernel.org>"
     [3]="<bfbbb428-5a4e-4b61-8fe0-fd0c6c506c64@kernel.org>")
case "${1:-show}" in
  show) for i in 1 2 3; do echo "===== $D/$i.txt (in reply to ${IRT[$i]})"; cat "$D/$i.txt"; echo; done
        echo "Nothing sent. To send all three: run this script again with the argument: send";;
  send) for i in 1 2 3; do
          git send-email --to=dlemoal@kernel.org "${CC[@]}" --suppress-cc=all --in-reply-to="${IRT[$i]}" "$D/$i.txt"
        done;;
  *) echo "usage: $0 [show|send]"; exit 2;;
esac
