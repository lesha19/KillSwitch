#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Ping with Xray (ADR 0023): every host of the subscription gets a
# probe-only outbound ks-ping-<n> that the observatory watches, "ks core delay" and "ks core
# proxies" read it through the stats API's ObservatoryService; the watchdog's escalation pass (ADR 0030,
# core-xray-escalate.sh) reads it too. No server is ever switched by itself (ADR 0036).
# pfctl, launchctl and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-xray-ping.sh   (XRAY=/path/to/xray to check the config and the API for real)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
# the probes of the running host's alternatives (ADR 0030) are tested in core-xray-escalate.sh
eval "ks_$(declare -f setting)"; setting() { if [ "$1" = escalate ]; then echo 0; else ks_setting "$@"; fi; }
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
T=$(mktemp -d); XPID=""; HPID=""
trap 'rm -rf "$T"; [ -z "$XPID" ] || kill "$XPID" "$HPID" 2>/dev/null' EXIT
DIR="$T"; CORE_DIR="$T/core"; mkdir -p "$CORE_DIR"
SETTINGS="$DIR/settings"; EVENTS="$DIR/events.log"; REPORT="$CORE_DIR/routing.json"; DIAG="$T/diag"; mkdir -p "$DIAG"
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$T/c}"; }
# hosts: 🇱🇹Литва (the fixture), 🇱🇹Литва 2 (another address), 🇩🇪Германия (by name); $1: perl run on $a after
hosts() { /usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $c = JSON::PP->new;
  my $b = $c->decode($c->encode($a->[0])); $b->{remarks} = "🇱🇹Литва 2"; $_->{settings}{vnext}[0]{address} = "203.0.113.11" for @{ $b->{outbounds} }[0, 1];
  my $d = $c->decode($c->encode($a->[0])); $d->{remarks} = "🇩🇪Германия"; $_->{settings}{vnext}[0]{address} = "de.example.com" for @{ $d->{outbounds} }[0, 1];
  push @$a, $b, $d; eval $ARGV[0]; die $@ if $@; print JSON::PP->new->encode($a)' "${1:-}" < "$fx/xray-panel.json" > "$T/p.json"; }
gen() { core_generate_xray "$T/p.json" "$T/c" "$T/s" 2>"$T/err"; }
xtest() {
  if [ -x "$XRAY" ]; then
    if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
    else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
  else echo "skip  $1: xray run -test (no $XRAY)"; fi
}
pings() { j 'join ",", map { $_->{tag} } grep { $_->{tag} =~ /\Aks-ping-/ } @{ $c->{outbounds} }'; }

# --- the config: a probe-only outbound per host, watched by the observatory
hosts
gen || bad "three hosts refused: $(cat "$T/err")"
[ "$(pings)" = ks-ping-0,ks-ping-1,ks-ping-2 ] && ok "an outbound ks-ping-<n> for every host" || bad "ping outbounds: $(j '[map { $_->{tag} } @{ $c->{outbounds} }]')"
[ "$(j 'join ",", map { $_->{protocol} . ":" . $_->{settings}{vnext}[0]{address} } grep { $_->{tag} =~ /\Aks-ping-/ } @{ $c->{outbounds} }')" = \
  vless:203.0.113.10,vless:203.0.113.11,vless:203.0.113.20 ] &&
  [ "$(j 'my %o = map { $_->{tag} => { %$_, tag => "" } } @{ $c->{outbounds} }; JSON::PP->new->canonical->encode($o{"ks-ping-0"}) eq JSON::PP->new->canonical->encode($o{LT_1}) ? "same" : "differs"')" = same ] &&
  ok "  each a copy of its host's server (the running one's equal to its LT_1), a name pinned to its approved address" || bad "  ping servers: $(j '[grep { $_->{tag} =~ /ks-ping/ } @{ $c->{outbounds} }]' | head -c 600)"
[ "$(j '$c->{outbounds}[0]{tag}')" = LT_1 ] && ok "  the running host's outbounds stay first (what no rule takes)" || bad "  first: $(j '$c->{outbounds}[0]{tag}')"
[ "$(j 'scalar grep { my $r = $_; grep { !ref && /ks-ping/ } values %$r } @{ $c->{routing}{rules} }')" = 0 ] &&
  ok "  no rule leads to them: they carry probes only" || bad "  a rule to ks-ping"
[ "$(j 'join ",", @{ $c->{burstObservatory}{subjectSelector} }')" = LT_,ks-ping- ] && [ "$(j 'exists $c->{observatory} ? 1 : 0')" = 0 ] &&
  ok "the subscription's burstObservatory also watches them (Xray serves one observatory)" || bad "burst: $(j '$c->{burstObservatory}') obs $(j '$c->{observatory}')"
[ "$(j 'join ",", @{ $c->{api}{services} }')" = StatsService,ObservatoryService ] &&
  ok "api: StatsService and the read-only ObservatoryService" || bad "api: $(j '$c->{api}')"
[ "$(j 'join "|", map { "$_->{name}=" . ($_->{ping} // "") } @{ $c->{servers} }' "$T/c.report")" = "🇱🇹Литва=ks-ping-0|🇱🇹Литва 2=ks-ping-1|🇩🇪Германия=ks-ping-2" ] &&
  ok "report: each host's probe outbound" || bad "report servers: $(j '$c->{servers}' "$T/c.report")"
[ "$(j 'scalar grep { $_->{name} =~ /ks-ping/ } @{ $c->{proxies} }' "$T/c.report")" = 0 ] &&
  ok "  not listed as the subscription's proxies" || bad "  proxies: $(j '$c->{proxies}' "$T/c.report")"
[ "$(paste -sd' ' - < "$T/s")" = "203.0.113.10 203.0.113.11 203.0.113.20" ] && ok "servers for pf unchanged: every host was approved already" || bad "servers: $(cat "$T/s")"
xtest "three hosts with probes" "$T/c"
hosts 'delete $_->{burstObservatory} for @$a'
gen || bad "no burst refused: $(cat "$T/err")"
[ "$(j 'join ",", @{ $c->{observatory}{subjectSelector} }')" = ks-ping- ] && [ "$(j '$c->{observatory}{probeUrl}')" = https://cp.cloudflare.com/generate_204 ] &&
  [ "$(j '$c->{observatory}{enableConcurrency} ? 1 : 0')" = 1 ] && [ "$(j 'exists $c->{burstObservatory} ? 1 : 0')" = 0 ] &&
  ok "no observatory in the subscription: ours (the URL mihomo's health checks use)" || bad "observatory: $(j '$c->{observatory}')"
xtest "our observatory" "$T/c"
hosts 'delete $_->{burstObservatory} for @$a; $_->{observatory} = { subjectSelector => ["LT_"], probeInterval => "5m" } for @$a'
gen && [ "$(j 'join ",", @{ $c->{observatory}{subjectSelector} }') $(j '$c->{observatory}{probeInterval}')" = "LT_,ks-ping- 5m" ] &&
  ok "the subscription's observatory: kept, ours added to its subjects" || bad "their observatory: $(j '$c->{observatory}')"
hosts '$a->[1]{outbounds}[0]{proxySettings} = { tag => "LT_1_FB" }'
gen && [ "$(pings)" = ks-ping-0,ks-ping-2 ] && [ "$(j '$c->{servers}[1]{ping} // "none"' "$T/c.report")" = none ] &&
  ok "a host whose server is reached through another outbound: no probe (no latency shown)" || bad "chained: $(cat "$T/err") $(pings)"
touch "$CORE_DIR/api-off"; hosts; gen
[ "$(j 'exists $c->{api} ? 1 : 0')" = 0 ] && [ "$(j 'join ",", @{ $c->{burstObservatory}{subjectSelector} }')" = LT_,ks-ping- ] &&
  ok "stats port taken (api-off): no api, the probes still run" || bad "api-off: $(j '$c->{api}')"
rm -f "$CORE_DIR/api-off"

# --- the import approves every host's DIRECT (KS-10): one host that cannot be built does not
# drop the hosts after it, and is logged
hosts '$a->[1]{outbounds} = [ grep { $_->{protocol} !~ /vless/ } @{ $a->[1]{outbounds} } ]; delete $a->[1]{routing}{balancers};
  unshift @{ $a->[2]{routing}{rules} }, { domain => ["domain:example.org"], outboundTag => "direct" }'
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
put_setting xrayserver "🇩🇪Германия"; gen; de=$(sha "$T/c.direct")
put_setting xrayserver ""; gen; lt=$(sha "$T/c.direct")
: > "$EVENTS"
KS_APPROVE_ALL=1 gen || bad "approve all: $(cat "$T/err")"
[ "$lt" != "$de" ] && [ "$(sort "$T/c.approved" | paste -sd, -)" = "$(printf '%s\n%s\n' "$lt" "$de" | sort | paste -sd, -)" ] &&
  ok "approval: a host with no server skipped, the hosts after it still approved" || bad "approved: $(cat "$T/c.approved") lt $lt de $de"
grep -q 'approval skipped.*🇱🇹Литва 2' "$EVENTS" && ok "  the skipped host logged" || bad "  events: $(cat "$EVENTS")"
hosts '$a->[1]{outbounds} = [ grep { $_->{protocol} !~ /vless/ } @{ $a->[1]{outbounds} } ]; delete $a->[1]{routing}{balancers}; $a->[1]{remarks} = "Ж" x 100'
: > "$EVENTS"; KS_APPROVE_ALL=1 gen
w64=$(printf 'Ж%.0s' $(seq 1 64))
grep -q "skipped (cannot be built): ${w64}\$" "$EVENTS" && iconv -f UTF-8 -t UTF-8 "$EVENTS" >/dev/null 2>&1 &&
  ok "  a long name logged cut to 64 characters, between characters" || bad "  long name: $(cat "$EVENTS")"

# --- the observatory's answer (gRPC GetOutboundStatus), decoded
grpc_frame() {  # the reply the API sends: alive ks-ping-0 at 87 ms, ks-ping-1 dead, someone else's LT_1
  /usr/bin/perl -e 'sub vi { my $v = shift; my $o = ""; while ($v >= 128) { $o .= chr(($v & 127) | 128); $v >>= 7 } $o . chr($v) }
    sub f { my ($n, $s) = @_; vi($n * 8 + 2) . vi(length $s) . $s }
    my @st = (vi(8) . vi(1) . vi(16) . vi(87) . f(3, "") . f(4, "ks-ping-0") . vi(40) . vi(1791722803),
              vi(16) . vi(99999999) . f(3, "dial tcp 203.0.113.11:443: timeout") . f(4, "ks-ping-1"),
              vi(8) . vi(1) . vi(16) . vi(50) . f(4, "LT_1"));
    my $m = f(1, join "", map { f(1, $_) } @st);
    print "\0", pack("N", length $m), $m'
}
grpc_frame | observe_decode > "$T/obs"
[ "$(paste -sd' ' - < "$T/obs")" = "ks-ping-0	1	87 ks-ping-1	0	0" ] &&
  ok "observatory reply: our probes only, alive and latency (no error text, no addresses)" || bad "decoded: $(cat -t "$T/obs")"
printf '' | observe_decode > "$T/obs" && bad "an empty reply decoded" || ok "an empty or broken reply: fails"

# --- what the app asks: delay of the selector or of one host, proxies with the last result
hosts; gen; cp "$T/c.report" "$REPORT"
put_setting core xray
OBS=$'ks-ping-0\t1\t87\nks-ping-1\t0\t0\nks-ping-2\t1\t40'
xray_observe() { [ -n "$OBS" ] && printf '%s\n' "$OBS"; }
[ "$(core_delay "$XRAY_GROUP" | j 'join ",", map { "$_=$c->{$_}" } sort keys %$c' /dev/stdin)" = "🇩🇪Германия=40,🇱🇹Литва=87" ] &&
  ok "delay of «Сервер»: every live host with its latency (mihomo's group answer)" || bad "group delay: $(core_delay "$XRAY_GROUP" 2>&1)"
[ "$(core_delay "🇱🇹Литва" | j '$c->{delay}' /dev/stdin)" = 87 ] && [ "$(core_delay "🇱🇹Литва 2" | j '$c->{delay}' /dev/stdin)" = 0 ] &&
  ok "delay of one host: its latency, 0 when dead (mihomo's proxy answer)" || bad "host delay: $(core_delay "🇱🇹Литва" 2>&1)"
core_delay Nowhere 2>/dev/null && bad "delay of an unknown host answered" || ok "delay of a host not in the subscription: refused"
OBS=""
core_delay "$XRAY_GROUP" 2>"$T/err" && bad "delay without the API answered" || ok "delay with no answer from the API: fails with a reason ($(cat "$T/err"))"
OBS=$'ks-ping-0\t1\t87\nks-ping-1\t0\t0'
p=$(core_proxies)
export G=$XRAY_GROUP
[ "$(j '$c->{proxies}{"🇱🇹Литва"}{history}[-1]{delay} . " " . ($c->{proxies}{"🇱🇹Литва"}{alive} ? 1 : 0) . " " . ($c->{proxies}{"🇱🇹Литва 2"}{alive} ? 1 : 0) . " " . (exists $c->{proxies}{"🇩🇪Германия"}{alive} ? "known" : "unknown")' <(echo "$p"))" = "87 1 0 unknown" ] &&
  ok "proxies: the last probe of each host (latency, alive), nothing for one not probed yet" || bad "proxies: $p"
[ "$(j '$c->{proxies}{$ENV{G}}{now}' <(echo "$p"))" = "🇱🇹Литва" ] && ok "  and the running host as before" || bad "  now: $p"
OBS=""
[ "$(core_proxies | j 'exists $c->{proxies}{"🇱🇹Литва"}{alive} ? 1 : 0' /dev/stdin)" = 0 ] && ok "proxies without the API: the list still comes" || bad "proxies without api"

# --- the real thing: Xray's ObservatoryService answers through curl (h2c gRPC)
if [ -x "$XRAY" ] && command -v python3 >/dev/null; then
  CORE_API_PORT=$((40000 + RANDOM % 20000)); WEB=$((CORE_API_PORT + 1))
  mkdir "$T/www"; ( cd "$T/www" && exec python3 -m http.server "$WEB" --bind 127.0.0.1 ) >/dev/null 2>&1 & HPID=$!
  printf '{"log":{"loglevel":"none"},"api":{"tag":"ks-api","listen":"127.0.0.1:%s","services":["StatsService","ObservatoryService"]},
    "outbounds":[{"tag":"ks-ping-0","protocol":"freedom"},{"tag":"ks-ping-1","protocol":"blackhole"}],
    "observatory":{"subjectSelector":["ks-ping-"],"probeUrl":"http://127.0.0.1:%s/","probeInterval":"1s","enableConcurrency":true}}' \
    "$CORE_API_PORT" "$WEB" > "$T/live.json"
  "$XRAY" run -c "$T/live.json" >/dev/null 2>&1 & XPID=$!
  unset -f xray_observe
  eval "$(sed -n '/^xray_observe() {/,/^}/p' "$here/../ks")"
  out=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; out=$(xray_observe 2>/dev/null | sort | cut -f1,2 | paste -sd' ' -); [ "$out" = "ks-ping-0	1 ks-ping-1	0" ] && break; done
  [ "$out" = "ks-ping-0	1 ks-ping-1	0" ] && ok "Xray $("$XRAY" version | awk 'NR == 1 { print $2 }'): ObservatoryService read through curl (h2c gRPC)" ||
    bad "live observatory: '$out'"
else
  echo "skip  live observatory (no $XRAY or python3)"
fi

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
