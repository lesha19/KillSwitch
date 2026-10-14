#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Fail closed on damaged root files (#17): a settings, allow or servers file that is not ours
# (owner, permissions) or has a line ks did not write blocks everything until «Сбросить настройки»
# (ks repair). A missing file is the defaults and blocks nothing. No root, nothing loaded.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
core_running() { return 0; }   # no standby (ADR 0018)
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/tsrelays"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; SERVERS_CORE="$DIR/servers-core"; EVENTS="$DIR/events.log"
HASHF="$DIR/rules.sha256"; SIGF="$DIR/tunnels"; FILESF="$DIR/rules.files"; INVALIDF="$DIR/invalid"; WIFI_MARK="$DIR/wifi-off-by-ks"; STATEF="$DIR/daemon-state"
NB_PLIST="$DIR/none"   # never the real NetBird plist (netbird.sh tests netbird_sync)
CORE_DIR="$DIR/core"; mkdir "$CORE_DIR"; CORE_EGRESS="$CORE_DIR/egress"; CORE_PROFILE="$CORE_DIR/none"
PF_CONF="$tmp/pf.conf"; echo 'anchor "com.apple/*"' > "$PF_CONF"
vpn_ifaces() { echo utun9; }
ts_ifaces() { :; }
dscl() { return 0; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
LOCKDOWN=$'pass out quick on lo0 all flags any\nblock drop out quick all'
locked() { [ "$(rules)" = "$LOCKDOWN" ]; }
expect_open() { if locked; then bad "$1: everything blocked"; else ok "$1: rules as usual"; fi; }
expect_locked() { if locked; then ok "$1: everything blocked"; else bad "$1: not blocked"; fi; }
reset() { rm -rf "$SETTINGS" "$ALLOW" "$SERVERS" "$SERVERS_MANUAL" "$SERVERS_CORE" "$TSRELAYS" "$CORE_EGRESS" "$SETTINGS.bad"; }

# --- what is fine
reset
expect_open "no settings file at all (the defaults)"
printf 'lan=1\ntailscale=0\ndns=1\ndirect=0\nwifiguard=1\nadblock=1\nblockadult=1\nblocksocial=0\nblockbetting=1\ndoh=https://dns.example.com/dns-query\nsplitapps=/Applications/Telegram.app,curl\nmultihop=Germany 1\n' > "$SETTINGS"
expect_open "every key ks writes, valid values"
printf 'multihop=off\nsplitapps=\n' > "$SETTINGS"
expect_open "multihop off, splitapps cleared"
printf 'core=xray\nxrayserver=\n' > "$SETTINGS"
expect_open "an empty xrayserver (no pick, left by a refused switch before 0.19)"
printf 'lan=1\n\nlan=0\n' > "$SETTINGS"
expect_open "a blank line and a repeated key (the last one counts)"
printf 'coredirect=1\nlan=1\n' > "$SETTINGS"
expect_open "coredirect from before 0.15 (install.sh drops it, ignored meanwhile)"
printf 'failover=1\nlan=1\n' > "$SETTINGS"
expect_open "failover from before 0.20 (ADR 0036: install.sh drops it, ignored meanwhile)"
printf 'hosts=nas.lan=192.168.1.10\nhosts=not a list\nlan=1\n' > "$SETTINGS"
expect_open "hosts from an unreleased 0.20.0 build (#73: install.sh drops it, ignored meanwhile)"
printf 'lan=1' > "$SETTINGS"
expect_open "no newline at the end"
: > "$SETTINGS"
expect_open "empty settings"
reset
printf '192.0.2.1\n203.0.113.0/24\n2001:db8::1\n' > "$ALLOW"; echo 192.0.2.7 > "$SERVERS_MANUAL"; echo 192.0.2.7 > "$SERVERS"
printf '# relays\n\n100.64.0.1\n' > "$TSRELAYS"; echo rules > "$CORE_EGRESS"
expect_open "address lists, tsrelays with comments, egress"
: > "$ALLOW"; : > "$SERVERS"
expect_open "empty lists"

# --- what blocks everything: settings
reset
printf 'lan=1\nvpn=1\n' > "$SETTINGS"; expect_locked "an unknown key"
printf 'lan=2\n' > "$SETTINGS"; expect_locked "a bad value"
printf 'lan=\n' > "$SETTINGS"; expect_locked "an empty value of a switch"
printf 'lan=1\ngarbage\n' > "$SETTINGS"; expect_locked "a line that is not key=value"
printf 'lan =1\n' > "$SETTINGS"; expect_locked "a space in the key"
printf 'splitapps=Apps/Telegram.app\n' > "$SETTINGS"; expect_locked "splitapps that ks set would refuse"
printf 'multihop=\n' > "$SETTINGS"; expect_locked "an empty multihop"
printf 'lan=1\n\001\n' > "$SETTINGS"; expect_locked "binary garbage"
printf 'lan=1\n' > "$SETTINGS"; chmod 664 "$SETTINGS"; expect_locked "settings writable by the group"
chmod 646 "$SETTINGS"; expect_locked "settings writable by anyone"
chmod 644 "$SETTINGS"; OWNER_UID=$((EUID + 1)); expect_locked "settings of another owner"; OWNER_UID=$EUID
rm -f "$SETTINGS"; mkdir "$SETTINGS"; expect_locked "settings is a directory"; rmdir "$SETTINGS"
echo lan=1 > "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$SETTINGS"; expect_locked "settings is a symlink"

# --- the lists the rules are built from
reset
printf '192.0.2.1\nexample.com\n' > "$ALLOW"; expect_locked "allow with a host name (pfctl would resolve it)"
printf '192.0.2.1\n\n' > "$ALLOW"; expect_locked "allow with a blank line"
reset; printf '192.0.2.1;pass\n' > "$SERVERS"; expect_locked "servers with garbage"
reset; printf '192.0.2.1 192.0.2.2\n' > "$SERVERS_MANUAL"; expect_locked "servers-manual with two addresses on a line"
reset; echo 192.0.2.1 > "$ALLOW"; chmod 666 "$ALLOW"; expect_locked "allow writable by anyone"
reset; printf '# relays\nrelay.example\n' > "$TSRELAYS"; expect_locked "tsrelays with a host name"
# KS-19: relays are host addresses; a network (0.0.0.0/0 above all) would open everything to everyone
for net in 0.0.0.0/0 ::/0 192.0.2.0/24 2001:db8::/32 192.0.2.1/32; do
  reset; printf '# relays\n100.64.0.1\n%s\n' "$net" > "$TSRELAYS"; expect_locked "tsrelays with a network ($net)"
done
reset; printf '# relays\n2001:db8::1\n' > "$TSRELAYS"; expect_open "tsrelays with an IPv6 host address"
reset; echo rules > "$CORE_EGRESS"; chmod 666 "$CORE_EGRESS"; expect_locked "egress writable by anyone (it lets the core out)"
reset
[ -z "$(root_files_bad)" ] && ok "nothing reported when all is well" || bad "reported: $(root_files_bad)"
printf 'bogus=1\n' > "$SETTINGS"; printf 'x\n' > "$ALLOW"
[ "$(root_files_bad | paste -sd, -)" = "settings,allow" ] && ok "the bad files are named" || bad "named: $(root_files_bad | paste -sd, -)"
reset
echo 192.0.2.1 > "$tmp/allow.new"; echo nope > "$ALLOW"
[ "$(rules "$tmp/allow.new")" != "$LOCKDOWN" ] && ok "a candidate list (ks allow) is checked, not the installed one" || bad "candidate list"

# --- the watchdog: damage while running is caught within two passes, logged and published
reset
PF=on; : > "$tmp/anchor"
pfctl() {
  case "$*" in
    "-s info") echo "Status: Enabled" ;;
    "-s rules") echo 'anchor "com.apple/*" all' ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") cat > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) return 0 ;;
  esac
}
utun_addrs() { echo "utun4 198.18.0.1"; }
core_guard() { CORE_STATE=off; }
passes() { local i; for i in $(seq "$1" "$2"); do watch_pass "$i"; done; }
st() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$STATEF"; }
passes 0 1
grep -q utun9 "$tmp/anchor" && ok "watchdog: rules loaded" || bad "watchdog: $(cat "$tmp/anchor")"
[ ! -e "$INVALIDF" ] && ok "  nothing named invalid" || bad "  invalid: $(cat "$INVALIDF")"
printf 'lan=1\nlan==\n' > "$SETTINGS"; : > "$EVENTS"
passes 2 3
[ "$(cat "$tmp/anchor")" = "$LOCKDOWN" ] && ok "settings damaged while running: everything blocked within 2 passes" || bad "not caught: $(cat "$tmp/anchor")"
[ "$(st protection)" = on ] && [ "$(cat "$INVALIDF")" = settings ] && [ "$(stat -f %Lp "$INVALIDF")" = 644 ] &&
  ok "  protection on, the app can read what is damaged" || bad "  state: $(cat "$STATEF"), invalid: $(cat "$INVALIDF" 2>&1)"
