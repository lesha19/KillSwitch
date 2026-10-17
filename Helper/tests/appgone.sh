#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# KillSwitch.app moved to the Trash (#84, audit 15.10.2026 §2 H3): the KeepAlive watchdog and its
# pf block must not stay on with nothing left to turn them off. The watchdog looks at the app its
# daemon recorded; ten minutes without it in a row, it removes protection the way "ks off" and
# "ks core off" do (rules, DNS, the core), lets the boot guard's network come back, logs one line
# and boots its own job out. The app back within the ten minutes: nothing happens.
# Against a fake pf, launchctl and ks: nothing of the system is touched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; VPN_ON="$DIR/vpn-on"; GAPF="$DIR/vpn-gap"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; EVENTS="$DIR/events.log"; DIAG="$tmp/diag"
HASHF="$DIR/rules.sha256"; SIGF="$DIR/tunnels"; FILESF="$DIR/rules.files"; INVALIDF="$DIR/invalid"; CORE_EGRESS="$DIR/none"
WIFI_MARK="$DIR/wifi-off-by-ks"; NET_SEEN="$DIR/net-guard-seen"; STATEF="$DIR/daemon-state"; NB_PLIST="$DIR/none"
APP_REC="$DIR/app"; APPS_DIR="$tmp/Applications"
# a second net under the functions below: any of these reached as a program only leaves a line here
mkdir "$tmp/bin"
for c in pfctl launchctl networksetup route scutil ifconfig sfltool sudo osascript; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/real"\nexit 1\n' "$c" "$tmp" > "$tmp/bin/$c"; chmod 755 "$tmp/bin/$c"
done
PATH="$tmp/bin:$PATH"
dscl() { return 1; }
PF_TRIES=1
echo 'anchor "com.apple/*" all' > "$tmp/main"; : > "$tmp/anchor"
pfctl() {
  echo "pfctl $*" >> "$tmp/calls"
  case "$*" in
    "-s info") echo "Status: Enabled" ;;
    "-s rules") cat "$tmp/main" ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") cat > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules"|"-a $ANCHOR -F all") : > "$tmp/anchor" ;;
    *) return 1 ;;
  esac
}
launchctl() {
  echo "launchctl $*" >> "$tmp/calls"
  case "$*" in
    "print-disabled system") printf '{\n\t"local.killswitch" => enabled\n}\n' ;;
    *) return 0 ;;
  esac
}
# "ks core off" of the watchdog: a ks of its own, as the real one runs it under the core lock
printf '#!/bin/bash\necho "ks $*" >> "%s/calls"\n[ "$*" != "core off" ] || rm -f "%s/vpn-on"\n' "$tmp" "$tmp" > "$tmp/ks"; chmod 755 "$tmp/ks"
KS_SELF="$tmp/ks"
utun_addrs() { echo "utun4 198.18.0.1"; }
core_guard() { CORE_STATE=off; }
gap_track() { :; }; netbird_bg() { :; }; diag_tick() { :; }; diag_bg() { :; }; net_guard() { :; }
# the bundle id of an app (PlistBuddy on its Info.plist in ks): a file of the fake bundle here
app_bundle_id() { cat "$1/Contents/id" 2>/dev/null; }

fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
app="$tmp/Applications/KillSwitch.app"
fresh() {  # the watchdog just started, the app in place and recorded, the rules not loaded yet
  rm -rf "$tmp/Applications" "$tmp/.Trash"; mkdir -p "$app/Contents" "$tmp/.Trash"; echo com.lesha19.KillSwitch > "$app/Contents/id"; rm -f "$APP_REC"; echo "$app" > "$APP_REC"
  mkdir -p "$tmp/Applications/Other.app/Contents"; echo com.example.Other > "$tmp/Applications/Other.app/Contents/id"
  : > "$EVENTS"; : > "$tmp/calls"; : > "$tmp/anchor"
  rm -f "$HASHF" "$SIGF" "$FILESF" "$INVALIDF" "$FLAG" "$VPN_ON" "$WIFI_MARK"
  LAST_FLAG=""; PROT=""; BLOCKING=0; PUBLISHED=""; SECONDS=0
  if declare -p APP_MISSING >/dev/null 2>&1; then APP_MISSING=""; APP_GONE=0; fi
}
# passes <from> <to> at <seconds>: the watchdog's passes, SECONDS (its uptime) set first
passes() { local i; SECONDS=$3; for i in $(seq "$1" "$2"); do watch_pass "$i" 2>/dev/null; done; }
blocking() { [ -s "$tmp/anchor" ]; }
booted_out() { grep -qx "launchctl bootout $WATCH_JOB" "$tmp/calls"; }
trash() { mv "$app" "$tmp/.Trash/"; }

