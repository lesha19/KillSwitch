#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The TUN's MTU (ADR 0032, issue #18): "ks set mtu auto|1280…1500", for both cores. «Авто» is what
# each core had before (Xray 1500, mihomo its own default); a value goes into the TUN inbound only.
# Nothing else in the config moves: the servers for pf, DIRECT and egress stay. No root, no network.
#   Helper/tests/core-mtu.sh   (XRAY=/MIHOMO= to check the configs with the real binaries)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
fx="$here/fixtures"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
DIR="$T"; CORE_DIR="$T/core"; mkdir -p "$CORE_DIR" "$T/home"
SETTINGS="$DIR/settings"; EVENTS="$DIR/events.log"
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; fi.example.com) echo 203.0.113.30 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "$2"; }
same_rest() { cmp -s "$1.direct" "$2.direct" && cmp -s "$1.egress" "$2.egress" && cmp -s "$1.srv" "$2.srv"; }

# --- the setting: auto (no line) or a number from 1280 (IPv6's minimum) to 1500
for v in 1280 1380 1500; do
  echo "mtu=$v" > "$T/set"; settings_lines_ok "$T/set" || bad "settings: mtu=$v refused"
done
ok "settings: mtu=1280…1500 is ours"
for v in 1279 1501 576 9000 01400 1400x "" auto -1; do
  echo "mtu=$v" > "$T/set"; ! settings_lines_ok "$T/set" || bad "settings: mtu=$v accepted"
done
ok "settings: anything else refused (fail closed, ADR 0015)"
core_lock_wanted set mtu && ok "ks set mtu runs under the core lock (it rebuilds)" || bad "set mtu not locked"

# --- Xray: the tun inbound's mtu
gx() { core_generate_xray "$fx/xray-panel.json" "$T/$1" "$T/$1.srv" 2>"$T/err"; }
put_setting core xray
gx x-auto || bad "xray auto refused: $(cat "$T/err")"
[ "$(j '(grep { $_->{tag} eq "ks-tun" } @{ $c->{inbounds} })[0]{settings}{mtu}' "$T/x-auto")" = 1500 ] &&
  ok "Xray, auto: 1500 as before" || bad "xray auto mtu: $(j '$c->{inbounds}' "$T/x-auto")"
put_setting mtu 1380
gx x-1380 || bad "xray 1380 refused: $(cat "$T/err")"
[ "$(j '(grep { $_->{tag} eq "ks-tun" } @{ $c->{inbounds} })[0]{settings}{mtu}' "$T/x-1380")" = 1380 ] &&
  ok "Xray, mtu=1380: the TUN takes it" || bad "xray mtu: $(j '$c->{inbounds}' "$T/x-1380")"
same_rest "$T/x-1380" "$T/x-auto" && [ "$(j 'JSON::PP->new->canonical->encode([ grep { $_->{tag} ne "ks-tun" } @{ $c->{inbounds} } ]) . JSON::PP->new->canonical->encode([ @$c{qw(outbounds routing dns)} ])' "$T/x-1380")" = \
  "$(j 'JSON::PP->new->canonical->encode([ grep { $_->{tag} ne "ks-tun" } @{ $c->{inbounds} } ]) . JSON::PP->new->canonical->encode([ @$c{qw(outbounds routing dns)} ])' "$T/x-auto")" ] &&
  ok "  nothing else: servers, DIRECT, egress, outbounds, routing and DNS as with auto" || bad "  more changed"
if [ -x "$XRAY" ]; then
  out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$T/x-1380" 2>&1) && ok "  xray run -test" || bad "  xray run -test: $(tail -2 <<<"$out")"
else echo "skip  xray run -test (no $XRAY)"; fi
echo 'mtu=99999' > "$SETTINGS"
gx x-bad && [ "$(j '(grep { $_->{tag} eq "ks-tun" } @{ $c->{inbounds} })[0]{settings}{mtu}' "$T/x-bad")" = 1500 ] &&
  ok "  a value out of range never reaches the core" || bad "  bad mtu: $(cat "$T/err")"

