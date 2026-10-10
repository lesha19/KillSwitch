#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The watchdog's passes (ks watch) against a fake pf: what each pass costs, how fast tampering
# and tunnel changes are caught, and the state file the app watches. Nothing is loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; EVENTS="$DIR/events.log"
HASHF="$DIR/rules.sha256"; SIGF="$DIR/tunnels"; WIFI_MARK="$DIR/wifi-off-by-ks"; STATEF="$DIR/daemon-state"
PF_CONF="$tmp/pf.conf"; echo 'anchor "com.apple/*"' > "$PF_CONF"
dscl() { return 1; }   # no core group: fewer rules, same logic
# Fake pf: "on"/"off", the main ruleset and our anchor in files; every call logged.
PF=on; echo 'anchor "com.apple/*" all' > "$tmp/main"; : > "$tmp/anchor"
pfctl() {
  echo "pfctl $*" >> "$tmp/calls"
  case "$*" in
    "-s info") echo "Status: $([ "$PF" = on ] && echo Enabled || echo Disabled)" ;;
    "-E") PF=on ;;
    "-s rules") cat "$tmp/main" ;;
    "-f $PF_CONF") echo 'anchor "com.apple/*" all' > "$tmp/main" ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") cat > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) echo "unexpected pfctl $*" >&2; return 1 ;;
  esac
}
ADDRS="utun4 198.18.0.1"
utun_addrs() { echo "ifconfig" >> "$tmp/calls"; echo "$ADDRS"; }
core_guard() { echo "core_guard" >> "$tmp/calls"; CORE_STATE=off; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
count() { grep -c "^$1" "$tmp/calls" 2>/dev/null; }
passes() { local i; : > "$tmp/calls"; for i in $(seq "$1" "$2"); do watch_pass "$i"; done; }

passes 0 0
[ -s "$tmp/anchor" ] && grep -q 'utun4' "$tmp/anchor" && ok "first pass loads the rules" || bad "first load: $(cat "$tmp/anchor")"

# --- cost: tunnels every pass (one ifconfig), pf every second pass, the core every second pass
passes 1 4
[ "$(count ifconfig)" = 4 ] && ok "steady: one ifconfig per pass" || bad "steady: ifconfig $(count ifconfig) in 4 passes"
[ "$(count pfctl)" -le 6 ] && ok "steady: pf checked every second pass ($(count pfctl) pfctl in 4 passes)" || bad "steady: $(count pfctl) pfctl in 4 passes"
[ "$(count core_guard)" = 2 ] && ok "steady: core checked every second pass" || bad "steady: core_guard $(count core_guard) in 4 passes"
grep -q 'anchor.*-f -' "$tmp/calls" && bad "steady: rules reloaded without a reason" || ok "steady: nothing reloaded"

# --- tampering is caught within two passes (one second each)
: > "$tmp/anchor"
passes 5 6
grep -q 'utun4' "$tmp/anchor" && ok "flushed rules reloaded within 2 passes" || bad "flush not caught"
grep -q 'rules were changed or flushed' "$EVENTS" && ok "  logged" || bad "  not logged"
PF=off
passes 7 8
[ "$PF" = on ] && ok "pf disabled: enabled again within 2 passes" || bad "pf disabled not caught"

# --- someone loaded a main ruleset without Apple's anchor point: ours is not evaluated at all
echo 'pass out all' > "$tmp/main"; : > "$EVENTS"; : > "$tmp/calls"
passes 30 31
grep -q "pfctl -f $PF_CONF" "$tmp/calls" && grep -q 'com.apple' "$tmp/main" && ok "anchor missing: main ruleset reloaded from pf.conf within 2 passes" ||
  bad "anchor missing: $(cat "$tmp/calls")"
grep -q 'anchor missing from main ruleset: reloading' "$EVENTS" && grep -q "main ruleset reloaded from $PF_CONF" "$EVENTS" &&
  ok "  logged, with the file it came from" || bad "  log: $(cat "$EVENTS")"
for i in 1 2 3; do echo 'pass out all' > "$tmp/main"; passes $((30 + 2 * i)) $((31 + 2 * i)); done
[ "$(grep -c "main ruleset reloaded" "$EVENTS")" = 1 ] && ok "  a program fighting over it: restored every time, logged once a minute" ||
  bad "  logged $(grep -c "main ruleset reloaded" "$EVENTS") times"
echo 'pass out all' > "$tmp/main"; : > "$PF_CONF"; : > "$tmp/calls"; : > "$EVENTS"; PFCONF_LOGGED=0
passes 40 41
grep -q "pfctl -f $PF_CONF" "$tmp/calls" && bad "pf.conf without the anchor reloaded anyway" || ok "pf.conf without Apple's anchor: not reloaded (it would not help)"
grep -q "has no com.apple anchor" "$EVENTS" && ok "  logged" || bad "  not logged: $(cat "$EVENTS")"
echo 'anchor "com.apple/*"' > "$PF_CONF"; echo 'anchor "com.apple/*" all' > "$tmp/main"

# --- a new tunnel is let in on the very next pass, whichever it is
ADDRS="utun4 198.18.0.1
utun7 198.18.128.1"
passes 9 9
grep -q 'utun7' "$tmp/anchor" && ok "new tunnel: rules follow on the next pass" || bad "new tunnel not caught"

# --- the state file for the app
st() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$STATEF"; }
[ "$(st protection)" = on ] && [ "$(st tunnels)" = "vpn:utun4,utun7 ts:" ] && [ "$(st pid)" = "$$" ] && [ "$(st core)" = off ] &&
  ok "state file: protection, tunnels, core, pid" || bad "state file: $(cat "$STATEF")"
[ "$(stat -f %Lp "$STATEF")" = 644 ] && ok "state file world-readable" || bad "state file mode $(stat -f %Lp "$STATEF")"
ino=$(stat -f %i "$STATEF")
passes 10 13
[ "$(stat -f %i "$STATEF")" = "$ino" ] && ok "state file not rewritten while nothing changes" || bad "state file rewritten"
echo 0 > "$FLAG"
passes 14 14
[ "$(st protection)" = off ] && ok "off by hand: state follows on the next pass" || bad "off: $(cat "$STATEF")"
echo $(( $(date +%s) + 300 )) > "$FLAG"
passes 15 15
[[ "$(st protection)" =~ ^paused:[0-9]+$ ]] && ok "pause: state follows" || bad "pause: $(cat "$STATEF")"
grep -qE 'DNS|token|password|server' "$STATEF" && bad "state file carries more than the state" || ok "state file holds no settings or secrets"

# --- "ks off" raced with a reload: rules loaded although off
echo 0 > "$FLAG"; rules > "$tmp/anchor"; : > "$EVENTS"
passes 16 17
[ ! -s "$tmp/anchor" ] && ok "off by hand, rules found loaded: flushed within 2 passes" || bad "rules stay loaded while off"
grep -q 'loaded while off' "$EVENTS" && ok "  logged" || bad "  not logged"
: > "$tmp/calls"; passes 18 19
[ "$(count 'pfctl -a')" -le 1 ] && ok "  while off: one anchor check every 2 passes" || bad "  while off: $(count 'pfctl -a') anchor calls"
echo $(( $(date +%s) + 300 )) > "$FLAG"; rules > "$tmp/anchor"
passes 20 21
[ ! -s "$tmp/anchor" ] && ok "paused, rules found loaded: flushed too" || bad "rules stay loaded while paused"

# --- a pause ends by itself
echo $(( $(date +%s) - 1 )) > "$FLAG"; : > "$EVENTS"
passes 22 22
[ ! -e "$FLAG" ] && grep -q 'utun4' "$tmp/anchor" && [ "$(st protection)" = on ] && ok "pause expired: flag gone, rules back, state on, in one pass" ||
  bad "pause expiry: flag $([ -e "$FLAG" ] && echo kept), $(cat "$STATEF")"
grep -q 'pause ended' "$EVENTS" && ok "  logged" || bad "  not logged"
echo $(( $(date +%s) + 300 )) > "$FLAG"; : > "$tmp/anchor"
passes 23 23
[ -e "$FLAG" ] && [ ! -s "$tmp/anchor" ] && ok "pause not yet over: nothing loaded" || bad "pause ended early"
rm -f "$FLAG"

# --- the boot-window guard at TERM: shutdown vs. being switched off in Login Items
rm -f "$FLAG"
networksetup() { echo "networksetup $*" >> "$tmp/net"; }
physical_services() { printf 'Wi-Fi\nUSB 10/100/1000 LAN\n'; }
JOB=loaded; DISABLED='	"local.killswitch" => enabled'
launchctl() {
  case "$*" in
    "print-disabled system") printf '{\n%s\n}\n' "$DISABLED" ;;
    "print system/local.killswitch") [ "$JOB" = loaded ] ;;
    *) return 0 ;;
  esac
}
: > "$tmp/net"; shutdown_guard
[ "$(paste -sd'|' "$WIFI_MARK")" = "Wi-Fi|USB 10/100/1000 LAN" ] && [ "$(grep -c ' off$' "$tmp/net")" = 2 ] &&
  ok "shutdown: physical services off, remembered" || bad "shutdown: $(cat "$tmp/net")"
