#!/bin/bash
# Rewrites Helper/tsrelays from Tailscale's public DERP map and the control plane's DNS.
set -eu
cd "$(dirname "$0")"
{
  echo "# Tailscale DERP relays and control plane, reachable by any process when tailscale=1."
  echo "# Regenerate: Helper/update-tsrelays.sh"
  {
    curl -fsS -m 20 https://login.tailscale.com/derpmap/default |
      python3 -I -c 'import json,sys; m=json.load(sys.stdin); [print(n[k]) for r in m["Regions"].values() for n in r["Nodes"] for k in ("IPv4","IPv6") if n.get(k)]'
    for h in controlplane.tailscale.com login.tailscale.com log.tailscale.com; do
      dig +short A "$h"; dig +short AAAA "$h"
    done | grep -E '^[0-9A-Fa-f:.]+$'
  } | sort -u
} > tsrelays.tmp
mv tsrelays.tmp tsrelays
grep -vc '^#' tsrelays
