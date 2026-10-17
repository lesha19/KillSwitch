#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The boot window guard never strands the network (ADR 0037, the 15.10.2026 incident): the
# services it turned off at shutdown come back and stay listed in the mark until networksetup
# itself says they are on. Against a stateful fake networksetup (services in a file, knobs that
# make "on" do nothing), a fake pf and a fake ifconfig -l: nothing of the system is touched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; VPN_ON="$DIR/vpn-on"; GAPF="$DIR/vpn-gap"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; EVENTS="$DIR/events.log"; DIAG="$tmp/diag"
HASHF="$DIR/rules.sha256"; SIGF="$DIR/tunnels"; FILESF="$DIR/rules.files"; INVALIDF="$DIR/invalid"; CORE_EGRESS="$DIR/none"
WIFI_MARK="$DIR/wifi-off-by-ks"; NET_SEEN="$DIR/net-guard-seen"; STATEF="$DIR/daemon-state"; NB_PLIST="$DIR/none"
dscl() { return 1; }
core_running() { return 0; }
PF_TRIES=1   # a refused load is not tried again here
PF=on; echo 'anchor "com.apple/*" all' > "$tmp/main"; : > "$tmp/anchor"
pfctl() {
  case "$*" in
    "-s info") echo "Status: $([ "$PF" = on ] && echo Enabled || echo Disabled)" ;;
    "-E") PF=on ;;
    "-s rules") cat "$tmp/main" ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") if [ -e "$tmp/pf-refuses" ]; then cat > /dev/null; echo "pfctl: Syntax error" >&2; return 1; fi; cat > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) return 1 ;;
  esac
}
utun_addrs() { echo "utun4 198.18.0.1"; }
core_guard() { CORE_STATE=off; }
JOB=loaded; DISABLED='	"local.killswitch" => enabled'
launchctl() {
  case "$*" in
    "print-disabled system") printf '{\n%s\n}\n' "$DISABLED" ;;
    "print system/local.killswitch") [ "$JOB" = loaded ] ;;
    *) return 0 ;;
  esac
}

