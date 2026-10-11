#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Checks the pf rules Helper/ks generates for the servers lists; no root, nothing loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"; ALLOW="$tmp/allow"; TSRELAYS="$tmp/none"
SERVERS="$tmp/servers"; SERVERS_MANUAL="$tmp/servers-manual"; SERVERS_CORE="$tmp/servers-core"; CORE_EGRESS="$tmp/egress"
vpn_ifaces() { echo utun9; }
ts_ifaces() { :; }
dscl() { return 0; }   # the _ksvpn group exists
core_running() { return 0; }   # no standby (ADR 0018) unless a check below says otherwise
fails=0
expect() {  # expect <desc> <regex> [absent]
  if grep -qE "$2" "$tmp/out"; then [ -z "${3:-}" ] && echo "ok    $1" || { echo "FAIL  $1"; fails=$((fails + 1)); }
  else [ -n "${3:-}" ] && echo "ok    $1" || { echo "FAIL  $1"; fails=$((fails + 1)); }; fi
}

echo 192.0.2.1 > "$SERVERS_MANUAL"; echo 203.0.113.10 > "$SERVERS_CORE"
servers_merge > "$SERVERS"
rules > "$tmp/out"
expect "manual server reachable by any process" '^pass out quick to \{ 192\.0\.2\.1 \} flags any'
expect "core server not reachable by any process" '^pass out quick to \{[^}]*203\.0\.113\.10' absent
expect "core group reaches both servers only" "^pass out quick proto \{ tcp udp \} to \{ 192\.0\.2\.1,203\.0\.113\.10 \} group $CORE_GROUP"
expect "no broad core rule" "^pass out quick group $CORE_GROUP" absent
expect "core group reaches the DoH resolvers on tcp 443 only (rotation's last resort)" \
  "^pass out quick proto tcp to \{ 1\.1\.1\.1, 8\.8\.8\.8 \} port 443 group $CORE_GROUP flags any keep state$"
expect "no other direct rule for the resolvers" "(udp|port (53|853)).*1\.1\.1\.1|1\.1\.1\.1.*(udp|port (53|853))" absent
expect "resolvers only for the core group" '^pass out quick( proto tcp)? to \{ 1\.1\.1\.1, 8\.8\.8\.8 \}( port 443)? flags' absent
: > "$SERVERS_CORE"; : > "$SERVERS_MANUAL"; : > "$SERVERS"
rules > "$tmp/out"
expect "no servers yet: the resolvers still reachable by the core" "^pass out quick proto tcp to \{ 1\.1\.1\.1, 8\.8\.8\.8 \} port 443 group $CORE_GROUP"
echo 192.0.2.1 > "$SERVERS_MANUAL"; echo 203.0.113.10 > "$SERVERS_CORE"
servers_merge > "$SERVERS"

# IPv6: the core has it off (ipv6: false, no IPv6 in the TUN), so IPv6 leaves through the physical
# interface, where only link-local/multicast (neighbour discovery, AirDrop, Bonjour) and the
# tailnet pass; everything else hits the final block.
expect "ends in block drop out quick all" '^block drop out quick all$'
[ "$(tail -1 "$tmp/out")" = "block drop out quick all" ] && echo "ok    the block is the last rule" ||
  { echo "FAIL  the block is not the last rule"; fails=$((fails + 1)); }
grep -E 'inet6' "$tmp/out" | grep -vE 'fe80::/10, ff00::/8|fd7a:115c:a1e0::/48' > "$tmp/v6"
[ ! -s "$tmp/v6" ] && echo "ok    no IPv6 pass beyond link-local, multicast and the tailnet" ||
  { echo "FAIL  IPv6 rules: $(cat "$tmp/v6")"; fails=$((fails + 1)); }
