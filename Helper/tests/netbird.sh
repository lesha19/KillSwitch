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
NB_SIGF="$tmp/netbird-sig"; NB_RETRYF="$tmp/netbird-retry"; DIR=$tmp
SIGNED=1; GROUP=1; BOOT_FAIL=0
codesign() { echo "codesign $*" >> "$tmp/calls"; [ "$SIGNED" = 1 ]; }
dscl() { [ "$GROUP" = 1 ]; }
launchctl() { echo "launchctl $*" >> "$tmp/calls"; [ "$1" != print ] && { [ "$1" != bootstrap ] || [ "$BOOT_FAIL" = 0 ]; }; }
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

GROUP=0; echo tailscale=1 > "$SETTINGS"; rm -f "$NB_SIGF"; netbird_sync
check "no group on the system (old install): not tagged" [ -z "$(group)" ]

# launchctl bootstrap fails: NetBird would stay down. Not recorded as done, tried again later.
GROUP=1; rm -f "$SETTINGS" "$NB_SIGF"; BOOT_FAIL=1; : > "$tmp/calls"; : > "$EVENTS"; now=1791720000
netbird_sync "$now"
check "bootstrap failed: restart tried" [ "$(restarts)" = 1 ]
grep -q 'netbird: .*did not start' "$EVENTS"; check "bootstrap failed: in events.log" [ $? = 0 ]
check "bootstrap failed: not recorded as done" [ ! -s "$NB_SIGF" ]
: > "$tmp/calls"; netbird_sync $((now + 10))
check "bootstrap failed: no retry before the backoff" [ "$(restarts)" = 0 ]
netbird_sync $((now + 31))
check "bootstrap failed: retried after 30 s" [ "$(restarts)" = 1 ]
: > "$tmp/calls"; netbird_sync $((now + 61))
check "failed again: the next try waits longer" [ "$(restarts)" = 0 ]
BOOT_FAIL=0; netbird_sync $((now + 92))
check "retry succeeded: restarted" [ "$(restarts)" = 1 ]
check "retry succeeded: recorded, no retry left" [ -s "$NB_SIGF" ] && [ ! -e "$NB_RETRYF" ]
grep -q 'netbird: its daemon started again' "$EVENTS"; check "retry succeeded: in events.log" [ $? = 0 ]
: > "$tmp/calls"; netbird_sync $((now + 200))
check "then quiet again" [ ! -s "$tmp/calls" ]

# the watchdog never waits for it: in the background, under its own lock
lockf() { echo "lockf $*" >> "$tmp/calls"; }
: > "$tmp/calls"; netbird_bg; wait
grep -q "^lockf -k -t 0 $DIR/netbird.lock .* _netbird\$" "$tmp/calls"; check "watchdog: netbird_sync in the background under a lock" [ $? = 0 ]
grep -q 'netbird_bg' <(declare -f watch_pass) && ! grep -q 'netbird_sync' <(declare -f watch_pass)
check "watchdog: the loop only starts it" [ $? = 0 ]

rm -f "$NB_PLIST"; : > "$tmp/calls"; netbird_bg; wait
check "no NetBird: nothing started" [ ! -s "$tmp/calls" ]
: > "$tmp/calls"; netbird_sync
check "no NetBird: nothing done" [ ! -s "$tmp/calls" ]

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
