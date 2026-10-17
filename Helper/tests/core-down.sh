#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The VPN on with a core that never comes up (#85, audit 15.10.2026 §2 M1): the VPN target outlives
# a reboot (ADR 0035), so everything stays blocked, without a leak, until "ks core off". After five
# minutes of it the watchdog says so in its state file (stuck=1) and the log, once, for the app's
# notification. "ks core off" ends the core's job even when it does not stop on bootout, and fails
# when the DNS was not given back (#92). Against a fake pf, launchctl and DNS store: nothing of the
# system is touched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; VPN_ON="$DIR/vpn-on"; GAPF="$DIR/vpn-gap"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; EVENTS="$DIR/events.log"; DIAG="$tmp/diag"
HASHF="$DIR/rules.sha256"; SIGF="$DIR/tunnels"; FILESF="$DIR/rules.files"; INVALIDF="$DIR/invalid"; CORE_EGRESS="$DIR/none"
WIFI_MARK="$DIR/wifi-off-by-ks"; NET_SEEN="$DIR/net-guard-seen"; STATEF="$DIR/daemon-state"; NB_PLIST="$DIR/none"
CORE_DIR="$tmp/core"; mkdir -p "$CORE_DIR"; DNS_STATE="$CORE_DIR/dns-state"; FOREIGN_VPN="$DIR/foreign-vpn"
# a second net under the functions below: any of these reached as a program only leaves a line here
mkdir "$tmp/bin"
for c in pfctl launchctl networksetup route scutil ifconfig sfltool sudo osascript sysctl; do
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
launchctl() { echo "launchctl $*" >> "$tmp/calls"; return 0; }
utun_addrs() { :; }   # no tunnel: our core never came up
CORE_UP=off
core_guard() { CORE_STATE=$CORE_UP; }
gap_track() { :; }; netbird_bg() { :; }; diag_tick() { :; }; diag_bg() { :; }; net_guard() { :; }; sleep() { :; }

fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
fresh() {  # the watchdog just started after a reboot
  : > "$EVENTS"; : > "$tmp/calls"; : > "$tmp/anchor"
  rm -f "$HASHF" "$SIGF" "$FILESF" "$INVALIDF" "$FLAG" "$VPN_ON" "$WIFI_MARK" "$STATEF"
  LAST_FLAG=""; PROT=""; BLOCKING=0; PUBLISHED=""; SECONDS=0; CORE_UP=off
  if declare -p STUCK_SINCE >/dev/null 2>&1; then STUCK_SINCE=""; VPN_STUCK=0; fi
}
# passes <from> <to> at <seconds>: the watchdog's passes, SECONDS (its uptime) set first
passes() { local i; SECONDS=$3; for i in $(seq "$1" "$2"); do watch_pass "$i" 2>/dev/null; done; }
st() { sed -n "s/^$1=//p" "$STATEF" 2>/dev/null; }
blocked() { grep -q '^block drop out quick all$' "$tmp/anchor"; }
said() { grep -c 'no core for 5 min' "$EVENTS"; }

# --- the VPN on after a reboot, the core never up: blocked, and after 5 min the app is told
fresh; echo 1 > "$VPN_ON"
passes 0 9 0; passes 10 29 290
blocked && ok "VPN on, no core, 4 min 50 s: everything blocked" || bad "VPN on, no core: not blocked (a leak)"
[ "$(st stuck)" = 0 ] && [ "$(said)" = 0 ] && ok "  not yet said" || bad "  said too early: stuck='$(st stuck)', $(cat "$EVENTS")"
passes 30 49 301
[ "$(st stuck)" = 1 ] && ok "5 min without a core: the state file says stuck=1 for the app" || bad "5 min: stuck='$(st stuck)' (the M1 bug: no signal)"
[ "$(said)" = 1 ] && ok "  one line in the log: $(grep 'no core' "$EVENTS" | cut -c21-)" || bad "  log: $(cat "$EVENTS")"
blocked && ok "  still blocked: telling is not opening" || bad "  rules gone after 5 min (a leak)"
passes 50 99 3600
[ "$(said)" = 1 ] && [ "$(st stuck)" = 1 ] && ok "  an hour on: still stuck=1, said once" || bad "  repeated or lost: stuck='$(st stuck)', $(said) lines"

# --- the core comes up: no longer stuck; down again: five new minutes
CORE_UP=on; passes 100 109 3700
[ "$(st stuck)" = 0 ] && ok "the core up: stuck=0" || bad "the core up: stuck='$(st stuck)'"
CORE_UP=off; passes 110 119 3710; passes 120 129 3900
[ "$(st stuck)" = 0 ] && ok "  down again, 3 min: not yet" || bad "  the old count kept: stuck='$(st stuck)'"
passes 130 139 4020
[ "$(st stuck)" = 1 ] && [ "$(said)" = 2 ] && ok "  ...said again 5 min after it went down" || bad "  never said again: stuck='$(st stuck)', $(said) lines"

