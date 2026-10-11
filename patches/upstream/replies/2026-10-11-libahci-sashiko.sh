#!/bin/bash
# Plain-text note under "[PATCH v3] ata: libahci: re-enable FBS after error handling on a port multiplier"
# answering the automated Sashiko review (PxFBS.EN written while PxCMD.FRE is set).
# No argument: write and show the reply.   "send": send it with git send-email.
set -euo pipefail
D=${W:-$HOME/kernel-patches}/replies-libahci; mkdir -p "$D"
IRT="<20261011180236.735-1-illofspeed@gmail.com>"
{ echo "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001"
  echo "Subject: Re: [PATCH v3] ata: libahci: re-enable FBS after error handling on a port multiplier"
  echo; cat; } > "$D/sashiko.txt" <<'EOF'
An automated review (Sashiko) of this patch pointed out that
ahci_enable_fbs() writes PxFBS.EN after hpriv->stop_engine(), which
clears PxCMD.ST but leaves PxCMD.FRE set, and asked whether that could
upset strict controllers.

For the record: this patch only adds a third caller of the existing
helper. ahci_pmp_attach() (every boot with a port multiplier, after
ahci_start_port() has enabled FIS reception) and ahci_do_softreset()
(after a successful fan-out softreset) already call ahci_enable_fbs()
with the port in the same state, so the patch does not change when or
how PxFBS.EN is written. If the helper should also stop FIS reception
around the write, that would be a separate change to ahci_enable_fbs()
and ahci_disable_fbs(); I am happy to look into it if the maintainers
think it is worth doing.

Tested on the 88SE9235 + 88SM9705 setup from the commit message: the
hot-plug now ends with "re-enabling FBS after error handling" and
"FBS is enabled", and parallel reads behind the multiplier scale again.
EOF
case "${1:-show}" in
  show) echo "===== $D/sashiko.txt (in reply to $IRT)"; cat "$D/sashiko.txt"; echo; echo "Nothing sent. To send: run this script again with the argument: send";;
  send) git send-email --to=linux-ide@vger.kernel.org --cc=dlemoal@kernel.org --cc=cassel@kernel.org --cc=linux-kernel@vger.kernel.org --suppress-cc=all --in-reply-to="$IRT" "$D/sashiko.txt";;
  *) echo "usage: $0 [show|send]"; exit 2;;
esac
