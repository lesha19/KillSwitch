#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The VPN is on from "ks core on" to "ks core off" (ADR 0035): the target file, and pf blocking
# while it is there whatever the protection switch says. A fake pf and launchd, nothing is loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; EVENTS="$DIR/events.log"; VPN_ON="$DIR/vpn-on"; GAPF="$DIR/vpn-gap"
HASHF="$DIR/rules.sha256"; SIGF="$DIR/tunnels"; FILESF="$DIR/rules.files"; INVALIDF="$DIR/invalid"; CORE_EGRESS="$DIR/none"
WIFI_MARK="$DIR/wifi-off-by-ks"; NET_SEEN="$DIR/net-guard-seen"; STATEF="$DIR/daemon-state"; NB_PLIST="$DIR/none"; DIAG="$tmp/diag"
CORE_DIR="$tmp/core"; mkdir -p "$CORE_DIR"; CORE_PLIST="$tmp/core.plist"
printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/xray"; chmod 755 "$CORE_DIR/xray"; echo '{}' > "$CORE_DIR/xray.json"
echo core=xray > "$SETTINGS"
dscl() { return 1; }
PF=on; echo 'anchor "com.apple/*" all' > "$tmp/main"; : > "$tmp/anchor"
pfctl() {
  echo "pfctl $*" >> "$tmp/calls"
  case "$*" in
    "-s info") echo "Status: $([ "$PF" = on ] && echo Enabled || echo Disabled)" ;;
    "-E") PF=on ;;
    "-s rules") cat "$tmp/main" ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") cat > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) return 0 ;;
  esac
}
ADDRS="utun4 198.18.0.1"
utun_addrs() { echo "$ADDRS"; }
# the core's job: "loaded" or "unloaded"; every call logged with what pf held at that moment
echo unloaded > "$tmp/job"
launchctl() {
  echo "launchctl $* anchor=$([ -s "$tmp/anchor" ] && echo rules || echo empty)" >> "$tmp/calls"
  case "$1" in
    print) [ "$(cat "$tmp/job")" = loaded ] && echo 'state = running' ;;
    bootstrap|kickstart) echo loaded > "$tmp/job" ;;
    bootout) echo unloaded > "$tmp/job" ;;
  esac
  [ "$1" != print ] || [ "$(cat "$tmp/job")" = loaded ]
}
pgrep() { return 1; }; xray_api_check() { return 1; }; core_plist_sync() { return 1; }
dns_locked() { echo "dns $1" >> "$tmp/calls"; }; sleep() { :; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
blocked() { grep -q '^block drop out quick all$' "$tmp/anchor"; }

# --- the target: written by "core on", removed only by "core off"
: > "$tmp/calls"; ADDRS=""   # no tunnel before the core runs
core_on 2>"$tmp/err" || bad "core on failed: $(cat "$tmp/err")"
[ -f "$VPN_ON" ] && ok "core on: the VPN target written" || bad "core on: no target file"
[ "$(stat -f %Lp "$VPN_ON" 2>/dev/null)" = 644 ] && ok "  world-readable" || bad "  mode $(stat -f %Lp "$VPN_ON" 2>/dev/null)"
core_off
[ ! -e "$VPN_ON" ] && ok "core off: the target removed" || bad "core off: target still there"
rm -f "$CORE_DIR/xray.json"
core_on 2>/dev/null && bad "core on without a config accepted"
[ ! -e "$VPN_ON" ] && ok "core on refused (no config): no target" || bad "refused core on wrote the target"
echo '{}' > "$CORE_DIR/xray.json"

# --- protection off: "core on" blocks before the core starts, "core off" opens after it stopped
echo 0 > "$FLAG"; : > "$tmp/anchor"; : > "$tmp/calls"; ADDRS=""
core_on 2>/dev/null
grep -m1 -E 'launchctl (bootstrap|kickstart)' "$tmp/calls" | grep -q 'anchor=rules' && blocked &&
  ok "core on, protection off: the rules loaded before the core starts" || bad "core on: $(paste -sd'|' "$tmp/calls")"
ADDRS="utun4 198.18.0.1"
disable 0
blocked && ok "ks off while the VPN is on: the rules stay" || bad "ks off flushed with the VPN on"
disable $(( $(date +%s) + 300 ))
blocked && ok "ks pause while the VPN is on: the rules stay" || bad "ks pause flushed with the VPN on"
echo 0 > "$FLAG"; : > "$tmp/calls"
core_off
[ ! -s "$tmp/anchor" ] && ok "core off, protection off: the rules flushed" || bad "core off kept the rules with protection off"
grep -q 'launchctl bootout.*anchor=rules' "$tmp/calls" && ok "  only after the core was stopped" || bad "  order: $(paste -sd'|' "$tmp/calls")"
grep -q 'launchctl disable' "$tmp/calls" && ok "  the core's job disabled (no core after a reboot)" || bad "  job not disabled: $(paste -sd'|' "$tmp/calls")"
rm -f "$FLAG"; ADDRS=""; core_on 2>/dev/null; ADDRS="utun4 198.18.0.1"
: > "$tmp/calls"
core_off
blocked && ok "core off, protection on: the rules stay" || bad "core off flushed with protection on"
grep -q 'launchctl' "$tmp/calls" && ! grep -q 'anchor=empty' "$tmp/calls" && ! grep -q -- '-F rules' "$tmp/calls" &&
  ok "  pf blocking at every step, and after the target went (no tunnel: everything blocked)" || bad "  gap: $(paste -sd'|' "$tmp/calls")"
echo 0 > "$FLAG"
disable 0
[ ! -s "$tmp/anchor" ] && ok "ks off with the VPN off: flushed as before" || bad "ks off with the VPN off kept the rules"
rm -f "$FLAG"

# --- «Журнал защиты»: one line per gap (the VPN on, not connected), how long and why
CORE=on; core_guard() { CORE_STATE=$CORE; }; BOOT=100; boot_id() { echo "$BOOT"; }
netbird_bg() { :; }; diag_tick() { :; }; diag_bg() { :; }; escalate_bg() { :; }
up()   { CORE=on; ADDRS="utun4 198.18.0.1"; watch_pass "$1"; }
down() { CORE=off; ADDRS=""; watch_pass "$1"; }
ago()  { echo "$(( $(date +%s) - $1 )) ${2:-100}" > "$GAPF"; }   # the gap began <s> ago
gaps() { grep -c 'internet closed' "$EVENTS"; }
: > "$VPN_ON"; : > "$EVENTS"
up 0; down 2
[ -f "$GAPF" ] && [ "$(gaps)" = 0 ] && ok "gap: its start kept on disk (a watchdog restarting in place goes on with it)" || bad "gap start: $(ls "$DIR")"
ago 8; up 4
grep -qE 'internet closed for [89] s: reconnect$' "$EVENTS" && [ ! -e "$GAPF" ] && ok "gap ended: one line, its length and the cause (reconnect)" ||
  bad "gap line: $(cat "$EVENTS")"
up 6
[ "$(gaps)" = 1 ] && ok "  no second line while connected" || bad "  lines: $(gaps)"
down 8; log_event "watchdog: new helper, restarting in place"; ago 3; up 10
tail -1 "$EVENTS" | grep -qE 'internet closed for [34] s: update$' && ok "gap of an update: says so" || bad "update gap: $(tail -1 "$EVENTS")"
down 12; log_event "core: Proxy -> DE 1"; ago 2; up 14
tail -1 "$EVENTS" | grep -qE 'internet closed for [23] s: server switch$' && ok "gap of a server switch: says so" || bad "switch gap: $(tail -1 "$EVENTS")"
down 16; ago 30; rm -f "$VPN_ON"; watch_pass 18
tail -1 "$EVENTS" | grep -qE 'internet closed for 3[01] s: VPN off$' && ok "gap ended by «Отключить VPN»: says so" || bad "off gap: $(tail -1 "$EVENTS")"
: > "$VPN_ON"; down 20; ago 5 99; n=$(gaps); up 22
[ "$(gaps)" = "$n" ] && [ ! -e "$GAPF" ] && ok "a gap from before a reboot: dropped, no line with a made-up length" || bad "reboot gap: $(tail -1 "$EVENTS")"
rm -f "$FLAG"; down 24; rm -f "$VPN_ON"; : > "$EVENTS"; up 26; down 28
[ ! -e "$GAPF" ] && ok "VPN off: no gap at all" || bad "gap without the VPN on"
unset -f core_guard netbird_bg diag_tick diag_bg escalate_bg

# --- «Перезапустить VPN» (ks core restart): the VPN stays on, pf never empty meanwhile
echo 0 > "$FLAG"; : > "$tmp/anchor"; ADDRS=""; echo unloaded > "$tmp/job"
core_on 2>/dev/null; ADDRS="utun4 198.18.0.1"; : > "$tmp/calls"
core_vpn_restart 2>"$tmp/err" || bad "core restart failed: $(cat "$tmp/err")"
grep -q 'launchctl kickstart -k' "$tmp/calls" && ok "core restart: the core restarted in place" || bad "core restart: $(paste -sd'|' "$tmp/calls")"
[ -f "$VPN_ON" ] && blocked && ! grep -q 'anchor=empty' "$tmp/calls" && ok "  protection off: the VPN target kept, pf never empty" ||
  bad "  restart opened pf: $(paste -sd'|' "$tmp/calls")"
rm -f "$VPN_ON"
core_vpn_restart 2>/dev/null && bad "core restart with the VPN off accepted" || ok "core restart with the VPN off: refused (nothing to restart)"

# --- core on / off / restart under the core lock, so a Disconnect cannot land inside a Connect
for c in on off restart; do core_lock_wanted core "$c" || bad "core $c not under the core lock"; done
core_lock_wanted core on && core_lock_wanted core off && ok "core on, off and restart take the core lock"
: > "$tmp/regen"; core_regen() { echo regen >> "$tmp/regen"; }; xray_api_check() { return 0; }
echo unloaded > "$tmp/job"; ADDRS=""
core_on 2>/dev/null
[ "$(grep -c . "$tmp/regen")" = 1 ] && ok "  core on rebuilds the config in this process (a second ks would wait for the lock it holds)" || bad "  regen calls: $(grep -c . "$tmp/regen")"
xray_api_check() { return 1; }; unset -f core_regen

# --- a core that does not stop: the VPN stays on, the rules stay, core off fails (pressed again later)
launchctl() {
  echo "launchctl $* anchor=$([ -s "$tmp/anchor" ] && echo rules || echo empty)" >> "$tmp/calls"
  case "$1" in print) echo 'state = running' ;; esac
}
echo 0 > "$FLAG"; : > "$tmp/calls"
core_off 2>/dev/null && bad "core off reported success with the core still there"
[ -f "$VPN_ON" ] && blocked && ok "core off, the core does not go: VPN target and rules kept, exit non-zero" || bad "stuck core off opened pf"
grep -q 'launchctl disable' "$tmp/calls" && bad "  the core's job disabled although the VPN stays on (no core after a reboot)" ||
  ok "  the core's job left enabled, as the VPN target says (it starts after a reboot)"

