#!/bin/bash
# Rewrites Helper/tsrelays from Tailscale's public DERP map and the control plane's DNS.
# KS-19: every address any process may reach with tailscale=1 comes from here, so the list is
# only replaced when every step worked, every line is one host address (never a network) and it
# is not far shorter than usual; ks refuses a network in it too (root_file_ok relays).
set -euo pipefail
cd "$(dirname "$0")"
MIN=50
trap 'rm -f tsrelays.tmp' EXIT
{
  echo "# Tailscale DERP relays and control plane, reachable by any process when tailscale=1."
  echo "# Regenerate: Helper/update-tsrelays.sh"
  {
    curl -q -fsS -m 20 https://login.tailscale.com/derpmap/default |
      python3 -I -c 'import json,sys; m=json.load(sys.stdin); [print(n[k]) for r in m["Regions"].values() for n in r["Nodes"] for k in ("IPv4","IPv6") if n.get(k)]'
    for h in controlplane.tailscale.com login.tailscale.com log.tailscale.com; do
      dig +short A "$h"; dig +short AAAA "$h"
    done | { grep -E '^[0-9A-Fa-f:.]+$' || true; }
  } | sort -u
} > tsrelays.tmp
python3 -I -c '
import ipaddress, sys
lines = [l.strip() for l in open(sys.argv[1]) if not l.startswith("#")]
for l in lines:
    a = ipaddress.ip_address(l)  # ValueError for a network, a name or anything else
    if a.is_unspecified or a.is_loopback or a.is_multicast: sys.exit("not a relay: " + l)
if len(lines) < int(sys.argv[2]): sys.exit("only %d addresses" % len(lines))
' tsrelays.tmp "$MIN"
mv tsrelays.tmp tsrelays
grep -vc '^#' tsrelays