grep -q 'invalid settings: everything blocked' "$EVENTS" && ok "  logged" || bad "  log: $(cat "$EVENTS")"
: > "$EVENTS"; passes 4 7
[ ! -s "$EVENTS" ] && ok "  not reloaded again while nothing changes" || bad "  reloaded: $(cat "$EVENTS")"
rm -f "$SETTINGS"
passes 8 9
grep -q utun9 "$tmp/anchor" && [ ! -e "$INVALIDF" ] && ok "settings gone (defaults): rules back, nothing named invalid" || bad "after removal: $(cat "$tmp/anchor"; cat "$STATEF")"

# --- what passes the check but pf still refuses (999.1.1.1): everything blocked, not the old rules
echo 999.1.1.1 > "$ALLOW"; : > "$EVENTS"
pfctl() {
  case "$*" in
    "-s info") echo "Status: Enabled" ;;
    "-s rules") echo 'anchor "com.apple/*" all' ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") local r; r=$(cat); grep -q 999 <<<"$r" && return 1; echo "$r" > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) return 0 ;;
  esac
}
passes 12 13
[ "$(cat "$tmp/anchor")" = "$LOCKDOWN" ] && [ "$(cat "$INVALIDF")" = rules ] && ok "rules pf refuses: everything blocked, named" ||
  bad "pf refused: $(cat "$tmp/anchor")"
