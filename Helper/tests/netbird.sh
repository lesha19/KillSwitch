#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# netbird_sync against a copy of NetBird's launchd plist: when its daemon gets our group, when
# the group comes off, and that nothing is touched (or restarted) while nothing changed.
# launchctl, codesign and dscl are fakes; nothing is loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
# under /private/tmp (world-writable, sticky) as on a machine whose TMPDIR is there: nb_trusted
# walks the ancestors only up to the test folder (NB_TRUST_ROOT), never weakened for the real one
tmp=$(mktemp -d /private/tmp/ks-netbird.XXXXXX); trap 'rm -rf "$tmp"' EXIT
NB_TRUST_ROOT=$(cd "$tmp" && pwd -P)
SETTINGS="$tmp/settings"; EVENTS="$tmp/events.log"; NB_PLIST="$tmp/netbird.plist"
NB_SIGF="$tmp/netbird-sig"; NB_RETRYF="$tmp/netbird-retry"; NB_UPF="$tmp/netbird-up"; DIR=$tmp
SIGNED=1; GROUP=1; BOOT_FAIL=0; CONSOLE=1
NB_OWNER=$(id -u)  # the test's files are ours, not root's
nb_user() { [ "$CONSOLE" = 1 ] && id -u; }  # the user at the console
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

# 0.18.0 on a real Mac: NetBird's daemon came back after the restart but stayed disconnected until
# someone ran "netbird up". Its CLI (ProgramArguments[0]) is asked first and "up" run after.
sock="$tmp/nb.sock"; NB_UP_TIMEOUT=1; NB_STATUS_TIMEOUT=1; NB_SETTLE=2; NB_SOCK_WAIT=10; AUTO=0
cat > "$bin" <<EOF
#!/bin/bash
echo "netbird \$*" >> "$tmp/calls"
case \$1 in
  status) [ -e "$tmp/connected" ] && echo "Management: Connected" || echo "Management: Disconnected" ;;
  up) [ -e "$tmp/up-hangs" ] && exec sleep 30; [ -e "$tmp/up-fails" ] && exit 1; touch "$tmp/connected" ;;
esac
EOF
chmod +x "$bin"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments: string --daemon-addr' -c "Add :ProgramArguments: string unix://$sock" "$NB_PLIST"
launchctl() {
  echo "launchctl $*" >> "$tmp/calls"
  case $1 in
    print) return 1 ;;
    bootout) rm -f "$tmp/connected" "$sock" ;;
    bootstrap) [ "$BOOT_FAIL" = 0 ] || return 1
      perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die' "$sock"
      [ "$AUTO" = 0 ] || touch "$tmp/connected" ;;
  esac
}
ups() { grep -c '^netbird up' "$tmp/calls" 2>/dev/null || true; }
flip() { if [ -e "$SETTINGS" ]; then rm -f "$SETTINGS"; else echo tailscale=0 > "$SETTINGS"; fi; }
fresh() { : > "$tmp/calls"; : > "$EVENTS"; rm -f "$tmp/up-fails" "$tmp/up-hangs"; flip; }

fresh; touch "$tmp/connected"; netbird_sync
check "was connected, came back disconnected: restarted" [ "$(restarts)" = 1 ]
check "and netbird up run once" [ "$(ups)" = 1 ]
grep -q "^netbird up .*--daemon-addr unix://$sock" "$tmp/calls"; check "up talks to the plist's daemon address" [ $? = 0 ]
check "connected again" [ -e "$tmp/connected" ]
grep -q 'netbird: reconnected' "$EVENTS"; check "reconnect in events.log" [ $? = 0 ]

fresh; rm -f "$tmp/connected"; netbird_sync
check "was not connected (netbird down): restarted" [ "$(restarts)" = 1 ]
check "but up never run" [ "$(ups)" = 0 ] && [ ! -e "$tmp/connected" ]
! grep -q 'reconnect' "$EVENTS"; check "and nothing about reconnecting logged" [ $? = 0 ]