# --- the app in place: the watchdog blocks and stays
fresh
passes 0 30 0; passes 31 60 700
blocking && ok "app in place: rules loaded" || bad "app in place: no rules"
[ ! -f "$FLAG" ] && ! booted_out && ok "  nothing removed, the watchdog stays" || bad "  removed with the app in place: $(cat "$tmp/calls")"

# --- the app to the Trash: blocking for ten minutes, then removed, logged once, the job booted out
fresh
passes 0 9 0; trash
passes 10 29 10; passes 30 49 300; passes 50 59 605
blocking && [ ! -f "$FLAG" ] && ! booted_out && ok "app gone 9 min 55 s: still blocking" || bad "app gone under 10 min: protection already removed"
passes 60 79 611
[ ! -s "$tmp/anchor" ] && ok "app gone 10 min: the rules flushed" || bad "app gone 10 min: still blocking (the H3 bug)"
[ "$(cat "$FLAG" 2>/dev/null)" = 0 ] && ok "  protection off, as «ks off» leaves it" || bad "  flag: '$(cat "$FLAG" 2>/dev/null)'"
grep -qx "pfctl -a $ANCHOR -F all" "$tmp/calls" && ok "  the anchor cleared, tables too" || bad "  anchor not cleared: $(grep pfctl "$tmp/calls" | tail -3)"
grep -qx 'ks core off' "$tmp/calls" && ok "  the core stopped and its DNS given back (ks core off)" || bad "  no ks core off"
booted_out && ok "  its own job booted out: KeepAlive does not bring it back" || bad "  the job left to KeepAlive"
[ "$(grep -c 'app' "$EVENTS")" = 1 ] && ok "  one line in the log: $(grep app "$EVENTS" | cut -c21-)" || bad "  log: $(cat "$EVENTS")"
passes 80 99 700
[ "$(grep -c 'ks core off' "$tmp/calls")" = 1 ] && [ "$(grep -c 'app' "$EVENTS")" = 1 ] && ok "  done once, not again every pass" || bad "  repeated: $(cat "$EVENTS")"

# --- with the VPN on (ADR 0035) the block holds whatever ks off says: the core off takes the target away
fresh; echo 1 > "$VPN_ON"
passes 0 9 0; trash; passes 10 19 10; passes 20 39 620
[ ! -f "$VPN_ON" ] && [ ! -s "$tmp/anchor" ] && booted_out && ok "VPN on, app gone 10 min: VPN target gone, rules flushed" ||
  bad "VPN on: vpn-on $([ -f "$VPN_ON" ] && echo kept || echo gone), anchor '$(head -1 "$tmp/anchor")'"

# --- the app back within the window (an update replacing it, a restore from the Trash): nothing
fresh
passes 0 9 0; trash; passes 10 19 10; passes 20 29 400
mv "$tmp/.Trash/KillSwitch.app" "$app"; passes 30 39 590
blocking && ! booted_out && ok "app back after 6 min: still blocking" || bad "app back: protection removed"
trash; passes 40 49 620; passes 50 59 900
blocking && ! booted_out && ok "  gone again: the ten minutes count from then" || bad "  the old count was kept"
passes 60 69 1300
! blocking && booted_out && ok "  ...and end ten minutes later" || bad "  never removed"