# --- mihomo: tun.mtu, only when set (auto: mihomo's own, as before)
gm() { core_generate_mihomo "$fx/ok-full.json" "$T/$1" "$T/$1.srv" 2>"$T/err"; }
printf 'core=mihomo\n' > "$SETTINGS"
gm m-auto || bad "mihomo auto refused: $(cat "$T/err")"
[ "$(j 'exists $c->{tun}{mtu} ? "set" : "none"' "$T/m-auto")" = none ] && ok "mihomo, auto: no tun.mtu, as before" || bad "mihomo auto: $(j '$c->{tun}' "$T/m-auto")"
put_setting mtu 1420
gm m-1420 || bad "mihomo 1420 refused: $(cat "$T/err")"
[ "$(j '$c->{tun}{mtu}' "$T/m-1420")" = 1420 ] && ok "mihomo, mtu=1420: tun.mtu" || bad "mihomo mtu: $(j '$c->{tun}' "$T/m-1420")"
same_rest "$T/m-1420" "$T/m-auto" &&
  [ "$(j 'delete $c->{tun}{mtu}; JSON::PP->new->canonical->encode($c)' "$T/m-1420")" = "$(j 'JSON::PP->new->canonical->encode($c)' "$T/m-auto")" ] &&
  ok "  nothing else changed" || bad "  more changed"
if [ -x "$MIHOMO" ]; then
  out=$("$MIHOMO" -t -d "$T/home" -f "$T/m-1420" 2>&1) && ok "  mihomo -t" || bad "  mihomo -t: $(tail -2 <<<"$out")"
else echo "skip  mihomo -t (no $MIHOMO)"; fi

# --- "ks set mtu": the real chain (import, rebuild, commit, restart, core_up); only launchd, lsof,
# pf and the core binaries are replaced. The job: $T/job (loaded), its pid in $T/pid; a restart gives a
# new pid; $T/up: the new core listens; $T/kickfail: kickstart fails; $T/refuse: the core's check fails.
ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"
SERVERS_CORE="$DIR/servers-core"; CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; APPROVED_DIRECT="$CORE_DIR/approved-direct"
CORE_EGRESS="$CORE_DIR/egress"; REPORT="$CORE_DIR/routing.json"; CORE_CTL="$CORE_DIR/ctl/mihomo.sock"
mkdir -p "$CORE_DIR/ctl"; : > "$SERVERS_MANUAL"
for b in xray mihomo; do printf '#!/bin/sh\n[ ! -e "%s/refuse" ]\n' "$T" > "$CORE_DIR/$b"; chmod 755 "$CORE_DIR/$b"; done
install() { :; }; pfctl() { cat >/dev/null; }; dscl() { return 0; }; loaded() { return 1; }
vpn_ifaces() { :; }; ts_ifaces() { :; }; xray_observe() { return 1; }; sleep() { :; }
core_api() { echo api >> "$T/calls"; }
launchctl() {
  case "$1" in
    print) [ -e "$T/job" ] || return 1; if [ -e "$T/waiting" ]; then echo 'state = waiting'; else printf 'state = running\npid = %s\n' "$(cat "$T/pid")"; fi ;;
    kickstart) echo kickstart >> "$T/calls"; [ ! -e "$T/kickfail" ] || return 1; echo $(( $(cat "$T/pid") + 1 )) > "$T/pid" ;;
  esac
}
lsof() { [ -e "$T/up" ] && cat "$T/pid"; }
CORE_UP_TRIES=2
kicks() { grep -c kickstart "$T/calls" 2>/dev/null; }
conf_mtu() { if [ "$(core_kind)" = xray ]; then j '(grep { $_->{tag} eq "ks-tun" } @{ $c->{inbounds} })[0]{settings}{mtu}' "$(core_conf)"; else j '$c->{tun}{mtu} // "none"' "$(core_conf)"; fi; }
for core in xray mihomo; do
  printf 'core=%s\n' "$core" > "$SETTINGS"; rm -f "$T/job" "$T/up" "$T/kickfail" "$T/refuse"; : > "$EVENTS"
  if [ "$core" = xray ]; then prof=$fx/xray-panel.json; else prof=$fx/ok-full.json; fi
  core_import "$prof" import >/dev/null 2>"$T/err" || bad "$core: import: $(cat "$T/err")"
  echo 100 > "$T/pid"; : > "$T/job"; : > "$T/up"; : > "$T/calls"
  set_mtu 1380 2>"$T/err" && [ "$(setting mtu auto)" = 1380 ] && [ "$(conf_mtu)" = 1380 ] &&
    ok "$core: set mtu 1380: stored, in the config" || bad "$core set: $(cat "$T/err") $(cat "$SETTINGS")"
  [ "$(kicks)" = 1 ] && ok "  exactly one restart" || bad "  $core restarts: $(paste -sd, - < "$T/calls")"
  grep -qx '.*tunnel MTU: 1380, VPN restarted' "$EVENTS" && ok "  the journal: restarted" || bad "  journal: $(cat "$EVENTS")"
  : > "$T/calls"; : > "$EVENTS"
  set_mtu 1380 >/dev/null 2>&1 && [ "$(kicks)" = 0 ] && [ ! -s "$EVENTS" ] && ok "  the same value again: nothing restarted or logged" ||
    bad "  same value: $(paste -sd, - < "$T/calls") $(cat "$EVENTS")"
  # the core does not come up with the new value: the previous one, its config and a restart back
  cp "$(core_conf)" "$T/conf.before"; rm -f "$T/up"; : > "$T/calls"; : > "$EVENTS"
  if set_mtu 1280 2>"$T/err"; then bad "$core: a core that does not come up: success"; fi
  [ "$(setting mtu auto)" = 1380 ] && cmp -s "$(core_conf)" "$T/conf.before" && [ "$(kicks)" = 2 ] &&
    grep -q 'MTU 1280' "$T/err" && grep -q 'tunnel MTU: 1280 refused, back to 1380' "$EVENTS" &&
    ok "  the core does not come up: back to 1380 and its config, restarted with it, said and logged" ||
    bad "  rollback: $(cat "$T/err") $(setting mtu auto) $(conf_mtu) $(paste -sd, - < "$T/calls") $(cat "$EVENTS")"
  ls "$CORE_DIR" | grep -q '\.prev$' && bad "  .prev files left" || ok "  no copies left"
  # the restart itself fails after the config was put in place: the same way back
  : > "$T/up"; : > "$T/kickfail"; : > "$T/calls"
  if set_mtu auto 2>"$T/err"; then bad "$core: a failed restart: success"; fi
  [ "$(setting mtu auto)" = 1380 ] && cmp -s "$(core_conf)" "$T/conf.before" && grep -q 'MTU' "$T/err" &&
    ok "  the restart fails after the config was put in place: back to 1380 and its config" ||
    bad "  kick fail: $(cat "$T/err") $(setting mtu auto) $(conf_mtu)"
  rm -f "$T/kickfail"
  # a config the core's own check refuses: nothing stored, nothing restarted
  : > "$T/refuse"; : > "$T/calls"
  if set_mtu 1500 2>/dev/null; then bad "$core: a refused config: success"; fi
  [ "$(setting mtu auto)" = 1380 ] && cmp -s "$(core_conf)" "$T/conf.before" && [ "$(kicks)" = 0 ] &&
    ok "  a config the core refuses: the old value kept, nothing restarted" || bad "  refused: $(setting mtu auto) $(kicks)"
  rm -f "$T/refuse"
  # the VPN off (no job): stored and built, nothing restarted, the journal does not say restarted
  rm -f "$T/job"; : > "$T/calls"; : > "$EVENTS"
  set_mtu auto 2>"$T/err" && ! grep -q '^mtu=' "$SETTINGS" && grep -qx "core=$core" "$SETTINGS" && [ "$(kicks)" = 0 ] &&
    grep -qx '.*tunnel MTU: auto' "$EVENTS" && ok "  the VPN off: auto stored, the line gone, no restart, the journal says no restart" ||
    bad "  off: $(cat "$T/err") $(cat "$SETTINGS") $(kicks) $(cat "$EVENTS")"