expect "no pass to any address except fixed ports (DHCP, Tailscale)" '^pass out quick (inet6? )?(proto [^ ]+ )?(proto \{[^}]*\} )?(from any )?to any( flags| keep| group|$)' absent
# the router's DNS over IPv6 link-local (RDNSS) is the router's DNS too: closed unless allowed
v6dns=$(grep -nE '^block drop out quick inet6 proto \{ tcp udp \} to \{ fe80::/10, ff00::/8 \} port 53$' "$tmp/out" | cut -d: -f1)
v6ll=$(grep -nE '^pass out quick inet6 to \{ fe80::/10, ff00::/8 \}' "$tmp/out" | cut -d: -f1)
[ -n "$v6dns" ] && [ -n "$v6ll" ] && [ "$v6dns" -lt "$v6ll" ] && echo "ok    router DNS over IPv6 link-local blocked before link-local passes" ||
  { echo "FAIL  router DNS over IPv6 link-local (block line ${v6dns:-none}, pass line ${v6ll:-none})"; fails=$((fails + 1)); }
printf 'lan=1\ndns=1\n' > "$SETTINGS"; rules > "$tmp/out"
expect "dns=1: router DNS over IPv6 allowed" 'inet6 .*port 53' absent
printf 'lan=0\ndns=1\n' > "$SETTINGS"; rules > "$tmp/out"
expect "lan=0: router DNS over IPv6 blocked (dns needs the home network)" '^block drop out quick inet6 .*port 53'
# «Домашняя сеть» (lan, on by default): private IPv4 networks pass, without it they are blocked
expect "lan=0: no private networks" '10\.0\.0\.0/8|192\.168\.0\.0/16' absent
rm -f "$SETTINGS"; rules > "$tmp/out"
expect "lan default on: private networks reachable" '^pass out quick inet to \{ 10\.0\.0\.0/8, 172\.16\.0\.0/12, 192\.168\.0\.0/16 \} flags any keep state$'
expect "lan default on: the router's DNS stays closed (dns default off)" '^block drop out quick proto \{ tcp udp \} to \{ 10\.0\.0\.0/8, 172\.16\.0\.0/12, 192\.168\.0\.0/16 \} port 53$'

# ADR 0013: the core leaves the tunnel only when its accepted config sends something DIRECT
# (core_commit writes the reasons into $CORE_EGRESS); the old coredirect setting does nothing
echo coredirect=1 > "$SETTINGS"
rules > "$tmp/out"
expect "coredirect=1 alone: no broad core rule" "^pass out quick group $CORE_GROUP" absent
rm -f "$SETTINGS"; : > "$CORE_EGRESS"
rules > "$tmp/out"
expect "empty egress: no broad core rule" "^pass out quick group $CORE_GROUP" absent
printf 'rules\ndns\n' > "$CORE_EGRESS"
rules > "$tmp/out"
expect "egress (subscription DIRECT rules, DNS): broad core rule" "^pass out quick group $CORE_GROUP flags any keep state$"
expect "egress: still only the core group, nobody else" "^pass out quick (proto [^ ]+ )?(flags any )?keep state$|^pass out quick all" absent
rm -f "$CORE_EGRESS"

rm -f "$SETTINGS" "$SERVERS_MANUAL"
rules > "$tmp/out"
expect "before migration all servers stay reachable" '^pass out quick to \{ 192\.0\.2\.1,203\.0\.113\.10 \}'
servers_migrate
[ "$(cat "$SERVERS_MANUAL")" = "$(cat "$SERVERS")" ] && echo "ok    migration keeps every old server as manual" ||
  { echo "FAIL  migration"; fails=$((fails + 1)); }

# ADR 0018: another program's VPN is up and ours is not running: the rules stand by instead of
# cutting it (its server is often ours too, reachable only by the core's group)
core_running() { return 1; }
utun_addrs() { echo "utun23 198.18.0.1"; }
rules > "$tmp/out"
[ "$(cat "$tmp/out")" = "pass out quick all flags any keep state" ] && echo "ok    other VPN up, ours not running: standby, nothing blocked" ||
  { echo "FAIL  standby: $(cat "$tmp/out")"; fails=$((fails + 1)); }