# --- a path the watchdog may not look into (TCC on ~/Downloads, a folder without x): not «gone»
fresh
passes 0 9 0; chmod 000 "$tmp/Applications"
passes 10 19 10; passes 20 39 2000
chmod 755 "$tmp/Applications"
blocking && ! booted_out && ok "app not readable (EACCES), 30 min: counts as there, still blocking" || bad "unreadable path taken for a missing app"

# --- no record (installed before #84, never seen by the daemon) or a damaged one: nothing to watch
fresh; rm -f "$APP_REC"; trash
passes 0 9 0; passes 10 29 2000
blocking && ! booted_out && ok "no record: nothing removed" || bad "no record: removed"
fresh; echo 'not a path' > "$APP_REC"; trash
passes 0 9 0; passes 10 29 2000
blocking && ! booted_out && ok "a record that is no app path: nothing removed" || bad "bad record: removed"
fresh; chmod 666 "$APP_REC"; trash
passes 0 9 0; passes 10 29 2000
blocking && ! booted_out && ok "a record others may write: not believed" || bad "writable record believed"

# --- an app on another volume (a DMG, a disk not mounted yet): never watched, whatever the record says
fresh; mkdir -p "$tmp/Volumes/KS/KillSwitch.app"; echo "$tmp/Volumes/KS/KillSwitch.app" > "$APP_REC"
passes 0 9 0; rm -rf "$tmp/Volumes"; passes 10 29 10; passes 30 49 2000
blocking && ! booted_out && ok "record outside /Applications, volume gone 30 min: nothing removed" || bad "app on an unmounted volume taken for gone"
fresh; echo "$tmp/Applications/../Volumes/KillSwitch.app" > "$APP_REC"
passes 0 9 0; passes 10 29 10; passes 30 49 2000
blocking && ! booted_out && ok "  a record leaving /Applications by ..: not believed" || bad "  .. record believed"

# --- renamed inside /Applications, the record not yet rewritten: found by its bundle id, recorded
fresh
passes 0 9 0; mv "$app" "$tmp/Applications/Kill Switch.app"; passes 10 29 10; passes 30 49 620
blocking && ! booted_out && [ ! -f "$FLAG" ] && ok "renamed app: not gone, nothing removed" || bad "renamed app taken for gone"
[ "$(cat "$APP_REC")" = "$tmp/Applications/Kill Switch.app" ] && ok "  the record follows it" || bad "  record: $(cat "$APP_REC")"
passes 50 69 1300
blocking && ! booted_out && ok "  and it is watched there from then on" || bad "  removed after the rename"

# --- removed at an earlier boot: the job comes back at the next one and goes again, silently
fresh; echo 0 > "$FLAG"
passes 0 9 0; trash; passes 10 29 10; passes 30 49 620
booted_out && [ ! -s "$EVENTS" ] && ! grep -q 'ks core off' "$tmp/calls" && ok "next boot, app still gone: booted out again without a log line" ||
  bad "repeat: $(booted_out && echo booted out || echo stays), log '$(cat "$EVENTS")'"

# --- the boot guard's network still off: the watchdog stays until net_guard has it back (ADR 0037)
fresh; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"
passes 0 9 0; trash; passes 10 29 10; passes 30 49 620
[ "$(cat "$FLAG" 2>/dev/null)" = 0 ] && ! booted_out && ok "mark left: protection removed, the watchdog stays to bring the network back" ||
  bad "mark left: flag '$(cat "$FLAG" 2>/dev/null)', $(booted_out && echo booted out || echo stays)"
rm -f "$WIFI_MARK"; passes 50 69 640
booted_out && ok "  booted out once the network is back" || bad "  never booted out"

# --- the daemon records the app path, the watchdog reads it: the same file
grep -q '"/Library/KillSwitch/app"' "$here/../../App/Core/DaemonExecutable.swift" 2>/dev/null &&
  grep -q '^APP_REC="\$DIR/app"' "$here/../ks" && ok "daemon and ks name the same record" || bad "the daemon does not record $DIR/app for ks"

[ ! -s "$tmp/real" ] && ok "no system program reached" || bad "reached the system: $(sort -u "$tmp/real" | head -5)"

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