# --- the fake networksetup: "$S" holds "name<TAB>device<TAB>Enabled|Disabled" per service, in
# order. Files, not variables: ks may run it in a subshell. Knobs:
#   $tmp/noop    a number: that many "on" calls are accepted and do nothing (the incident)
#   $tmp/never   "on" never does anything
#   $tmp/late    "<device> <n>": the device is missing from ifconfig -l for the first n calls
#   $tmp/noconfigd  devices the kernel has (ifconfig -l) and configd does not know yet (the incident)
#   $tmp/inject  a line added to the mark by the next -getnetworkserviceenabled (a concurrent writer)
#   $tmp/extra   raw text appended to -listnetworkserviceorder
S="$tmp/services"
networksetup() {
  local n
  echo "networksetup $*" >> "$tmp/net"
  case "$1" in
    -listnetworkserviceorder)
      echo "An asterisk (*) denotes that a network service is disabled."
      awk -F'\t' '{ printf "(%s) %s\n(Hardware Port: %s, Device: %s)\n\n", ($3 == "Enabled" ? NR : "*"), $1, $1, $2 }' "$S"
      [ ! -s "$tmp/extra" ] || cat "$tmp/extra" ;;
    -getnetworkserviceenabled)
      if [ -s "$tmp/inject" ]; then cat "$tmp/inject" >> "$WIFI_MARK"; rm -f "$tmp/inject"; fi
      n=$2 awk -F'\t' '$1 == ENVIRON["n"] { print $3; f = 1 } END { if (!f) print "** Error: The parameters were not valid." }' "$S" ;;
    -setnetworkserviceenabled)
      n=$2 awk -F'\t' '$1 == ENVIRON["n"] { f = 1 } END { exit !f }' "$S" || { echo "** Error: The parameters were not valid."; return 4; }
      if [ "$3" = on ]; then
        [ -e "$tmp/hang" ] && exec sleep 30   # exec: the timeout kills this very process
        [ -e "$tmp/never" ] && return 0
        n=$(cat "$tmp/noop" 2>/dev/null || echo 0)
        if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$tmp/noop"; return 0; fi
      fi
      n=$2 awk -F'\t' -v OFS='\t' -v s="$([ "$3" = on ] && echo Enabled || echo Disabled)" '$1 == ENVIRON["n"] { $3 = s } 1' "$S" > "$S.new" && mv "$S.new" "$S" ;;
    *) return 1 ;;
  esac
}
ifconfig() {
  local d k
  [ "${1:-}" = -l ] || return 1
  if [ -s "$tmp/late" ]; then
    read -r d k < "$tmp/late"
    if [ "$k" -gt 0 ]; then echo "$d $((k - 1))" > "$tmp/late"; else rm -f "$tmp/late"; d=""; fi
  fi
  echo "lo0 gif0 stf0 anpi0 en0 en1 en7 en8 bridge0 ap1 awdl0 llw0 utun0 utun4" | tr ' ' '\n' | grep -vx "${d:-none}" | paste -sd' ' -
}
# configd's interfaces (scutil, State:/Network/Interface): the kernel's, less $tmp/noconfigd
configd_ifs() {
  local d="" k
  [ -s "$tmp/late" ] && read -r d k < "$tmp/late"
  echo "lo0 gif0 stf0 anpi0 en0 en1 en7 en8 bridge0 ap1 awdl0 llw0 utun0 utun4" | tr ' ' '\n' | grep -vx "${d:-none}" | grep -vxF -f "$tmp/noconfigd"
}
# a clock of its own: every pass is a second, a sleep moves it on; one boot unless $tmp/boot changes
echo 100000 > "$tmp/clock"; echo 1111 > "$tmp/boot"; : > "$tmp/noconfigd"
net_now() { cat "$tmp/clock"; }
tick() { echo $(( $(cat "$tmp/clock") + ${1:-1} )) > "$tmp/clock"; }
sleep() { tick "${1%.*}"; }
eval "$(declare -f boot_id | sed '1s/^boot_id/real_boot_id/')"   # ks's own, kept for its test
boot_id() { cat "$tmp/boot"; }
seen_ago() { echo "$(cat "$tmp/boot") $(( $(cat "$tmp/clock") - $1 ))" > "$NET_SEEN"; }   # the watchdog first saw the mark n s ago
restart() {  # the watchdog starts again (HUP exec, a crash and KeepAlive): its own variables from zero
  NET_OLD=0   # (the watchdog before ADR 0037 review: its own flag, from zero too)
  SECONDS=0; NET_LOGGED=-100; NET_FORCED=0; NET_OK=""; LAST_FLAG=""; PUBLISHED=""
  if declare -F net_guard_start >/dev/null; then net_guard_start; fi
}

fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
services() { printf '%s\n' "$@" | tr '|' '\t' > "$S"; }
state() { n=$1 awk -F'\t' '$1 == ENVIRON["n"] { print $3 }' "$S"; }
ons() { grep -c 'setnetworkserviceenabled .* on$' "$tmp/net"; }
fresh() {  # a new boot: the watchdog just started, nothing logged, rules not loaded yet
  : > "$EVENTS"; : > "$tmp/net"; : > "$tmp/anchor"; : > "$tmp/noconfigd"
  rm -f "$HASHF" "$SIGF" "$FILESF" "$INVALIDF" "$tmp/noop" "$tmp/never" "$tmp/late" "$tmp/pf-refuses" "$tmp/hang" "$tmp/inject" "$tmp/extra" "$FLAG" "$NET_SEEN"
  LAST_FLAG=""; PROT=""; BLOCKING=0; PUBLISHED=""; SECONDS=0; NET_OLD=0; NET_LOGGED=-100; NET_FORCED=0; NET_OK=""
  tick 1000; echo $(( $(cat "$tmp/boot") + 1 )) > "$tmp/boot"
  if declare -F net_guard_start >/dev/null; then net_guard_start; fi
}
passes() { local i; for i in $(seq "$1" "$2"); do watch_pass "$i" 2>/dev/null; tick; done; }
mark_names() { cut -f1 "$WIFI_MARK" 2>/dev/null | sort | paste -sd'|' -; }
can() { declare -F "$1" >/dev/null || { bad "$2: there is no $1"; return 1; }; }

services 'Wi-Fi|en0|Enabled' 'USB 10/100/1000 LAN|en7|Enabled' 'Thunderbolt Bridge|bridge0|Enabled' 'iPhone USB|en8|Disabled' 'Tailscale|utun0|Enabled'

# --- shutdown: every enabled service on a physical port off, "name<TAB>device" in the mark
fresh; rm -f "$WIFI_MARK"
shutdown_guard
[ "$(state Wi-Fi)$(state 'USB 10/100/1000 LAN')$(state 'Thunderbolt Bridge')" = DisabledDisabledDisabled ] &&
  ok "shutdown: Wi-Fi, LAN and the bridge off" || bad "shutdown: $(cat "$S")"