utun_addrs() { printf 'utun23 198.18.0.1\nutun7 198.18.128.1\n'; }
rules > "$tmp/out"
expect "other VPN next to our TUN: no standby" '^block drop out quick all$'
utun_addrs() { :; }
rules > "$tmp/out"
expect "no tunnel at all: no standby" '^block drop out quick all$'
utun_addrs() { echo "utun23 198.18.0.1"; }
core_running() { return 0; }
rules > "$tmp/out"
expect "our core running (TUN not up yet): no standby" '^block drop out quick all$'
core_running() { return 1; }
echo 'lan==' > "$SETTINGS"
rules > "$tmp/out"
[ "$(cat "$tmp/out")" = "$(lockdown)" ] && echo "ok    damaged settings: lockdown wins over standby" ||
  { echo "FAIL  damaged + standby: $(cat "$tmp/out")"; fails=$((fails + 1)); }
rm -f "$SETTINGS"

# NetBird: its daemon is let out by its group (netbird_sync tags it), under the tailscale setting,
# for its own flows only (ADR 0026): UDP (WireGuard to peers on any port, STUN, QUIC relays) and
# TCP to NetBird's management, signal, relay and TURN ports; never DNS (its upstream resolver).
core_running() { return 0; }
rm -f "$SETTINGS"; rules > "$tmp/out"
expect "NetBird's daemon: no DNS or DoT/DoQ past the VPN" \
  "^block drop out quick proto \{ tcp udp \} to any port \{ 53, 853 \} group $NB_GROUP$"
expect "NetBird's daemon: UDP passes (peers listen on any port)" "^pass out quick proto udp group $NB_GROUP keep state$"
expect "NetBird's daemon: TCP only to NetBird's ports" \
  "^pass out quick proto tcp to any port \{ 80, 443, 3478, 5349, 10000, 33073, 33080 \} group $NB_GROUP flags any keep state$"
expect "no broad NetBird rule" "^pass out quick group $NB_GROUP" absent
dnsl=$(grep -n "^block drop out quick proto { tcp udp } to any port { 53, 853 } group $NB_GROUP" "$tmp/out" | cut -d: -f1)
passl=$(grep -n "^pass out quick proto (udp|tcp)[^#]* group $NB_GROUP" -E "$tmp/out" | head -1 | cut -d: -f1)
[ -n "$dnsl" ] && [ -n "$passl" ] && [ "$dnsl" -lt "$passl" ] && echo "ok    NetBird's DNS block comes before its passes" ||
  { echo "FAIL  NetBird's DNS block comes before its passes"; fails=$((fails + 1)); }
[ "$(tail -n 1 "$tmp/out")" = 'block drop out quick all' ] && echo "ok    still fail-closed with NetBird" ||
  { echo "FAIL  still fail-closed with NetBird"; fails=$((fails + 1)); }
# pfctl resolves group names: only where both groups exist (a Mac with KillSwitch installed)
if ! /usr/bin/dscl . -read "/Groups/$NB_GROUP" >/dev/null 2>&1 || ! /usr/bin/dscl . -read "/Groups/$CORE_GROUP" >/dev/null 2>&1; then
  echo "skip  pf parse: no $NB_GROUP/$CORE_GROUP group here"
elif pfctl -nf - < "$tmp/out" >/dev/null 2>&1; then echo "ok    pf parses the rules with NetBird"
else echo "FAIL  pf parses the rules with NetBird: $(pfctl -nf - < "$tmp/out" 2>&1 | grep -v -e 'Use of -f' -e 'present in the main' -e 'pf.conf' | head -3)"; fails=$((fails + 1)); fi
echo tailscale=0 > "$SETTINGS"; rules > "$tmp/out"
expect "tailscale=0: no NetBird pass" "group $NB_GROUP" absent
rm -f "$SETTINGS"
dscl() { [ "$3" != "/Groups/$NB_GROUP" ]; }   # an install from before the group
rules > "$tmp/out"
expect "no NetBird group yet: no NetBird pass" "group $NB_GROUP" absent
dscl() { return 0; }

# KS-14: any program may bind UDP port 68; the DHCP pass is for the system's DHCP client (root)
rm -f "$SETTINGS"; rules > "$tmp/out"
expect "DHCP to a server's port 67 only from root's socket" '^pass out quick inet proto udp from any port 68 to any port 67 user 0 keep state$'
expect "no DHCP pass for any process" '^pass out quick inet proto udp from any port 68 to any port 67 keep state$' absent

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