grep -q 'invalid rules: everything blocked' "$EVENTS" && ok "  logged" || bad "  log: $(cat "$EVENTS")"
: > "$EVENTS"; passes 14 17
[ ! -s "$EVENTS" ] && ok "  not retried while nothing changes" || bad "  retried: $(cat "$EVENTS")"
rm -f "$ALLOW"; passes 18 19
grep -q utun9 "$tmp/anchor" && ok "  fixed: rules back" || bad "  still: $(cat "$tmp/anchor")"

# --- pf refusing a load once (another load of the anchor under way, "Device busy": the watchdog and
# "ks core refresh" reloading together) is not rules pf will not take: no lockdown of the VPN
echo 1 > "$tmp/busy"   # a file: pfctl runs in a pipeline
pfctl() {
  case "$*" in
    "-s info") echo "Status: Enabled" ;;
    "-s rules") echo 'anchor "com.apple/*" all' ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") cat > "$tmp/anchor.in"
      if [ "$(cat "$tmp/busy")" -gt 0 ]; then echo $(($(cat "$tmp/busy") - 1)) > "$tmp/busy"; echo "pfctl: DIOCXCOMMIT: Device busy" >&2; return 1; fi
      mv "$tmp/anchor.in" "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) return 0 ;;
  esac
}
sleep() { :; }
: > "$EVENTS"; load
grep -q utun9 "$tmp/anchor" && [ ! -e "$INVALIDF" ] && ok "pf busy once: the rules loaded on the next try, nothing named invalid" ||
  bad "pf busy once: $(cat "$tmp/anchor"), invalid: $(cat "$INVALIDF" 2>&1)"