[ "$(state 'iPhone USB')" = Disabled ] && [ "$(state Tailscale)" = Enabled ] && ok "  the user's disabled service and the VPN left as they were" || bad "  others: $(cat "$S")"
grep -qx 'Wi-Fi	en0' "$WIFI_MARK" && grep -qx 'Thunderbolt Bridge	bridge0' "$WIFI_MARK" && ! grep -q 'iPhone USB' "$WIFI_MARK" &&
  ok "  mark: name and device per line, only what ks turned off" || bad "  mark: $(cat "$WIFI_MARK")"

# --- a second shutdown before anything turned them back on: they are "(*)" now, the list stays
cp "$WIFI_MARK" "$tmp/mark1"
shutdown_guard
[ "$(mark_names)" = "Thunderbolt Bridge|USB 10/100/1000 LAN|Wi-Fi" ] && ok "second shutdown: the mark keeps the whole list" ||
  bad "second shutdown truncated the mark: '$(mark_names)'"
ls "$WIFI_MARK".* 2>/dev/null | grep -qv '\.lock$' && bad "  a temporary mark left behind" || ok "  no temporary file left"

# --- a second shutdown after a rename: one line per device, under the name it has now
fresh; services 'Wi-Fi 2|en0|Enabled' 'LAN|en7|Disabled'; printf 'Wi-Fi\ten0\nLAN\ten7\n' > "$WIFI_MARK"
shutdown_guard
[ "$(sort "$WIFI_MARK" | paste -sd'|' -)" = "LAN	en7|Wi-Fi 2	en0" ] && ok "renamed, then a second shutdown: the mark keeps en0 once, by its name now" ||
  bad "rename merge: $(paste -sd'|' "$WIFI_MARK")"
services 'Wi-Fi|en0|Enabled'; printf 'Wi-Fi\n' > "$WIFI_MARK"
shutdown_guard
[ "$(paste -sd'|' "$WIFI_MARK")" = "Wi-Fi	en0" ] && ok "  an old name-only line gives way to the name and device" || bad "  old line merge: $(paste -sd'|' "$WIFI_MARK")"

# --- a service name with a tab cannot be told from its device: left on at shutdown, logged
fresh; services 'LAN|en7|Enabled'; rm -f "$WIFI_MARK"
printf '(9) Home\tNet\n(Hardware Port: Wi-Fi, Device: en5)\n\n' > "$tmp/extra"
shutdown_guard
[ "$(paste -sd'|' "$WIFI_MARK")" = "LAN	en7" ] && ok "a name with a tab: not in the mark" || bad "tab name in the mark: $(paste -sd'|' "$WIFI_MARK")"
grep -q 'setnetworkserviceenabled Home' "$tmp/net" && bad "  networksetup called with half a name" || ok "  networksetup not called with half the name"
grep -q 'en5.*control character' "$EVENTS" && ok "  logged by its device" || bad "  not logged: $(cat "$EVENTS")"

# --- the incident: rules up, but the first two "on" calls do nothing (en0 not in configd yet)
fresh; services 'Wi-Fi|en0|Disabled' 'USB 10/100/1000 LAN|en7|Disabled' 'Thunderbolt Bridge|bridge0|Disabled' 'iPhone USB|en8|Disabled' 'Tailscale|utun0|Enabled'
cp "$tmp/mark1" "$WIFI_MARK"; echo 2 > "$tmp/noop"
passes 0 0
[ -s "$tmp/anchor" ] && ok "boot: rules loaded on the first pass" || bad "boot: rules not loaded"
[ -f "$WIFI_MARK" ] && ok "  'on' did nothing: the mark is kept" || bad "  the mark deleted although the network is still off"
passes 1 2
[ "$(state Wi-Fi)$(state 'USB 10/100/1000 LAN')$(state 'Thunderbolt Bridge')" = EnabledEnabledEnabled ] &&
  ok "  tried again on the next passes: everything back on" || bad "  still off: $(cat "$S")"