fresh; AUTO=1; touch "$tmp/connected"; netbird_sync; AUTO=0
check "came back connected by itself: no up" [ "$(ups)" = 0 ]
grep -q 'netbird: reconnected' "$EVENTS"; check "and logged as reconnected" [ $? = 0 ]

fresh; touch "$tmp/connected" "$tmp/up-fails"; netbird_sync
check "up fails: tried once" [ "$(ups)" = 1 ]
grep -q 'netbird: did not reconnect' "$EVENTS"; check "up fails: in events.log" [ $? = 0 ]

fresh; touch "$tmp/connected" "$tmp/up-hangs"; t0=$(date +%s); netbird_sync
check "up hangs: killed, the job goes on" [ $(($(date +%s) - t0)) -lt 10 ]
grep -q 'netbird: did not reconnect' "$EVENTS"; check "up hangs: in events.log" [ $? = 0 ]

# bootstrap fails, the retry brings the daemon back: reconnected then
fresh; touch "$tmp/connected"; BOOT_FAIL=1; now=1791730000; netbird_sync "$now"
check "bootstrap failed: no up yet" [ "$(ups)" = 0 ]
BOOT_FAIL=0; netbird_sync $((now + 31))
check "retry succeeded: up run" [ "$(ups)" = 1 ] && [ -e "$tmp/connected" ]
grep -q 'netbird: reconnected' "$EVENTS"; check "retry succeeded: reconnect logged" [ $? = 0 ]
: > "$tmp/calls"; netbird_sync $((now + 200))
check "then quiet again" [ ! -s "$tmp/calls" ]

# KS-09: root never runs NetBird's binary. Its CLI runs as the user at the console, and only a
# binary signed by NetBird's team that only root can change; anything else is not NetBird.
tagged() { /usr/libexec/PlistBuddy -c 'Delete :GroupName' "$NB_PLIST" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Add :GroupName string $NB_GROUP" "$NB_PLIST"
  rm -f "$NB_SIGF" "$SETTINGS"; : > "$tmp/calls"; : > "$EVENTS"; touch "$tmp/connected"; }
ran() { grep -c '^netbird ' "$tmp/calls" 2>/dev/null || true; }

tagged; SIGNED=0; netbird_sync; SIGNED=1
check "replaced by a foreign binary: group taken off" [ -z "$(group)" ]
check "replaced by a foreign binary: it is never run" [ "$(ran)" = 0 ]

tagged; chmod 775 "$bin"; netbird_sync; chmod 755 "$bin"
check "binary writable by its group: not NetBird, group taken off" [ -z "$(group)" ]
check "binary writable by its group: never run" [ "$(ran)" = 0 ]
grep -q 'netbird: .*can be changed' "$EVENTS"; check "binary writable by others: in events.log" [ $? = 0 ]

open="$tmp/open"; mkdir "$open"; chmod 777 "$open"; cp -p "$bin" "$open/netbird"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $open/netbird" "$NB_PLIST"
tagged; netbird_sync
check "folder anyone can write: not NetBird, never run" [ -z "$(group)" ] && [ "$(ran)" = 0 ]
ln -s "$bin" "$open/link"; /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $open/link" "$NB_PLIST"
/usr/libexec/PlistBuddy -c 'Delete :GroupName' "$NB_PLIST" >/dev/null 2>&1; rm -f "$NB_SIGF"; netbird_sync
# launchd runs the link, which anyone can swap (#50): a swap gets root at NetBird's next start
# whatever ks does, so refusing protects nothing; it is logged
check "a link in a folder anyone can write, to a binary only root can change: NetBird" [ "$(group)" = "$NB_GROUP" ]
grep -q "netbird: $open/link is a link in a folder others than root can write" "$EVENTS"
check "  and in events.log" [ $? = 0 ]
/usr/libexec/PlistBuddy -c 'Delete :GroupName' "$NB_PLIST" >/dev/null 2>&1
mkdir -p "$tmp/links"; ln -s "$bin" "$tmp/links/link"; /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $tmp/links/link" "$NB_PLIST"
rm -f "$NB_SIGF"; netbird_sync
check "a link in a folder only root can change, to such a binary: NetBird" [ "$(group)" = "$NB_GROUP" ]
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $bin" "$NB_PLIST"

