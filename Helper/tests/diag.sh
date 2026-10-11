#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The local diagnostics journal of Helper/ks (ADR 0021): Xray's stats API and access log, the
# per-minute metrics, the events the watchdog notices, rotation and «Собрать отчёт» with its
# redaction. No root, no network: launchctl, curl, scutil and the core are stand-ins.
#   Helper/tests/diag.sh   (XRAY=/path/to/xray to check configs with "xray run -test")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; SETTINGS="$tmp/settings"; EVENTS="$tmp/events.log"; STATEF="$tmp/daemon-state"
SERVERS="$tmp/servers"; SERVERS_MANUAL="$tmp/servers-manual"; SERVERS_CORE="$tmp/core/servers-core"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"; PINS="$CORE_DIR/pins"; APPROVED_HOSTS="$CORE_DIR/approved-hosts"
CORE_PROFILE="$CORE_DIR/profile.json"; REPORT="$CORE_DIR/routing.json"; FOREIGN_VPN="$CORE_DIR/foreign-vpn"; CORE_EGRESS="$CORE_DIR/egress"
DIAG="$tmp/diag"
resolve_host() { case "$1" in lt.example.com) echo 203.0.113.40 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$tmp/c}"; }
gen() { core_generate_xray "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
xtest() {  # xtest <name> <config>
  if [ -x "$XRAY" ]; then
    if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
    else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
  else echo "skip  $1: xray run -test (no $XRAY)"; fi
}

# --- Xray: counters through the stats API, on loopback only
gen "$fx/xray-panel.json" || bad "panel config refused: $(cat "$tmp/err")"
[ "$(j '$c->{api}{listen}')" = "127.0.0.1:$CORE_API_PORT" ] && [ "$(j 'join ",", @{ $c->{api}{services} }')" = StatsService ] &&
  ok "api: StatsService only, on 127.0.0.1:$CORE_API_PORT" || bad "api: $(j '$c->{api}')"
[ "$(j 'ref $c->{stats}')" = HASH ] && ok "stats: on" || bad "stats: $(j '$c->{stats}')"
[ "$(j 'join ",", map { "$_=" . ($c->{policy}{system}{$_} ? 1 : 0) } sort keys %{ $c->{policy}{system} }')" = \
  "statsInboundDownlink=1,statsInboundUplink=1,statsOutboundDownlink=1,statsOutboundUplink=1" ] &&
  ok "policy: system counters for inbounds and outbounds" || bad "policy system: $(j '$c->{policy}{system}')"
[ "$(j '$c->{policy}{levels}{0}{connIdle}')" = 600 ] && ok "policy: the subscription's levels kept" || bad "policy levels: $(j '$c->{policy}')"
[ "$(j '$c->{log}{access}')" = none ] && ok "diagnostics off (default): no access log" || bad "access: $(j '$c->{log}')"
xtest "stats api" "$tmp/c"
cp "$fx/xray-panel.json" "$tmp/p.json"
/usr/bin/perl -MJSON::PP -i -0pe '$a = JSON::PP->new->decode($_); delete $_->{policy} for @$a; $_ = JSON::PP->new->encode($a)' "$tmp/p.json"
gen "$tmp/p.json" && [ "$(j '$c->{policy}{system}{statsInboundUplink} ? 1 : 0')" = 1 ] && ok "policy: added when the subscription has none" ||
  bad "no policy: $(j '$c->{policy}')"

# --- «Подробная диагностика»: every connection in diag/access.log, only when on
echo diag=1 > "$SETTINGS"
gen "$fx/xray-panel.json" && [ "$(j '$c->{log}{access}')" = none ] && ok "diag=1 without the diag folder: no access log (Xray would not start)" ||
  bad "no folder: $(j '$c->{log}')"
mkdir "$DIAG"
gen "$fx/xray-panel.json" && [ "$(j '$c->{log}{access}')" = "$DIAG/access.log" ] && [ "$(j '$c->{log}{loglevel}')" = warning ] &&
  ok "diag=1: access log in the diag folder, error log unchanged" || bad "verbose: $(j '$c->{log}')"
xtest "access log" "$tmp/c"
echo diag=0 > "$SETTINGS"
gen "$fx/xray-panel.json" && [ "$(j '$c->{log}{access}')" = none ] && ok "diag=0: no access log" || bad "diag=0: $(j '$c->{log}')"
rm -f "$SETTINGS"
settings_lines_ok <(printf 'diag=1\ndiag=0\n') && ok "settings: diag=0|1 is ours" || bad "settings: diag refused"
settings_lines_ok <(printf 'diag=verbose\n') && bad "settings: diag=verbose taken" || ok "settings: other diag values are not"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
