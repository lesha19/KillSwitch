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

# --- "ks set mtu": checked, stored, the config rebuilt and the core restarted
APPLY_RC=0; core_apply_settings() { echo "apply $(setting mtu auto)" >> "$T/applied"; return "$APPLY_RC"; }
core_restart() { echo restart >> "$T/applied"; }
printf 'core=xray\nmtu=1400\n' > "$SETTINGS"; rm -f "$T/applied"
set_mtu 1380 && [ "$(setting mtu auto)" = 1380 ] && [ "$(paste -sd, - < "$T/applied")" = "apply 1380,restart" ] &&
  ok "set mtu 1380: stored, rebuilt, the core restarted" || bad "set: $(cat "$SETTINGS") $(cat "$T/applied" 2>&1)"
rm -f "$T/applied"
set_mtu auto && ! grep -q '^mtu=' "$SETTINGS" && grep -qx core=xray "$SETTINGS" && [ "$(paste -sd, - < "$T/applied")" = "apply auto,restart" ] &&
  ok "set mtu auto: the line goes, the rest stays" || bad "auto: $(cat "$SETTINGS")"
rm -f "$T/applied"
for v in 1000 1501 abc "" 1400.5; do
  if set_mtu "$v" 2>/dev/null; then bad "set mtu '$v' accepted"; fi
done
[ ! -e "$T/applied" ] && ! grep -q '^mtu=' "$SETTINGS" && ok "anything else refused before anything is touched" || bad "bad values: $(cat "$SETTINGS")"
put_setting mtu 1400; APPLY_RC=1; rm -f "$T/applied"
if set_mtu 1300 2>/dev/null; then bad "a value the core refuses: success"; fi
[ "$(setting mtu auto)" = 1400 ] && ! grep -q restart "$T/applied" && ok "a config that cannot be built: the old value back, nothing restarted" || bad "rollback: $(cat "$SETTINGS")"
APPLY_RC=0
grep -q 'mtu)' <(declare -f passwordless_args_ok) && bad "mtu is passwordless" || ok "not among the passwordless commands (admin, like other core settings)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