[ -f "$WIFI_MARK" ] && ok "  first seen on: the mark waits for a second look" || bad "  mark dropped on the first success"
passes 3 6
[ ! -e "$WIFI_MARK" ] && ok "  the mark gone once still on 3 s later" || bad "  mark left: $(cat "$WIFI_MARK" 2>/dev/null)"
[ ! -e "$NET_SEEN" ] && ok "  the first-seen time goes with it" || bad "  $NET_SEEN left behind"
[ "$(state 'iPhone USB')" = Disabled ] && ok "  the user's own disabled service still off" || bad "  iPhone USB turned on"
grep -q 'network on' "$EVENTS" && ok "  logged" || bad "  not logged: $(cat "$EVENTS")"
[ "$(grep -c 'not back yet' "$EVENTS")" -le 1 ] && ok "  the retries logged at most once" || bad "  retries flood the log: $(grep -c 'not back yet' "$EVENTS")"
n=$(ons); passes 7 8
[ "$(ons)" = "$n" ] && ok "  nothing more once the mark is gone" || bad "  networksetup still called"

# --- Enabled and in the kernel, but configd does not know the device yet: exactly the incident
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; echo en0 > "$tmp/noconfigd"
passes 0 5
[ "$(state Wi-Fi)" = Enabled ] && [ -f "$WIFI_MARK" ] && ok "configd without en0: Enabled is not enough, the mark is kept" || bad "configd: $(cat "$S") / mark $([ -f "$WIFI_MARK" ] && echo kept || echo gone)"
seen_ago 95; passes 6 9
[ -f "$WIFI_MARK" ] && ok "  ...after 90 s too, while the kernel has en0" || bad "  dropped after 90 s though configd never saw en0"
n=$(grep -c 'getnetworkserviceenabled Wi-Fi' "$tmp/net"); passes 10 10
[ "$(grep -c 'getnetworkserviceenabled Wi-Fi' "$tmp/net")" -gt "$n" ] && ok "  checked again every pass" || bad "  not retried"
: > "$tmp/noconfigd"; passes 11 15
[ ! -e "$WIFI_MARK" ] && ok "  gone once configd knows en0" || bad "  mark: $(cat "$WIFI_MARK" 2>/dev/null)"

# --- the interface appears late: Enabled but en0 not in ifconfig -l yet
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; echo "en0 2" > "$tmp/late"
passes 0 0
[ -f "$WIFI_MARK" ] && ok "late interface: kept while en0 is not there" || bad "late interface: mark gone before en0 appeared"
passes 1 8
[ ! -e "$WIFI_MARK" ] && [ "$(state Wi-Fi)" = Enabled ] && ok "  gone once en0 is there" || bad "  mark: $(cat "$WIFI_MARK" 2>/dev/null)"

# --- an adapter unplugged during the restart: on, never in ifconfig -l; the mark does not outlive 90 s
fresh; services 'Dock LAN|en9|Disabled'; printf 'Dock LAN\ten9\n' > "$WIFI_MARK"
passes 0 5
[ "$(state 'Dock LAN')" = Enabled ] && [ -f "$WIFI_MARK" ] && ok "unplugged adapter: turned on, kept while the watchdog waits for it" || bad "unplugged: $(cat "$S")"
seen_ago 95; passes 6 10
[ ! -e "$WIFI_MARK" ] && ok "  90 s on: not in the kernel, Enabled is enough, the mark goes" || bad "  the mark stays for an adapter that is not there"

# --- renamed and deleted services: found by device, or dropped
fresh; services 'Wi-Fi 2|en0|Disabled' 'LAN|en7|Enabled'
printf 'Wi-Fi\ten0\nOld Dock\ten9\n' > "$WIFI_MARK"
passes 0 5
[ "$(state 'Wi-Fi 2')" = Enabled ] && ok "renamed service: found by its device and turned on" || bad "renamed: $(cat "$S")"
[ ! -e "$WIFI_MARK" ] && ok "  a deleted service (no name, no device) does not keep the mark" || bad "  mark: $(cat "$WIFI_MARK" 2>/dev/null)"

# --- a mark from before 0.20.0: names only
fresh; services 'Wi-Fi|en0|Disabled' 'LAN|en7|Disabled'; printf 'Wi-Fi\nLAN\n' > "$WIFI_MARK"
passes 0 5
[ "$(state Wi-Fi)$(state LAN)" = EnabledEnabled ] && [ ! -e "$WIFI_MARK" ] && ok "old mark (names only): read, restored, removed" ||
  bad "old mark: $(cat "$S") / $(cat "$WIFI_MARK" 2>/dev/null)"

