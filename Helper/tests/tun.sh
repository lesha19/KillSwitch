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

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