rm -f "$WIFI_MARK"; : > "$tmp/net"
DISABLED='	"local.killswitch" => disabled'
shutdown_guard
[ ! -e "$WIFI_MARK" ] && [ ! -s "$tmp/net" ] && ok "switched off in Login Items: network left alone (nothing would turn it back on)" ||
  bad "disabled job turned the network off"
grep -q 'switched off .*network left on' "$EVENTS" && ok "  logged" || bad "  not logged"
DISABLED='	"local.killswitch" => true'
shutdown_guard
[ ! -e "$WIFI_MARK" ] && ok "launchctl disable (=> true) counts too" || bad "=> true"
DISABLED='	"local.killswitch" => enabled'; echo 0 > "$FLAG"; : > "$tmp/net"
shutdown_guard
[ ! -s "$tmp/net" ] && ok "off by hand: network left alone" || bad "off by hand"
rm -f "$FLAG"

# --- ks netrestore: the network back on when the watchdog cannot do it
printf 'Wi-Fi\n' > "$WIFI_MARK"; : > "$tmp/net"; : > "$tmp/anchor"
JOB=loaded
net_restore 2>/dev/null && bad "netrestore while the watchdog runs and the rules are not up" ||
  { [ -e "$WIFI_MARK" ] && [ ! -s "$tmp/net" ] && ok "netrestore refused while the watchdog will do it after the rules"; }