# --- a backslash in a name is a backslash (awk -v would read \n as a newline)
fresh; services 'Wi-Fi\new|en0|Disabled'; printf 'Wi-Fi\\new\n' > "$WIFI_MARK"
passes 0 5
[ "$(state 'Wi-Fi\new')" = Enabled ] && [ ! -e "$WIFI_MARK" ] && ok "a backslash in the name: found and turned on" || bad "backslash: $(cat "$S") / $(cat "$WIFI_MARK" 2>/dev/null)"

# --- a line added meanwhile (a shutdown, ks netrestore) is not lost when the watchdog rewrites the mark
fresh; services 'Wi-Fi|en0|Disabled' 'LAN|en7|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; printf 'LAN\ten7\n' > "$tmp/inject"
passes 0 0
grep -qx 'LAN	en7' "$WIFI_MARK" && ok "a line written while net_back ran: still in the mark" || bad "concurrent line lost: $(paste -sd'|' "$WIFI_MARK" 2>/dev/null)"
passes 1 6
[ ! -e "$WIFI_MARK" ] && [ "$(state LAN)" = Enabled ] && ok "  and restored like the others" || bad "  LAN: $(state LAN) / $(cat "$WIFI_MARK" 2>/dev/null)"

# --- networksetup hangs: killed after NS_TIMEOUT, the pass goes on, the mark stays
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/hang"; NS_TIMEOUT=1
t0=$(date +%s); passes 0 0; t=$(($(date +%s) - t0))
[ "$t" -le 3 ] && [ -f "$WIFI_MARK" ] && ok "networksetup hanging: given up after the timeout (${t} s), mark kept" || bad "hang: ${t} s, mark $([ -f "$WIFI_MARK" ] && echo kept || echo gone)"
rm -f "$tmp/hang"; NS_TIMEOUT=3; passes 1 5
[ ! -e "$WIFI_MARK" ] && ok "  restored on the next passes" || bad "  not restored after the hang"

# --- the network comes back before the core is looked after: core_guard (which may hang) runs after it
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"
core_guard() { CORE_STATE=off; echo core >> "$tmp/order"; }
ks_ns=$(declare -f ns)
ns() { case "$1" in -setnetworkserviceenabled) echo net >> "$tmp/order" ;; esac; networksetup "$@"; }
: > "$tmp/order"; passes 0 0
[ "$(head -1 "$tmp/order")" = net ] && ok "net_guard before core_guard in a pass" || bad "pass order: $(paste -sd' ' "$tmp/order")"
core_guard() { CORE_STATE=off; }; eval "$ks_ns"

# --- rules never come up and "on" never works: 90 s after the watchdog first saw the mark it tries anyway
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/pf-refuses"; : > "$tmp/never"
passes 0 3
[ "$BLOCKING" = 0 ] || bad "(setup) the rules loaded although pf refuses them"
[ "$(ons)" = 0 ] && ok "rules not up: the boot window stays closed for now" || bad "rules not up: the network turned on at once"
seen_ago 95; SECONDS=95
passes 4 4
[ "$(ons)" -ge 1 ] && ok "  90 s on: turned on regardless of the rules" || bad "  nothing tried after 90 s"
grep -q 'rules not up after 90 s' "$EVENTS" && ok "  logged" || bad "  not logged: $(cat "$EVENTS")"
[ -f "$WIFI_MARK" ] && ok "  'on' failed: the mark is kept" || bad "  mark deleted though Wi-Fi is off"
grep -q 'NETWORK STILL OFF' "$EVENTS" && ok "  NETWORK STILL OFF logged" || bad "  no NETWORK STILL OFF"
passes 5 10
[ "$(grep -c 'NETWORK STILL OFF' "$EVENTS")" = 1 ] && ok "  ...once a minute, not every pass" || bad "  NETWORK STILL OFF $(grep -c 'NETWORK STILL OFF' "$EVENTS") times"
SECONDS=160; passes 11 11
[ "$(grep -c 'NETWORK STILL OFF' "$EVENTS")" = 2 ] && ok "  ...and again a minute later" || bad "  not repeated after a minute"
rm -f "$tmp/never"; passes 12 16
[ ! -e "$WIFI_MARK" ] && [ "$(state Wi-Fi)" = Enabled ] && ok "  'on' works again: restored without the rules" || bad "  still off"

