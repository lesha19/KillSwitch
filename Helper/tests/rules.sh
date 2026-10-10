#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Checks the pf rules Helper/ks generates for the servers lists; no root, nothing loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"; ALLOW="$tmp/allow"; TSRELAYS="$tmp/none"
SERVERS="$tmp/servers"; SERVERS_MANUAL="$tmp/servers-manual"; SERVERS_CORE="$tmp/servers-core"
vpn_ifaces() { echo utun9; }
ts_ifaces() { :; }
dscl() { return 0; }   # the _ksvpn group exists
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

echo coredirect=1 > "$SETTINGS"
rules > "$tmp/out"
expect "coredirect=1: broad core rule" "^pass out quick group $CORE_GROUP flags any keep state"

rm -f "$SETTINGS" "$SERVERS_MANUAL"
rules > "$tmp/out"
expect "before migration all servers stay reachable" '^pass out quick to \{ 192\.0\.2\.1,203\.0\.113\.10 \}'
servers_migrate
[ "$(cat "$SERVERS_MANUAL")" = "$(cat "$SERVERS")" ] && echo "ok    migration keeps every old server as manual" ||
  { echo "FAIL  migration"; fails=$((fails + 1)); }

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
