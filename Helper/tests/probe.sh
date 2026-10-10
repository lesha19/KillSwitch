#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# "ks probe" of Helper/ks (why nothing works, ADR 0006): is there a network, do Russian
# (whitelisted) and foreign addresses answer, from the physical interface as the core's group.
# curl, scutil and the group switch replaced; nothing leaves the Mac.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

IFC="en0"; UP=""   # addresses that answer
primary_iface() { echo "$IFC"; }
as_core_group() { echo "group $*" >> "$tmp/calls"; "$@"; }
curl() {
  local url="" ifc="" a
  while [ $# -gt 0 ]; do
    case "$1" in --interface) ifc=$2; shift ;; https://*) url=$1 ;; esac
    shift
  done
  echo "$ifc $url" >> "$tmp/urls"
  a=${url#https://}; a=${a%%/*}
  if [[ " $UP " == *" $a "* ]]; then printf '0.031'; else printf '0.000000'; return 28; fi
}

UP="77.88.8.8 1.1.1.1"
check "everything answers" "$(net_probe)" "link=1 ru=1 foreign=1"
check "probes go out of the physical interface (past the TUN)" "$(cut -d' ' -f1 "$tmp/urls" | sort -u)" "en0"
check "as the core's group, the only one pf lets reach these addresses" "$(grep -vc '^group as_core_group\|^group curl' "$tmp/calls")" 0
check "stops at the first address that answers" "$(cut -d' ' -f2 "$tmp/urls" | paste -sd' ' -)" \
  "https://77.88.8.8/ https://1.1.1.1/"
UP="77.88.8.1"
check "whitelist mode: only the Russian address answers" "$(net_probe)" "link=1 ru=1 foreign=0"
UP="8.8.8.8"
check "foreign only" "$(net_probe)" "link=1 ru=0 foreign=1"
UP=""; : > "$tmp/urls"
check "nothing answers" "$(net_probe)" "link=1 ru=0 foreign=0"
check "only the fixed probe addresses" "$(cut -d' ' -f2 "$tmp/urls" | paste -sd' ' -)" \
  "https://77.88.8.8/ https://77.88.8.1/ https://1.1.1.1/ https://8.8.8.8/"
IFC=""; : > "$tmp/urls"
check "no network: nothing probed" "$(net_probe)" "link=0 ru=0 foreign=0"
check "no network: no requests" "$(wc -l < "$tmp/urls" | tr -d ' ')" 0

# the pf exception that lets the probe out: tcp 443, the core's group, these addresses only
SETTINGS="$tmp/settings"; ALLOW="$tmp/allow"; TSRELAYS="$tmp/none"; CORE_EGRESS="$tmp/none"
SERVERS="$tmp/servers"; SERVERS_MANUAL="$tmp/servers-manual"; : > "$SERVERS"; : > "$SERVERS_MANUAL"
vpn_ifaces() { :; }; ts_ifaces() { :; }; dscl() { return 0; }
core_running() { return 0; }   # no standby (ADR 0018) whatever runs on this Mac
rules > "$tmp/rules"
check "pf: the Russian probe addresses for the core group on tcp 443" \
  "$(grep -c "^pass out quick proto tcp to { 77\.88\.8\.8, 77\.88\.8\.1 } port 443 group $CORE_GROUP flags any keep state$" "$tmp/rules")" 1
check "pf: no other rule names them" "$(grep -c '77\.88\.8' "$tmp/rules")" 1

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