done
# Xray: a setting the generator changes on the way (a double VPN entry it cannot use goes off,
# ADR 0027) reaches the real settings, so the app tells it; a rollback puts it back with the rest
printf 'core=xray\n' > "$SETTINGS"; rm -f "$T/waiting" "$T/kickfail" "$T/refuse"
core_import "$fx/xray-panel.json" import >/dev/null 2>"$T/err" || bad "xray: import: $(cat "$T/err")"
echo 100 > "$T/pid"; : > "$T/job"; : > "$T/up"; : > "$EVENTS"; put_setting multihop Ghost
set_mtu 1380 2>"$T/err" && [ "$(setting multihop x)" = off ] && grep -q 'double VPN off: its entry «Ghost»' "$EVENTS" &&
  [ "$(stat -f %Lp "$SETTINGS")" = 644 ] && ok "xray: double VPN the build turned off is off in the settings too, logged" ||
  bad "multihop carried: $(cat "$T/err") $(paste -sd, - < "$SETTINGS") $(cat "$EVENTS")"
put_setting multihop Ghost; rm -f "$T/up"
if set_mtu 1280 2>/dev/null; then bad "a core that does not come up: success"; fi
[ "$(setting multihop x)" = Ghost ] && [ "$(setting mtu auto)" = 1380 ] && ok "  a rollback puts the settings back as they were" ||
  bad "  rollback settings: $(paste -sd, - < "$SETTINGS")"
