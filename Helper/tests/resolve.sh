#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Server name resolution of Helper/ks: the core's resolver, then DoH, never the LAN's DNS for
# rotation and refresh; fake-ip and unroutable answers refused. curl and dscacheutil replaced.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
CORE_CTL="$tmp/mihomo.sock"
/usr/bin/perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die' "$CORE_CTL"
ans() { printf '{"Status":0,"Answer":[{"type":5,"data":"cdn.example."}%s]}' "$(for a in "$@"; do printf ',{"type":1,"data":"%s"}' "$a"; done)"; }
CORE_ANS=""; DOH_ANS=""   # empty: that resolver fails
curl() {
  local out="" url="" sock=0 ifc=""
  while [ $# -gt 0 ]; do
    case "$1" in -o) out=$2; shift ;; --unix-socket) sock=1; shift ;; --interface) ifc=$2; shift ;; http*) url=$1 ;; esac
    shift
  done
  echo "$url" >> "$tmp/urls"
  [ -z "$ifc" ] || echo "$ifc $url" >> "$tmp/bound"
  if [ "$sock" = 1 ]; then [ -n "$CORE_ANS" ] || return 7; ans $CORE_ANS > "$out"
  else [ -n "$DOH_ANS" ] || return 7; ans $DOH_ANS > "$out"; fi
}
dscacheutil() { echo "lan dns" >> "$tmp/lan"; printf 'name: x\nip_address: 192.0.2.66\n'; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

CORE_ANS="203.0.113.5 203.0.113.6"; DOH_ANS="198.51.100.1"
check "core's resolver first, every A record" "$(resolve_all de.example.com | paste -sd' ' -)" "203.0.113.5 203.0.113.6"
check "no DoH when the core answers" "$(grep -c dns-query "$tmp/urls")" 0
CORE_ANS="198.18.0.5"
check "fake-ip from the core refused, DoH used" "$(resolve_all de.example.com)" 198.51.100.1
CORE_ANS="0.0.0.0 127.0.0.1 224.0.0.1 203.0.113.7"
check "unroutable answers dropped" "$(resolve_all de.example.com)" 203.0.113.7
CORE_ANS=""; DOH_ANS=""
check "nothing answers: nothing" "$(resolve_all de.example.com)" ""
check "rotation never asks the LAN's DNS" "$([ -e "$tmp/lan" ] && echo asked)" ""
check "refresh (strict) never asks the LAN's DNS" "$(KS_STRICT_DNS=1 resolve_host de.example.com; [ -e "$tmp/lan" ] && echo asked)" ""
EVENTS="$tmp/events.log"; VPN=""
vpn_ifaces() { echo "$VPN"; }
check "import with our core up: no system resolver" "$(resolve_host de.example.com; [ -e "$tmp/lan" ] && echo asked)" ""
rm -f "$CORE_CTL"; VPN=utun5
check "import with another tunnel up: no system resolver" "$(resolve_host de.example.com; [ -e "$tmp/lan" ] && echo asked)" ""
VPN=""
check "first import, no tunnel at all: system resolver" "$(resolve_host de.example.com)" 192.0.2.66
grep -q 'de.example.com.*system resolver' "$EVENTS" && echo "ok    system resolver use logged" || { echo "FAIL  not logged"; fails=$((fails + 1)); }
check "odd names are not looked up" "$(resolve_all 'a&type=AAAA'; echo rc=$?)" rc=1

# rotation's last resort: DoH to 1.1.1.1/8.8.8.8 from the primary interface as group _ksvpn
as_core_group() { echo "as _ksvpn: $1" >> "$tmp/asgid"; "$@"; }
primary_iface() { echo en0; }
CORE_ANS="203.0.113.5"; DOH_ANS="198.51.100.1"; : > "$tmp/urls"; rm -f "$tmp/lan"
check "direct: DoH answer" "$(resolve_direct de.example.com)" 198.51.100.1
check "direct: bound to the primary interface, 1.1.1.1 first" "$(head -1 "$tmp/bound")" "en0 https://1.1.1.1/dns-query?name=de.example.com&type=A"
check "direct: run as the core group" "$(sort -u "$tmp/asgid")" "as _ksvpn: curl"
check "direct: never the core's socket or the LAN's DNS" "$(grep -vc '^https://' "$tmp/urls"; [ -e "$tmp/lan" ] && echo asked)" 0
DOH_ANS=""
check "direct: nothing answers, nothing" "$(resolve_direct de.example.com; echo rc=$?)" rc=1
primary_iface() { :; }
check "direct: no primary interface, no lookup" "$(: > "$tmp/bound"; resolve_direct de.example.com; echo rc=$?; cat "$tmp/bound")" rc=1
check "direct: odd names are not looked up" "$(resolve_direct 'a&type=AAAA'; echo rc=$?)" rc=1

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
