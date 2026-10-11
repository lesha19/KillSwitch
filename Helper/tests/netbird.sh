#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# netbird_sync against a copy of NetBird's launchd plist: when its daemon gets our group, when
# the group comes off, and that nothing is touched (or restarted) while nothing changed.
# launchctl, codesign and dscl are fakes; nothing is loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"; EVENTS="$tmp/events.log"; NB_PLIST="$tmp/netbird.plist"
SIGNED=1; GROUP=1
codesign() { echo "codesign $*" >> "$tmp/calls"; [ "$SIGNED" = 1 ]; }
dscl() { [ "$GROUP" = 1 ]; }
launchctl() { echo "launchctl $*" >> "$tmp/calls"; [ "$1" != print ]; }
bin="$tmp/netbird"; echo x > "$bin"
cat > "$NB_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>netbird</string>
<key>ProgramArguments</key><array><string>$bin</string><string>service</string><string>run</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
fails=0
check() {  # check <desc> <condition...>
  local d=$1; shift
  if "$@"; then echo "ok    $d"; else echo "FAIL  $d"; fails=$((fails + 1)); fi
}
restarts() { grep -c '^launchctl bootstrap system ' "$tmp/calls" 2>/dev/null || true; }
group() { nb_group; }
: > "$tmp/calls"

netbird_sync
check "tailscale default on, signed: daemon gets our group" [ "$(group)" = "$NB_GROUP" ]
check "and is restarted once" [ "$(restarts)" = 1 ]
grep -q "subject.OU\] = \"$NB_TEAM\"" "$tmp/calls"; check "signature checked against NetBird's team" [ $? = 0 ]
check "the rest of the plist stays" [ "$(nb_bin)" = "$bin" ]

: > "$tmp/calls"; netbird_sync
check "nothing changed: no signature check, no restart" [ ! -s "$tmp/calls" ]

echo tailscale=0 > "$SETTINGS"; netbird_sync
check "tailscale=0: group taken off" [ -z "$(group)" ]
check "and restarted" [ "$(restarts)" = 1 ]

rm -f "$SETTINGS"; netbird_sync
check "tailscale back on: tagged again" [ "$(group)" = "$NB_GROUP" ]

# an update rewrites the binary with something not signed by NetBird
SIGNED=0; sleep 1; echo y > "$bin"; netbird_sync
check "binary no longer NetBird's: group taken off" [ -z "$(group)" ]

# an update rewrites the plist (no group): tagged again
SIGNED=1; sleep 1; /usr/libexec/PlistBuddy -c 'Set :RunAtLoad true' "$NB_PLIST"; netbird_sync
check "plist rewritten: tagged again" [ "$(group)" = "$NB_GROUP" ]

GROUP=0; echo tailscale=1 > "$SETTINGS"; NB_SIG=""; netbird_sync
check "no group on the system (old install): not tagged" [ -z "$(group)" ]

rm -f "$NB_PLIST"; : > "$tmp/calls"; netbird_sync
check "no NetBird: nothing done" [ ! -s "$tmp/calls" ]

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