# a "ks set" outside the core lock (lan, wifiguard) while set_mtu builds or restarts (#50): only
# what set_mtu changed goes into the settings and back, the other key stays
: > "$T/up"; real=$SETTINGS
eval "rebuild_orig() $(declare -f core_rebuild | tail -n +2)"
core_rebuild() { put_setting lan 1 "$real"; rebuild_orig "$@"; }
put_setting multihop Ghost
set_mtu 1420 2>"$T/err" && [ "$(setting lan x)" = 1 ] && [ "$(setting mtu auto)" = 1420 ] && [ "$(setting multihop x)" = off ] &&
  ok "  a ks set of another key during the build: kept, mtu and the double VPN still carried" ||
  bad "  concurrent set lost: $(cat "$T/err") $(paste -sd, - < "$SETTINGS")"
eval "core_rebuild() $(declare -f rebuild_orig | tail -n +2)"
eval "restart_orig() $(declare -f core_restart | tail -n +2)"
core_restart() { [ -e "$T/setonce" ] || { : > "$T/setonce"; put_setting wifiguard 1; }; restart_orig; }
put_setting multihop Ghost; rm -f "$T/up" "$T/setonce"
if set_mtu 1280 2>/dev/null; then bad "a core that does not come up: success"; fi
[ "$(setting wifiguard x)" = 1 ] && [ "$(setting lan x)" = 1 ] && [ "$(setting mtu auto)" = 1420 ] && [ "$(setting multihop x)" = Ghost ] &&
  ok "  a ks set of another key during the restart, then a rollback: kept, mtu and the double VPN back" ||
  bad "  concurrent set lost by the rollback: $(paste -sd, - < "$SETTINGS")"
eval "core_restart() $(declare -f restart_orig | tail -n +2)"
: > "$T/up"; drop_setting lan; drop_setting wifiguard; set_mtu 1380 >/dev/null 2>&1 || bad "  back to 1380 for the rest"
# killed after the config was put in place and before the restart: the same value again finishes it
{ ( core_restart() { kill -9 "$BASHPID"; }; set_mtu 1420 ); } 2>/dev/null; : > "$T/calls"
set_mtu 1420 2>"$T/err" && [ "$(setting mtu auto)" = 1420 ] && [ "$(conf_mtu)" = 1420 ] && [ "$(kicks)" = 1 ] &&
  ! ls "$CORE_DIR" "$DIR" | grep -q '\.prev$\|\.mtu' && ok "  an interrupted change: the same value again restarts the core, no copies left" ||
  bad "  interrupted: $(cat "$T/err") $(setting mtu auto) $(kicks) $(ls "$CORE_DIR" "$DIR" | grep '\.prev$')"
# auto and 1500 build the same Xray config: stored, nothing restarted
set_mtu auto 2>/dev/null; : > "$T/calls"; : > "$EVENTS"
set_mtu 1500 2>"$T/err" && [ "$(setting mtu auto)" = 1500 ] && [ "$(kicks)" = 0 ] && grep -qx '.* tunnel MTU: 1500' "$EVENTS" &&
  ok "  auto -> 1500 with Xray: the same config, stored, no restart, the journal says no restart" || bad "  same config: $(kicks) $(cat "$EVENTS")"
# the job loaded but the core not running: restarted, but nothing to wait for, so not «restarted»
: > "$T/waiting"; : > "$T/calls"; : > "$EVENTS"
set_mtu 1380 2>"$T/err" && [ "$(kicks)" = 1 ] && grep -qx '.* tunnel MTU: 1380' "$EVENTS" &&
  ok "  the core was not running: started, the journal does not say restarted" || bad "  not running: $(kicks) $(cat "$EVENTS")"
rm -f "$T/waiting"
# no subscription yet: only stored (the import builds with it)
rm -f "$CORE_DIR"/profile* "$PINS"; printf 'core=xray\n' > "$SETTINGS"; : > "$T/calls"; : > "$T/job"
set_mtu 1420 2>/dev/null && [ "$(setting mtu auto)" = 1420 ] && [ "$(kicks)" = 0 ] && ok "no subscription: stored, nothing restarted" || bad "no profile: $(kicks)"
: > "$T/calls"
for v in 1000 1501 abc "" 1400.5; do
  if set_mtu "$v" 2>/dev/null; then bad "set mtu '$v' accepted"; fi
done
[ ! -s "$T/calls" ] && [ "$(setting mtu auto)" = 1420 ] && ok "anything else refused before anything is touched" || bad "bad values: $(cat "$SETTINGS")"
grep -q 'mtu)' <(declare -f passwordless_args_ok) && bad "mtu is passwordless" || ok "not among the passwordless commands (admin, like other core settings)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
