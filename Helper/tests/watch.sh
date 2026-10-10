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

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