# --- a mark written at shutdown long ago (any overnight shutdown) opens nothing early: the rules first
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/pf-refuses"
touch -t "$(date -v-20M +%Y%m%d%H%M.%S)" "$WIFI_MARK"
restart; passes 0 2
[ "$(state Wi-Fi)" = Disabled ] && [ -f "$WIFI_MARK" ] && ok "mark 20 min old at start, rules not up: the network stays off" || bad "old mark: network on before the rules: $(cat "$S")"

# --- the 90 s count survives the watchdog restarting (HUP exec, a crash and KeepAlive)
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/pf-refuses"
passes 0 1; seen_ago 95; restart; passes 2 2
[ "$(state Wi-Fi)" = Enabled ] && ok "first seen 95 s ago, watchdog restarted: the fallback still fires" || bad "restart postponed the fallback: $(cat "$S")"
for _ in 1 2 3; do restart; passes 3 3; done
[ "$(state Wi-Fi)" = Enabled ] && ok "  a restart loop does not postpone it either" || bad "  restart loop"
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/pf-refuses"
echo "1 $(( $(cat "$tmp/clock") - 500 ))" > "$NET_SEEN"
passes 0 1
[ "$(state Wi-Fi)" = Disabled ] && ok "a first-seen time from another boot: the count starts again" || bad "old boot's time used: $(cat "$S")"
[ "$(cut -d' ' -f1 "$NET_SEEN" 2>/dev/null)" = "$(cat "$tmp/boot")" ] && ok "  rewritten for this boot" || bad "  $NET_SEEN: $(cat "$NET_SEEN" 2>/dev/null)"
[ "$(stat -f %Lp "$NET_SEEN" 2>/dev/null)" = 644 ] && ok "  world-readable (the app's banner)" || bad "  mode $(stat -f %Lp "$NET_SEEN" 2>/dev/null)"

# --- review fixes (PR 81): the first-seen file and the clock
# boot id: kern.bootsessionuuid (kern.boottime moves when the clock is stepped early in boot)
sysctl() { case "$*" in "-n kern.bootsessionuuid") echo B6CABD8C-0000 ;; "-n kern.boottime") echo "{ sec = 5, usec = 0 } Thu" ;; *) return 1 ;; esac; }
[ "$(real_boot_id)" = B6CABD8C-0000 ] && ok "boot id is kern.bootsessionuuid" || bad "boot id: '$(real_boot_id)'"
unset -f sysctl
# an epoch with a leading zero is not octal: age is read, the fallback still fires
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"
echo "$(cat "$tmp/boot") 0$(( $(cat "$tmp/clock") - 100 ))" > "$NET_SEEN"
[ "$(net_seen_age)" = 100 ] && ok "leading-zero first-seen epoch: age 100" || bad "leading zero: '$(net_seen_age 2>&1)'"
echo "$(cat "$tmp/boot") 99999999999999999999999" > "$NET_SEEN"
[ "$(net_seen_age)" = 0 ] && [ "$(cut -d' ' -f2 "$NET_SEEN")" = "$(cat "$tmp/clock")" ] && ok "  an unusable first-seen time is rewritten now" || bad "  unusable time: '$(cat "$NET_SEEN")'"
# a clock that jumps forward in a running watchdog does not open the network before the rules
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/pf-refuses"
passes 0 1; tick 500; SECONDS=3; passes 2 3
[ "$(state Wi-Fi)" = Disabled ] && ok "clock jumped +500 s after 3 s of uptime: not forced" || bad "forward jump forced the network on: $(cat "$S")"
SECONDS=95; passes 4 4
[ "$(state Wi-Fi)" = Enabled ] && ok "  90 s of uptime and 90 s of age: forced" || bad "  not forced after 95 s uptime"
# a device the kernel has and configd never learns: Enabled is accepted after 300 s, and logged
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; echo en0 > "$tmp/noconfigd"
passes 0 3; seen_ago 305; passes 4 8
[ ! -e "$WIFI_MARK" ] && ok "never in configd: the mark goes after 300 s" || bad "mark kept forever: $(cat "$WIFI_MARK")"
grep -q 'never known to configd' "$EVENTS" && ok "  logged" || bad "  not logged: $(cat "$EVENTS")"

# --- switched off in Login Items while a mark exists: nothing would ever restore it, so now
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"
DISABLED='	"local.killswitch" => disabled'
shutdown_guard
[ "$(state Wi-Fi)" = Enabled ] && [ ! -e "$WIFI_MARK" ] && ok "Login Items off with a mark: the network back on" || bad "Login Items: $(cat "$S") / mark $([ -e "$WIFI_MARK" ] && echo kept)"
DISABLED='	"local.killswitch" => enabled'