tagged; CONSOLE=0; echo tailscale=0 > "$SETTINGS"; netbird_sync; CONSOLE=1
check "nobody at the console: restarted" [ -z "$(group)" ] && [ "$(restarts)" = 1 ]
check "nobody at the console: its CLI never run (not as root either)" [ "$(ran)" = 0 ]

tagged; echo tailscale=0 > "$SETTINGS"; netbird_sync
check "signed, only root can change it: its CLI asked (as the console user)" [ "$(ran)" -gt 0 ]

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

# nb_trusted (#50): launchd runs the path in NetBird's plist, not the file it resolves to, so the
# links are followed one by one and each one's folder is checked: exit 1 when the file or a
# folder above it can be changed by others, 2 (with the real path) when only a link's folder can
rc() { nb_trusted "$1" > /dev/null; echo $?; }
mkdir -p "$tmp/safe" "$tmp/open" "$tmp/real"; chmod 777 "$tmp/open"
echo x > "$tmp/real/netbird"
real=$(cd "$tmp/real" && pwd -P)/netbird
check "nb_trusted: a trusted file, by its real path" [ "$(nb_trusted "$tmp/real/netbird")" = "$real" ]
ln -s "$tmp/real/netbird" "$tmp/safe/nb"
check "  a link in a trusted folder: 0, its target" [ "$(nb_trusted "$tmp/safe/nb")" = "$real" -a "$(rc "$tmp/safe/nb")" = 0 ]
ln -s ../real/netbird "$tmp/safe/rel"
check "  a relative link too" [ "$(nb_trusted "$tmp/safe/rel")" = "$real" ]
ln -s "$tmp/real/netbird" "$tmp/open/nb"
check "  a link in a folder anyone can write: 2, with its target" [ "$(rc "$tmp/open/nb")" = 2 -a "$(nb_trusted "$tmp/open/nb")" = "$real" ]
ln -s "$tmp/open/nb" "$tmp/safe/chain"
check "  a trusted link to such a link: 2 (the middle link counts)" [ "$(rc "$tmp/safe/chain")" = 2 ]
ln -s "$tmp/open" "$tmp/safe/dir"
check "  through a linked folder anyone can write: 2" [ "$(rc "$tmp/safe/dir/nb")" = 2 ]
cp "$tmp/real/netbird" "$tmp/open/netbird"; ln -s "$tmp/open/netbird" "$tmp/safe/into"
check "  a trusted link to a file in such a folder: 1" [ "$(rc "$tmp/safe/into")" = 1 ]
check "  nb_target: the real path on 0 and 2, nothing on 1" [ "$(nb_target "$tmp/open/nb")" = "$real" -a -z "$(nb_target "$tmp/safe/into")" ]
ln -s "$tmp/safe/loop" "$tmp/safe/loop2"; ln -s "$tmp/safe/loop2" "$tmp/safe/loop"
check "  a link loop: 1" [ "$(rc "$tmp/safe/loop")" = 1 ]
check "  a relative path: 1" [ "$(rc "real/netbird")" = 1 ]
chmod 666 "$tmp/real/netbird"
check "  a file others can write: 1" [ "$(rc "$tmp/safe/nb")" = 1 -a "$(rc "$tmp/open/nb")" = 1 ]

# the real walk goes up to / (ks sets it, the environment cannot): /private/tmp, writable by
# anyone, makes a binary below it untrusted
check "ks walks the ancestors up to /" [ "$(sed -n 's/^NB_TRUST_ROOT=\([^ ]*\).*/\1/p' "$here/../ks")" = / ]
echo x > "$tmp/nb"; NB_TRUST_ROOT=/
untrusted() { ! nb_trusted "$1" >/dev/null; }
check "a binary under a world-writable folder (/private/tmp): not trusted" untrusted "$tmp/nb"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