grep -q 'invalid' "$EVENTS" && bad "  logged as invalid: $(cat "$EVENTS")" || ok "  not logged as invalid"
# refused on every try (pf busy for longer): the lockdown, but the watchdog tries the rules again
# about every 10 s instead of blocking the VPN until something else changes
echo 3 > "$tmp/busy"; : > "$EVENTS"; load
[ "$(cat "$tmp/anchor")" = "$LOCKDOWN" ] && [ "$(cat "$INVALIDF")" = rules ] && ok "pf busy on every try: everything blocked, named" ||
  bad "busy 3: $(cat "$tmp/anchor"), invalid: $(cat "$INVALIDF" 2>&1)"
: > "$EVENTS"; passes 20 23
[ "$(cat "$tmp/anchor")" = "$LOCKDOWN" ] && [ ! -s "$EVENTS" ] && ok "  pf healthy again: not hammered within 10 s" || bad "  retried at once: $(cat "$EVENTS")"
touch -t "$(date -r $(($(date +%s) - 11)) +%Y%m%d%H%M.%S)" "$INVALIDF"
passes 24 25
grep -q utun9 "$tmp/anchor" && [ ! -e "$INVALIDF" ] && ok "  10 s later: tried again, the rules back, nothing named invalid" ||
  bad "  lockdown kept: $(cat "$tmp/anchor"), invalid: $(cat "$INVALIDF" 2>&1)"
grep -q 'rules loaded again after pf had refused them' "$EVENTS" && ok "  logged" || bad "  log: $(cat "$EVENTS")"
# the clock stepped back: the file's time is in the future, tried again rather than never
echo 3 > "$tmp/busy"; load; echo 0 > "$tmp/busy"
touch -t "$(date -r $(($(date +%s) + 3600)) +%Y%m%d%H%M.%S)" "$INVALIDF"
passes 28 29
grep -q utun9 "$tmp/anchor" && [ ! -e "$INVALIDF" ] && ok "  invalid written in the future (clock stepped back): tried again" ||
  bad "  future mtime: $(cat "$tmp/anchor"), invalid: $(cat "$INVALIDF" 2>&1)"
# still refused: the lockdown stays, tried again later, without flooding the log
echo 3 > "$tmp/busy"; load; echo 3 > "$tmp/busy"; : > "$EVENTS"
touch -t "$(date -r $(($(date +%s) - 11)) +%Y%m%d%H%M.%S)" "$INVALIDF"
passes 26 27
[ "$(cat "$tmp/anchor")" = "$LOCKDOWN" ] && [ "$(cat "$INVALIDF")" = rules ] && [ ! -s "$EVENTS" ] &&
  ok "  refused again on the retry: still blocked, not logged every 10 s" || bad "  retry refused: $(cat "$tmp/anchor"), log: $(cat "$EVENTS")"
echo 2 > "$tmp/busy"; lockdown > "$tmp/anchor"; load_rules lockdown && [ "$(cat "$tmp/anchor")" = "$LOCKDOWN" ] &&
  ok "the lockdown itself is retried when pf is busy" || bad "lockdown not retried"
echo 0 > "$tmp/busy"
# a lockdown left by such a refusal (an older ks): «Сбросить настройки» loads the rules again
lockdown > "$tmp/anchor"; echo rules > "$INVALIDF"; : > "$EVENTS"
repair >/dev/null
grep -q utun9 "$tmp/anchor" && [ ! -e "$INVALIDF" ] && ok "repair after pf refused the rules once: rules back" ||
  bad "repair with only pf's refusal: $(cat "$tmp/anchor"), invalid: $(cat "$INVALIDF" 2>&1)"
unset -f sleep
pfctl() {
  case "$*" in
    "-s info") echo "Status: Enabled" ;;
    "-s rules") echo 'anchor "com.apple/*" all' ;;
    "-a $ANCHOR -s rules") cat "$tmp/anchor" ;;
    "-a $ANCHOR -f -") cat > "$tmp/anchor" ;;
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) return 0 ;;
  esac
}