JOB=unloaded
net_restore >/dev/null && [ ! -e "$WIFI_MARK" ] && grep -qx 'networksetup -setnetworkserviceenabled Wi-Fi on' "$tmp/net" &&
  ok "netrestore: watchdog gone, the services ks turned off are on again" || bad "netrestore: $(cat "$tmp/net")"
grep -q 'network turned back on' "$EVENTS" && ok "  logged" || bad "  not logged"
printf 'Wi-Fi\n' > "$WIFI_MARK"; JOB=loaded; PF=on; rules > "$tmp/anchor"
net_restore >/dev/null && [ ! -e "$WIFI_MARK" ] && ok "netrestore: watchdog runs, rules loaded: allowed" || bad "netrestore with rules"
: > "$tmp/net"
net_restore >/dev/null && [ ! -s "$tmp/net" ] && ok "netrestore without the mark: nothing to do" || bad "netrestore without mark"

# --- ks version: what the app compares with its own copy
[[ "$(ks_version "$here/../ks")" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?\ [0-9a-f]{64}$ ]] && ok "ks version: version and the file's sha256" ||
  bad "ks version: $(ks_version "$here/../ks")"
[ "$(ks_version "$here/../ks" | cut -d' ' -f2)" = "$(shasum -a 256 "$here/../ks" | cut -d' ' -f1)" ] && ok "  hash of the file itself" || bad "  hash"

# --- the core's log: root-only, capped
CORE_DIR="$tmp/core"; mkdir -m 755 "$CORE_DIR"; CORE_LOG_MAX=1000; CORE_LOG="$CORE_DIR/core.log"
core_log_tidy
[ "$(stat -f %Lp "$CORE_LOG")" = 600 ] && ok "core log created root-only" || bad "core log mode $(stat -f %Lp "$CORE_LOG" 2>/dev/null)"
[ "$(stat -f %Lp "$CORE_DIR")" = 711 ] && ok "core dir not listable by others" || bad "core dir mode $(stat -f %Lp "$CORE_DIR")"
chmod 644 "$CORE_LOG"; echo small > "$CORE_LOG"
core_log_tidy
[ "$(stat -f %Lp "$CORE_LOG")" = 600 ] && [ "$(cat "$CORE_LOG")" = small ] && [ ! -e "$CORE_LOG.1" ] &&
  ok "core log: world-readable one from an older version fixed, small one kept" || bad "core log small: $(ls -l "$CORE_DIR")"
head -c 1500 /dev/zero | tr '\0' x > "$CORE_LOG"; exec 7>>"$CORE_LOG"
core_log_tidy
echo after >&7; exec 7>&-
[ "$(stat -f %z "$CORE_LOG.1")" = 1500 ] && [ "$(stat -f %Lp "$CORE_LOG.1")" = 600 ] && [ "$(cat "$CORE_LOG")" = after ] &&
  ok "core log over the cap: one older copy, truncated in place (launchd's O_APPEND fd keeps writing)" ||
  bad "core log rotate: $(ls -l "$CORE_DIR"; head -c 20 "$CORE_LOG")"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