# --- ks netrestore: refused while the watchdog will do it, for 20 s after it first saw the mark
fresh; services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; JOB=loaded
touch -t "$(date -v-30M +%Y%m%d%H%M.%S)" "$WIFI_MARK"; seen_ago 5
net_restore 2>/dev/null && bad "netrestore: watchdog saw the mark 5 s ago, rules not up: allowed (the mark's own age counted)" ||
  { [ "$(state Wi-Fi)" = Disabled ] && ok "netrestore refused for the first 20 s the watchdog has"; }
seen_ago 30
net_restore >/dev/null 2>&1 && [ "$(state Wi-Fi)" = Enabled ] && [ ! -e "$WIFI_MARK" ] && ok "  after 20 s it turns the network on (and looks twice)" ||
  bad "netrestore after 20 s: $(cat "$S") / $(cat "$WIFI_MARK" 2>/dev/null)"
services 'Wi-Fi|en0|Disabled'; printf 'Wi-Fi\ten0\n' > "$WIFI_MARK"; : > "$tmp/never"; JOB=unloaded
net_restore >/dev/null 2>&1 && bad "netrestore: says done though Wi-Fi is still off" ||
  { [ -f "$WIFI_MARK" ] && ok "  'on' did nothing: fails and keeps the mark"; }
rm -f "$tmp/never"

# --- uninstall: with the mark gone, every disabled service on en*/bridge* is turned back on
if grep -q 'BASH_SOURCE' "$here/../uninstall.sh"; then
  # shellcheck source=../uninstall.sh
  . "$here/../uninstall.sh"
  if can network_back "uninstall"; then
    fresh; rm -f "$WIFI_MARK"
    services 'Wi-Fi|en0|Disabled' 'Thunderbolt Bridge|bridge0|Disabled' 'Tailscale|utun0|Disabled' 'LAN|en7|Enabled'
    network_back "$tmp/no-ks" >/dev/null 2>&1
    [ "$(state Wi-Fi)$(state 'Thunderbolt Bridge')" = EnabledEnabled ] && ok "uninstall without a mark: disabled en*/bridge* services on" ||
      bad "uninstall: $(cat "$S")"
    [ "$(state Tailscale)" = Disabled ] && ok "  not a VPN's service" || bad "  Tailscale turned on"
    services 'Wi-Fi|en0|Disabled'; : > "$tmp/hang"; NS_TIMEOUT=1
    t0=$(date +%s); network_back "$tmp/no-ks" >/dev/null 2>&1; t=$(($(date +%s) - t0)); rm -f "$tmp/hang"; NS_TIMEOUT=3
    [ "$t" -le 4 ] && ok "  a hanging networksetup is killed (${t} s)" || bad "  uninstall waited ${t} s for networksetup"
  fi
  # the network comes back before the folder (and the ks that knows the mark) is gone
  a=$(grep -n '^ *network_back ' "$here/../uninstall.sh" | head -1 | cut -d: -f1); b=$(grep -n 'rm -rf /Library/KillSwitch' "$here/../uninstall.sh" | cut -d: -f1)
  [ -n "$a" ] && [ "$a" -lt "$b" ] && ok "  run before /Library/KillSwitch is removed" || bad "  order: network_back at '$a', rm at '$b'"
else
  bad "uninstall.sh cannot be loaded by a test (no BASH_SOURCE guard)"
fi

# --- uninstall.sh run directly by a user: it asks sudo for root before anything else. Run with an
# id that says 501 and an exec that only reports; a DEBUG trap stops it before main, should it get there.
printf '%s\n' 'id() { echo 501; }' 'exec() { echo "EXEC $*"; builtin exit 42; }' \
  'trap '\''case $BASH_COMMAND in main*) echo MAIN-RAN; builtin exit 43 ;; esac'\'' DEBUG' > "$tmp/env.sh"
out=$(BASH_ENV="$tmp/env.sh" /bin/bash "$here/../uninstall.sh" 2>&1); rc=$?
[ "$rc" = 42 ] && [[ "$out" == "EXEC sudo $here/../uninstall.sh"* ]] && ok "uninstall.sh as a user: re-runs itself through sudo" ||
  bad "uninstall.sh as a user: rc $rc, '$out'"

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