# --- ADR 0018 standby never while our VPN is on: another VPN's tunnel during our own restart
launchctl() { case "$1" in print) return 1 ;; esac; }   # our core down for the moment
ADDRS="utun9 198.18.0.5"
rules | grep -qx 'pass out quick all flags any keep state' && bad "VPN on, protection off, a foreign tunnel, our core restarting: pass-all" ||
  ok "VPN on, protection off, a foreign tunnel, our core restarting: the rules block"
rm -f "$VPN_ON"
rules | grep -qx 'pass out quick all flags any keep state' && ok "  the VPN off: standby as before (ADR 0018)" || bad "  standby lost with the VPN off"

# --- «Подключить» while the watchdog still running is a 0.19 one (an upgrade between the new ks in
# place and the takeover: the relaunched app connects at once). That one flushes our rules every pass
# while protection is off, so core on hands over to the new ks (HUP) and starts the core only once
# the new watchdog says vpn=1 blocking=1; never: it fails before the core starts, the target undone.
old_watchdog() {  # old_watchdog <polls before the takeover | never>
  rm -f "$VPN_ON"; echo 0 > "$FLAG"; : > "$tmp/anchor"; : > "$tmp/calls"; echo unloaded > "$tmp/job"; ADDRS=""
  printf 'pid=1\nprotection=off\ncore=off\ntunnels=\nstandby=0\n' > "$STATEF"; rm -f "$tmp/takeover"; TAKE=$1
}
launchctl() {
  echo "launchctl $* anchor=$([ -s "$tmp/anchor" ] && echo rules || echo empty)" >> "$tmp/calls"
  case "$1" in
    print) [ "$2" = "$CORE_JOB" ] && [ "$(cat "$tmp/job")" = loaded ] && echo 'state = running' ;;
    bootstrap|kickstart) echo loaded > "$tmp/job" ;;
    kill) echo "$TAKE" > "$tmp/takeover" ;;
  esac
  [ "$1" != print ] || { [ "$2" = "$CORE_JOB" ] && [ "$(cat "$tmp/job")" = loaded ]; }
}
sleep() {  # each poll: the 0.19 watchdog flushes, until the new one has taken over
  local n
  [ -f "$tmp/takeover" ] || return 0
  n=$(cat "$tmp/takeover"); : > "$tmp/anchor"
  [ "$n" = never ] && return 0
  if [ "$n" -le 1 ]; then
    rm -f "$tmp/takeover"; rules > "$tmp/anchor"
    printf 'pid=2\nprotection=off\ncore=off\ntunnels=\nstandby=0\nvpn=1\nblocking=1\n' > "$STATEF"
  else echo $((n - 1)) > "$tmp/takeover"; fi
}
old_watchdog 4
core_on 2>"$tmp/err"; rc=$?
[ "$rc" = 0 ] && grep -q 'launchctl kill HUP system/local.killswitch ' "$tmp/calls" &&
  ok "core on, a 0.19 watchdog running: HUP, then connected" || bad "core on next to a 0.19 watchdog: rc $rc $(cat "$tmp/err") $(paste -sd'|' "$tmp/calls")"