# --- the VPN off: no core is no trouble
fresh
passes 0 9 0; passes 10 29 3600
[ "$(st stuck)" = 0 ] && [ "$(said)" = 0 ] && ok "VPN off, no core, an hour: never stuck" || bad "VPN off: stuck='$(st stuck)'"

# --- «Отключить VPN» then: the target goes, the job with it
fresh; echo 1 > "$VPN_ON"
passes 0 9 0; passes 10 29 400
dns_locked() { echo "dns $1" >> "$tmp/calls"; }
job=loaded
launchctl() {
  echo "launchctl $*" >> "$tmp/calls"
  case "$1" in
    print) [ "$job" = loaded ] ;;
    kill) [ "$2" = SIGKILL ] && job=gone; return 0 ;;
    *) return 0 ;;
  esac
}
core_off 2>"$tmp/err" && [ ! -f "$VPN_ON" ] && ok "core off while stuck: VPN target gone" || bad "core off failed: $(cat "$tmp/err")"
passes 30 39 410
[ "$(st stuck)" = 0 ] && ok "  stuck=0 once the VPN is off" || bad "  still stuck after core off"
# a core that ignores bootout (stuck in a start, SIGTERM unanswered): killed, not left running
: > "$tmp/calls"; echo 1 > "$VPN_ON"; job=loaded
core_off 2>"$tmp/err" && ok "core off, the job does not go on bootout: killed, success" || bad "core off with a stubborn job: $(cat "$tmp/err")"
grep -qx "launchctl kill SIGKILL $CORE_JOB" "$tmp/calls" && ok "  launchctl kill SIGKILL after bootout timed out" || bad "  no kill: $(paste -sd'|' "$tmp/calls")"
grep -q 'launchctl disable' "$tmp/calls" && [ ! -f "$VPN_ON" ] && ok "  job disabled, target gone" || bad "  job left enabled or target kept"
# a job that does not go even then: as before, the VPN stays on and core off fails (pressed again later)
launchctl() { echo "launchctl $*" >> "$tmp/calls"; [ "$1" != print ] || return 0; }
: > "$tmp/calls"; echo 1 > "$VPN_ON"
if core_off 2>/dev/null; then bad "core off reported success with the core still there"
elif [ -f "$VPN_ON" ]; then ok "a job that survives SIGKILL: core off fails, the VPN target kept"
else bad "target removed with the core running"; fi

# --- core off when the DNS is not given back (#92): non-zero, and the watchdog tries again
launchctl() { echo "launchctl $*" >> "$tmp/calls"; [ "$1" != print ]; }
dns_locked() { "dns_$1"; }   # no lockf in tests
boot_id() { echo B1; }; dns_migrate() { return 1; }
W=Setup:/Network/Service/W/DNS
dns_snapshot() { cat "$tmp/snap"; }
dns_put() { [ "$STORE" = accepts ] && printf '%s\t%s\n' "$1" "$2" > "$tmp/snap"; return 0; }
STORE=refuses; printf '%s\t%s\n' "$W" "$DNS_OURS" > "$tmp/snap"; printf 'boot B1\n%s\t1.1.1.1\n' "$W" > "$DNS_STATE"
echo 1 > "$VPN_ON"; : > "$EVENTS"
if core_off 2>"$tmp/err"; then bad "core off reported success with the DNS still ours (the #92 gap)"
else ok "DNS store refuses: core off fails: $(head -1 "$tmp/err")"; fi
[ -f "$DNS_STATE" ] && ok "  the DNS state kept: the watchdog gives it back on its next pass" || bad "  DNS state removed: nothing tries again"
grep -q 'DNS not restored' "$EVENTS" && ok "  logged" || bad "  not logged: $(cat "$EVENTS")"
eval "$(sed -n '/^core_guard() {/,/^}/p' "$here/../ks")"   # the real one back over the stub above
STORE=accepts; core_guard
[ "$(cut -f2 "$tmp/snap")" = 1.1.1.1 ] && [ ! -f "$DNS_STATE" ] && ok "  the store back: the watchdog restored it, state gone" ||
  bad "  watchdog retry: snap '$(cut -f2 "$tmp/snap")', state $([ -f "$DNS_STATE" ] && echo kept || echo gone)"
printf '%s\t%s\n' "$W" "$DNS_OURS" > "$tmp/snap"; printf 'boot B1\n%s\t1.1.1.1\n' "$W" > "$DNS_STATE"
echo 1 > "$VPN_ON"
core_off 2>"$tmp/err" && [ "$(cut -f2 "$tmp/snap")" = 1.1.1.1 ] && ok "DNS given back: core off succeeds" || bad "core off with a working store: $(cat "$tmp/err")"

[ ! -s "$tmp/real" ] && ok "no system program reached" || bad "reached the system: $(sort -u "$tmp/real" | head -5)"

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
