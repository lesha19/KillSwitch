#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Checks the detection of a second VPN tunnel next to our core (ifconfig/netstat replaced).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
FOREIGN_VPN="$tmp/foreign-vpn"; EVENTS="$tmp/events.log"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

ADDRS="utun11 100.64.111.130
utun19 198.18.128.1"
utun_addrs() { echo "$ADDRS"; }
tun_addrs() { echo "$ADDRS"; }
ROUTES_BASE='Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.168.89.254     UGScg                 en0
default            link#29            UCSIg              utun11
1                  198.18.128.0       UGSc               utun19
2/7                198.18.128.0       UGSc               utun19
128.0/1            198.18.128.0       UGSc               utun19
100.64/10          link#29            UCS                utun11
100.100.100.100/32 link#29            UCS                utun11'
ROUTES=$ROUTES_BASE
netstat() { echo "$ROUTES"; }

check "our core and Tailscale only: nothing" "$(foreign_tuns)" ""
tun_guard
check "  no state file" "$([ -e "$FOREIGN_VPN" ] && echo yes || echo no)" no

ADDRS="$ADDRS
utun22 198.18.0.1"
ROUTES="$ROUTES_BASE
0/1                198.18.0.1         UGSc               utun22
128.0/1            198.18.0.1         UGSc               utun22"
check "Happ-style split routes: found" "$(foreign_tuns)" utun22
tun_guard
check "  state file for the app" "$(cat "$FOREIGN_VPN")" utun22
check "  world-readable" "$(stat -f %Lp "$FOREIGN_VPN")" 644
tun_guard
check "  logged once" "$(grep -c 'another VPN tunnel' "$EVENTS")" 1

ROUTES="$ROUTES_BASE
default            link#40            UCSg               utun23
10/8               link#40            UCS                utun24
192.168.5/24       link#41            UCS                utun25"
check "default route: found; 10/8 and narrower routes (corporate VPN): not" "$(foreign_tuns)" "utun23"

ROUTES=$ROUTES_BASE
tun_guard
check "gone: state file removed" "$([ -e "$FOREIGN_VPN" ] && echo yes || echo no)" no

ADDRS="utun19 198.18.0.1"   # config from before 198.18.128.1: our TUN cannot be told apart
ROUTES="$ROUTES_BASE
0/1                198.18.0.1         UGSc               utun22"
check "our TUN unknown: no guess" "$(foreign_tuns)" ""

# Beyond 198.18: any tunnel interface (utun, ipsec, ppp) that takes the default route or splits
# it, IPv4 or IPv6, unless it is ours or Tailscale's (100.64/10, fd7a:115c:a1e0::/48).
ADDRS="utun11 100.64.111.130
utun11 fd7a:115c:a1e0::8d3a:7604
utun19 198.18.128.1
utun30 10.66.0.2
ipsec0 10.200.0.7"
ROUTES="$ROUTES_BASE
default            link#50            UCSg               ipsec0"
check "IKEv2 full tunnel (ipsec0, default): found" "$(foreign_tuns)" ipsec0
ROUTES="$ROUTES_BASE
0/1                10.66.0.1          UGSc               utun30
128.0/1            10.66.0.1          UGSc               utun30"
check "WireGuard split routes (10.66.0.2, not 198.18): found" "$(foreign_tuns)" utun30
ROUTES="$ROUTES_BASE
0/1                link#51            UGSc               ppp0
128.0/1            link#51            UGSc               ppp0"
check "PPP (L2TP/PPTP) split routes: found" "$(foreign_tuns)" ppp0
ROUTES="$ROUTES_BASE
default            link#29            UCSg               utun11"
check "Tailscale exit node (100.64/10): not another VPN" "$(foreign_tuns)" ""
ROUTES="$ROUTES_BASE

Internet6:
Destination        Gateway            Flags               Netif Expire
default            fe80::%utun1       UGcIg               utun1
default            fd7a:115c:a1e0::   UGcg               utun11
fd7a:115c:a1e0::/48 utun11            USc                utun11
fd00::/8           fe80::%utun30      UGSc               utun30
fe80::%utun30/64   fe80::1%utun30     UcI                utun30
ff00::/8           ::1                UmCI               utun30"
check "IPv6: Tailscale, scoped defaults and narrow routes: nothing" "$(foreign_tuns)" ""
ROUTES="$ROUTES
::/1               fe80::%utun30      UGSc               utun30
8000::/1           fe80::%utun30      UGSc               utun30"
check "IPv6 split routes: found" "$(foreign_tuns)" utun30
ROUTES="$ROUTES_BASE
default            link#50            UCSg               ipsec0
0/1                10.66.0.1          UGSc               utun30"
check "two of them: both, sorted" "$(foreign_tuns)" "ipsec0 utun30"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