# --- a damaged off/pause flag must not keep protection off forever
echo garbage > "$FLAG"; : > "$EVENTS"
passes 10 11
[ ! -e "$FLAG" ] && [ "$(st protection)" = on ] && grep -q utun9 "$tmp/anchor" && ok "unreadable off/pause flag: removed, protection on" ||
  bad "flag: $([ -e "$FLAG" ] && cat "$FLAG"), $(cat "$STATEF")"
grep -q 'unreadable' "$EVENTS" && ok "  logged" || bad "  not logged"

# --- the boot window guard does not trust damaged settings either
networksetup() { echo "networksetup $*" >> "$tmp/net"; }
physical_services() { echo Wi-Fi; }
launchctl() { case "$*" in "print-disabled system") echo '{}' ;; *) return 0 ;; esac; }
: > "$tmp/net"; printf 'wifiguard=0\nbogus\n' > "$SETTINGS"
shutdown_guard
grep -q 'Wi-Fi off' "$tmp/net" && ok "shutdown with damaged settings saying wifiguard=0: network off anyway" || bad "boot guard skipped"
rm -f "$WIFI_MARK"; : > "$tmp/net"; printf 'wifiguard=0\n' > "$SETTINGS"
shutdown_guard
[ ! -s "$tmp/net" ] && ok "valid wifiguard=0: network left on" || bad "valid wifiguard=0 ignored"

# --- ks repair: «Сбросить настройки»
reset
printf 'lan=0\nbogus=1\n' > "$SETTINGS"; printf '192.0.2.1\nexample.com\n\n203.0.113.5\n' > "$ALLOW"; chmod 666 "$ALLOW"
echo 192.0.2.7 > "$SERVERS_MANUAL"; echo 198.51.100.1 > "$SERVERS_CORE"; printf '192.0.2.7\nx\n' > "$SERVERS"
rules > "$tmp/anchor"; : > "$EVENTS"
repair >/dev/null
[ ! -e "$SETTINGS" ] && [ -f "$SETTINGS.bad" ] && [ "$(stat -f %Lp "$SETTINGS.bad")" = 600 ] && ok "repair: settings back to the defaults, the damaged one kept root-only" ||
  bad "repair settings: $(ls -l "$DIR")"
[ "$(paste -sd, "$ALLOW")" = "192.0.2.1,203.0.113.5" ] && [ "$(stat -f %Lp "$ALLOW")" = 644 ] && ok "repair: allow keeps its good lines, not writable by others" ||
  bad "repair allow: $(cat "$ALLOW") $(stat -f %Lp "$ALLOW")"
[ "$(paste -sd, "$SERVERS")" = "192.0.2.7,198.51.100.1" ] && ok "repair: servers merged again" || bad "repair servers: $(cat "$SERVERS")"
[ -z "$(root_files_bad)" ] && grep -q utun9 "$tmp/anchor" && ok "repair: nothing bad left, rules loaded as usual" || bad "after repair: $(root_files_bad)"
grep -q 'repaired: settings,allow,servers' "$EVENTS" && ok "  logged" || bad "  log: $(cat "$EVENTS")"
: > "$EVENTS"; repair >/dev/null
[ ! -s "$EVENTS" ] && ok "repair with nothing damaged: does nothing" || bad "repair again: $(cat "$EVENTS")"
# KS-19: a relay list with a network keeps only its host addresses, never 0.0.0.0/0
printf '# relays\n100.64.0.1\n0.0.0.0/0\n::/0\n2001:db8::1\n' > "$TSRELAYS"
repair >/dev/null
[ "$(grep -v '^#' "$TSRELAYS" | paste -sd, -)" = "100.64.0.1,2001:db8::1" ] && [ -z "$(root_files_bad)" ] &&
  ok "repair: tsrelays keeps its host addresses, networks dropped" || bad "repair tsrelays: $(paste -sd, "$TSRELAYS"), bad: $(root_files_bad)"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