grep -E 'launchctl (bootstrap|kickstart)' "$tmp/calls" | grep -q 'anchor=empty' &&
  bad "  the core started while the 0.19 watchdog had flushed the rules: $(paste -sd'|' "$tmp/calls")" ||
  ok "  the core started only with the new watchdog's rules loaded"
old_watchdog never
core_on 2>"$tmp/err" && bad "core on accepted although the new watchdog never took over"
! grep -qE 'launchctl (bootstrap|kickstart)' "$tmp/calls" && [ ! -e "$VPN_ON" ] && grep -q 'watchdog' "$tmp/err" &&
  ok "  never taken over: fails before the core starts, the VPN target undone, says why" || bad "  never: $(cat "$tmp/err") $(paste -sd'|' "$tmp/calls")"
old_watchdog 3; : > "$VPN_ON"; rules > "$tmp/anchor"; echo loaded > "$tmp/job"
core_vpn_restart 2>"$tmp/err"
grep -q 'launchctl kickstart -k' "$tmp/calls" && ! grep -q 'kickstart -k.*anchor=empty' "$tmp/calls" && grep -q 'kill HUP' "$tmp/calls" &&
  ok "core restart next to a 0.19 watchdog: the takeover first, restarted with the rules loaded" || bad "  restart: $(paste -sd'|' "$tmp/calls")"
sleep() { :; }; rm -f "$VPN_ON" "$FLAG" "$STATEF" "$tmp/takeover"

# --- two "core on" at once never share a temporary file
grep -q 'vpn-on.tmp' "$here/../ks" && bad "a fixed temporary name for the VPN target" || ok "the VPN target written through a unique temporary file"

# --- uninstall with the VPN on: the target goes before the watchdog's bootout (its shutdown guard
# would turn the network off for a VPN that is being removed)
u="$here/../uninstall.sh"
r=$(grep -n 'rm -f /Library/KillSwitch/vpn-on' "$u" | head -1 | cut -d: -f1); b=$(grep -n 'launchctl bootout system/local.killswitch 2' "$u" | head -1 | cut -d: -f1)
[ -n "$r" ] && [ -n "$b" ] && [ "$r" -lt "$b" ] && ok "uninstall: the VPN target removed before the watchdog stops" || bad "uninstall order: rm at ${r:-none}, bootout at ${b:-none}"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
