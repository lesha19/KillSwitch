#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Ping and automatic server failover with Xray (ADR 0023): every host of the subscription gets a
# probe-only outbound ks-ping-<n> that the observatory watches, "ks core delay" and "ks core
# proxies" read it through the stats API's ObservatoryService, and the watchdog's failover pass
# moves to the fastest live host of the same country after 3 failed probes in a row or 2 minutes
# at more than 3× the usual latency. pfctl, launchctl and DNS are replaced here, nothing is loaded.
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
  ok "no observatory in the subscription: ours (the URL the failover groups of mihomo check)" || bad "observatory: $(j '$c->{observatory}')"
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
hosts '$a->[1]{outbounds} = [ grep { $_->{protocol} !~ /vless/ } @{ $a->[1]{outbounds} } ];
  unshift @{ $a->[2]{routing}{rules} }, { domain => ["domain:example.org"], outboundTag => "direct" }'
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
put_setting xrayserver "🇩🇪Германия"; gen; de=$(sha "$T/c.direct")
put_setting xrayserver ""; gen; lt=$(sha "$T/c.direct")
: > "$EVENTS"
KS_APPROVE_ALL=1 gen || bad "approve all: $(cat "$T/err")"
[ "$lt" != "$de" ] && [ "$(sort "$T/c.approved" | paste -sd, -)" = "$(printf '%s\n%s\n' "$lt" "$de" | sort | paste -sd, -)" ] &&
  ok "approval: a host with no server skipped, the hosts after it still approved" || bad "approved: $(cat "$T/c.approved") lt $lt de $de"
grep -q 'approval skipped.*🇱🇹Литва 2' "$EVENTS" && ok "  the skipped host logged" || bad "  events: $(cat "$EVENTS")"
hosts '$a->[1]{outbounds} = [ grep { $_->{protocol} !~ /vless/ } @{ $a->[1]{outbounds} } ]; $a->[1]{remarks} = "Ж" x 100'
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

# --- the failover pass (the watchdog, every 20 s)
core_job() { CORE_RUN=1; CORE_PID=100; }
PROBE="90 1"
diag_probe() { echo "$PROBE"; }
NET=en0; primary_iface() { echo "$NET"; }
xray_select() {
  echo "$1" >> "$T/selected"; put_setting xrayserver "$1"
  /usr/bin/perl -MJSON::PP -e 'local $/; my $r = JSON::PP->new->decode(<STDIN>); $r->{selected} = $ARGV[0]; print JSON::PP->new->encode($r)' "$1" < "$REPORT" > "$REPORT.n" &&
    mv "$REPORT.n" "$REPORT"
}
reset_fo() { rm -f "$CORE_DIR"/failover* "$T/selected" "$DIAG"/events-*.jsonl; : > "$EVENTS"; cp "$T/c.report" "$REPORT"; put_setting xrayserver "🇱🇹Литва"; }
pass() { failover_pass "$NOW"; NOW=$((NOW + 20)); }
OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'
reset_fo; NOW=1000000
for _ in 1 2 3 4 5; do pass; done
[ ! -e "$T/selected" ] && ok "answering probes: no switch (the observatory's view of the host does not decide)" || bad "switched on good probes: $(cat "$T/selected")"
PROBE="0 0"; pass; pass
[ ! -e "$T/selected" ] && ok "two failed probes: no switch yet" || bad "switched after 2"
PROBE="90 1"; pass; PROBE="0 0"; pass; pass
[ ! -e "$T/selected" ] && ok "fail, fail, answer, fail, fail: no switch (3 in a row needed)" || bad "switched without 3 in a row"
pass
[ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] &&
  ok "3 failed probes in a row: switched to the live host of the same country (not the faster one abroad)" || bad "switch: $(cat "$T/selected" 2>&1)"
grep -q 'failover (no answer): 🇱🇹Литва -> 🇱🇹Литва 2$' "$EVENTS" && ok "  events.log: failover (no answer): from -> to" || bad "  events: $(cat "$EVENTS")"
grep -q '"ev":"failover","from":"🇱🇹Литва","to":"🇱🇹Литва 2","reason":"no-answer"' "$DIAG"/events-*.jsonl &&
  ok "  the diagnostics journal: a failover event" || bad "  journal: $(cat "$DIAG"/events-*.jsonl 2>&1)"
OBS=$'ks-ping-0\t1\t50\nks-ping-1\t0\t0\nks-ping-2\t1\t30'
PROBE="0 0"; pass; pass; pass; pass; pass; pass
[ "$(wc -l < "$T/selected")" -eq 1 ] && ok "  then not again within 3 minutes" || bad "  flapping: $(cat "$T/selected")"
pass; pass; pass
[ "$(tail -1 "$T/selected")" = "🇱🇹Литва" ] && ok "  later, still failing: back to the first one, alive again" || bad "  second switch: $(cat "$T/selected")"

OBS=$'ks-ping-0\t0\t0\nks-ping-1\t0\t0\nks-ping-2\t1\t30'
reset_fo; PROBE="0 0"
for _ in 1 2 3 4 5 6; do pass; done
[ ! -e "$T/selected" ] && ok "every host of the country dead: stays (another country is never picked by itself)" || bad "switched abroad: $(cat "$T/selected")"
[ "$(grep -c 'failover (no answer): 🇱🇹Литва, no live server of its country' "$EVENTS")" = 1 ] &&
  ok "  logged once while it lasts" || bad "  nolive lines: $(cat "$EVENTS")"
PROBE="90 1"; pass; PROBE="0 0"; pass; pass; pass
[ "$(grep -c 'no live server' "$EVENTS")" = 2 ] && ok "  and again after it answered in between" || bad "  nolive again: $(cat "$EVENTS")"

OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'
reset_fo; put_setting multihop "🇱🇹Литва 2"; PROBE="0 0"
for _ in 1 2 3 4; do pass; done
[ ! -e "$T/selected" ] && ok "double VPN (ADR 0027): the entry host is never failover's new exit (that would be one hop)" || bad "switched to the entry: $(cat "$T/selected")"
# the entry dead: every exit is unreachable through it, moving the exit would only churn
OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t0\t0'
reset_fo; put_setting multihop "🇩🇪Германия"; PROBE="0 0"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do pass; done
[ ! -e "$T/selected" ] && ok "  the entry's own probe dead: no failover at all (the exit stays the person's)" || bad "churned with a dead entry: $(cat "$T/selected")"
OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'
reset_fo; PROBE="0 0"
for _ in 1 2 3 4; do pass; done
[ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] && ok "  the entry alive: the exit still fails over" || bad "  entry alive: $(cat "$T/selected" 2>&1)"
put_setting multihop off
# own servers (ADR 0027) route differently from the subscription's hosts: never a failover target
reset_fo
/usr/bin/perl -MJSON::PP -e 'local $/; my $r = JSON::PP->new->decode(<STDIN>); $r->{servers}[1]{name} = "🇱🇹Литва 2 (свой)"; print JSON::PP->new->encode($r)' < "$REPORT" > "$REPORT.n" && mv "$REPORT.n" "$REPORT"
PROBE="0 0"; for _ in 1 2 3 4; do pass; done
[ ! -e "$T/selected" ] && ok "an own server («(свой)») is never failover's target" || bad "switched to an own server: $(cat "$T/selected")"

OBS=$'ks-ping-0\t1\t100\nks-ping-1\t1\t110\nks-ping-2\t1\t30'
reset_fo; put_setting xrayserver ""; PROBE="100 1"   # no server picked by hand: the first host, auto
for _ in 1 2 3 4 5 6; do pass; done
PROBE="450 1"
for _ in 1 2 3 4 5 6; do pass; done
[ ! -e "$T/selected" ] && ok "latency above 3× the usual for less than 2 minutes: stays" || bad "slow switch too early: $(cat "$T/selected")"
pass
[ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] && grep -q 'failover (slow): 🇱🇹Литва -> 🇱🇹Литва 2$' "$EVENTS" &&
  ok "auto (no pick by hand): more than 3× the usual latency for 2 minutes: switched to a faster host of the country" || bad "slow: $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"
grep -q '"reason":"slow","ms":450,"usual":100' "$DIAG"/events-*.jsonl && ok "  the journal has the latency and the usual one" || bad "  journal: $(cat "$DIAG"/events-*.jsonl)"
OBS=$'ks-ping-0\t1\t100\nks-ping-1\t1\t400\nks-ping-2\t1\t30'
reset_fo; put_setting xrayserver ""; PROBE="100 1"
for _ in 1 2 3 4 5 6; do pass; done
PROBE="450 1"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ ! -e "$T/selected" ] && grep -q 'failover (slow): 🇱🇹Литва, no faster server of its country' "$EVENTS" &&
  ok "slow, but the other host of the country is no faster: stays, logged" || bad "slow no faster: $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"

# --- a server picked by hand is respected: never left for being slow, only when it is dead
OBS=$'ks-ping-0\t1\t100\nks-ping-1\t1\t110\nks-ping-2\t1\t30'
reset_fo; PROBE="100 1"   # xrayserver=🇱🇹Литва: picked by hand
for _ in 1 2 3 4 5 6; do pass; done
PROBE="450 1"
for _ in $(seq 1 12); do pass; done
[ ! -e "$T/selected" ] && [ ! -s "$EVENTS" ] && ok "picked by hand and slow: stays, nothing logged" || bad "slow manual: $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"
PROBE="0 0"; pass; pass; pass
[ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] && ok "  picked by hand and dead (3 failures): moved" || bad "  dead manual: $(cat "$T/selected" 2>&1)"
PROBE="100 1"; for _ in 1 2 3 4 5 6 7 8 9 10; do pass; done
PROBE="450 1"; for _ in $(seq 1 8); do pass; done
[ "$(tail -1 "$T/selected")" = "🇱🇹Литва" ] && ok "  the host failover moved to is not a pick by hand: slow moves on from it" || bad "  after failover: $(cat "$T/selected")"

# --- a pick by hand («ks core select») starts over: no failover from it within the cooldown
OBS=$'ks-ping-0\t1\t100\nks-ping-1\t1\t110\nks-ping-2\t1\t30'
reset_fo; put_setting xrayserver ""; PROBE="0 0"
pass; pass
KS_NOW=$NOW core_select "$XRAY_GROUP" "🇱🇹Литва" 2>"$T/err" || bad "select: $(cat "$T/err")"
grep -qx 'manual=🇱🇹Литва' "$CORE_DIR/failover" && grep -qx 'fails=0' "$CORE_DIR/failover" && grep -qx "last=$NOW" "$CORE_DIR/failover" &&
  ok "select by hand: the failover state starts over, the pick remembered, the cooldown from now" || bad "state: $(cat "$CORE_DIR/failover")"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ "$(cat "$T/selected")" = "🇱🇹Литва" ] && ok "  dead right after the pick: kept for 3 minutes" || bad "  moved within the cooldown: $(cat "$T/selected")"
pass; pass
[ "$(tail -1 "$T/selected")" = "🇱🇹Литва 2" ] && ok "  still dead after them: moved" || bad "  after the cooldown: $(cat "$T/selected")"

# --- a pick by hand and a failover switch at the same moment: one after the other, the pick last
cat > "$T/run.sh" <<'EOF'
. "$KS"
DIR=$T; CORE_DIR=$T/core; SETTINGS=$T/settings; EVENTS=$T/events.log; REPORT=$T/core/routing.json; DIAG=$T/diag
core_job() { CORE_RUN=1; CORE_PID=100; }
diag_probe() { echo "0 0"; }
primary_iface() { echo en0; }
xray_observe() { printf 'ks-ping-0\t0\t0\nks-ping-1\t1\t110\nks-ping-2\t1\t30\n'; }
xray_select() { echo "start $1" >> "$T/order"; sleep 1; put_setting xrayserver "$1"
  /usr/bin/perl -MJSON::PP -e 'local $/; my $r = JSON::PP->new->decode(<STDIN>); $r->{selected} = $ARGV[0]; print JSON::PP->new->encode($r)' "$1" < "$REPORT" > "$REPORT.n" &&
    mv "$REPORT.n" "$REPORT"; echo "end $1" >> "$T/order"; }
case $1 in
  failover) failover_pass 2000000 ;;
  select) KS_NOW=2000001 core_select "$XRAY_GROUP" "🇩🇪Германия" ;;
esac
EOF
both() {  # both <first> <second>: the second starts while the first holds the lock
  rm -f "$T/order"; cp "$T/c.report" "$REPORT"; put_setting xrayserver "🇱🇹Литва"
  printf 'server=🇱🇹Литва\nfails=2\nlast=0\nmanual=\n' > "$CORE_DIR/failover"
  export T KS="$here/../ks"
  core_lock_exec "$(lock_wait "$1")" bash "$T/run.sh" "$1" & sleep 0.4
  core_lock_exec "$(lock_wait "$2")" bash "$T/run.sh" "$2" 2>"$T/lock.err"; wait
}
lock_wait() { if [ "$1" = failover ]; then echo 0; else echo 120; fi; }   # failover_bg and the dispatcher
core_lock_wanted core select && ! core_lock_wanted core delay && ok "ks core select runs under the core lock (like import, refresh, _regen)" || bad "select not locked"
grep -q 'core_lock_exec 0 "\$0" _failover' <(declare -f failover_bg) && ok "  the watchdog's failover pass under the same lock, never waiting" || bad "  failover_bg: $(declare -f failover_bg)"
both failover select
[ "$(paste -sd, - < "$T/order")" = "start 🇱🇹Литва 2,end 🇱🇹Литва 2,start 🇩🇪Германия,end 🇩🇪Германия" ] && [ "$(setting xrayserver "")" = "🇩🇪Германия" ] &&
  ok "failover switching, then a pick by hand: it waits, one restart after the other, the pick wins" || bad "order: $(cat "$T/order")"
both select failover
[ "$(paste -sd, - < "$T/order")" = "start 🇩🇪Германия,end 🇩🇪Германия" ] && [ "$(setting xrayserver "")" = "🇩🇪Германия" ] &&
  ok "a pick by hand switching, then the failover pass: skipped, the pick stays" || bad "order: $(cat "$T/order")"

# --- a host whose name the settings would call damaged (over 256 bytes, control characters) is
# never a failover target: writing it would make the watchdog block everything
OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'
reset_fo; PROBE="0 0"
long="🇱🇹$(printf 'x%.0s' $(seq 1 300))"
L=$long /usr/bin/perl -MJSON::PP -i -0pe '$r = JSON::PP->new->decode($_); $r->{servers}[1]{name} = $ENV{L}; $_ = JSON::PP->new->encode($r)' "$REPORT"
pass; pass; pass
[ ! -e "$T/selected" ] && grep -q 'no live server of its country' "$EVENTS" && ok "a same-country host with a name over 256 bytes: not a failover target" ||
  bad "long name: $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"

# --- the Mac without a network (no primary interface): the probe fails for that reason, not the
# server's; nothing counted, so a local outage does not abandon a server picked by hand
OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'
reset_fo; PROBE="0 0"; NET=""
for _ in $(seq 1 10); do pass; done
[ ! -e "$T/selected" ] && [ ! -s "$EVENTS" ] && ok "no network: no switch, nothing logged" || bad "offline: $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"
NET=en0; pass; pass
[ ! -e "$T/selected" ] && ok "  back online: failures while offline not counted" || bad "  counted offline: $(cat "$T/selected")"
pass
[ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] && ok "  then 3 failures online: moved" || bad "  online: $(cat "$T/selected" 2>&1)"

OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'
reset_fo; put_setting failover 0; PROBE="0 0"
for _ in 1 2 3 4 5; do pass; done
[ ! -e "$T/selected" ] && [ ! -s "$EVENTS" ] && ok "failover=0 (the setting off): nothing" || bad "failover off: $(cat "$T/selected" 2>&1)"
put_setting failover 1
reset_fo; core_job() { CORE_RUN=0; CORE_PID=""; }
for _ in 1 2 3 4 5; do pass; done
[ ! -e "$T/selected" ] && ok "core not running: nothing" || bad "switched with the core down"
core_job() { CORE_RUN=1; CORE_PID=100; }
reset_fo; put_setting core mihomo
for _ in 1 2 3 4 5; do pass; done
[ ! -e "$T/selected" ] && ok "mihomo: nothing (its fallback groups do it, ADR 0005)" || bad "failover pass with mihomo"
put_setting core xray
reset_fo; xray_select() { return 1; }
for _ in 1 2 3; do pass; done
grep -q 'failover failed: 🇱🇹Литва -> 🇱🇹Литва 2' "$EVENTS" && ok "a switch that fails: logged, the running config stays" || bad "failed switch: $(cat "$EVENTS")"
# ADR 0023: the state follows the switch only once it happened; a refused one (KS-10, exit 3)
# leaves the server picked by hand a pick by hand, and that server is not tried again for 30
# minutes (ADR 0030 review: not every cooldown)
grep -qx 'server=🇱🇹Литва' "$CORE_DIR/failover" && grep -qx 'manual=🇱🇹Литва' "$CORE_DIR/failover" &&
  ok "  the failed switch: still the hand-picked server, still a pick by hand" || bad "  state: $(cat "$CORE_DIR/failover")"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ "$(grep -c 'failover failed' "$EVENTS")" = 1 ] && ok "  not tried again within 3 minutes" || bad "  retries: $(cat "$EVENTS")"
pass
[ "$(grep -c 'failover failed' "$EVENTS")" = 1 ] && ok "  nor after them: that server is skipped 30 minutes" || bad "  after cooldown: $(cat "$EVENTS")"
NOW=$((NOW + 1800)); pass; pass; pass
[ "$(grep -c 'failover failed' "$EVENTS")" = 2 ] && ok "  tried again after 30 minutes" || bad "  after 30 min: $(cat "$EVENTS")"
OBS=$'ks-ping-0\t1\t100\nks-ping-1\t1\t110\nks-ping-2\t1\t30'
seen=$(grep -c 'failover' "$EVENTS")
PROBE="100 1"; for _ in 1 2 3 4 5 6; do pass; done
PROBE="450 1"; for _ in $(seq 1 12); do pass; done
[ "$(grep -c 'failover' "$EVENTS")" = "$seen" ] && ok "  later slow: the hand-picked server is not left for being slow" || bad "  slow after failed switch: $(cat "$EVENTS")"
reset_fo; xray_select() { echo "$1" >> "$T/selected"; return 0; }
OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t120\nks-ping-2\t1\t30'; PROBE="0 0"
pass; pass; pass
grep -qx 'server=🇱🇹Литва 2' "$CORE_DIR/failover" && grep -qx 'manual=' "$CORE_DIR/failover" &&
  ok "a switch that worked: the new server in the state, not a pick by hand" || bad "state after switch: $(cat "$CORE_DIR/failover")"

# --- the watchdog starts it every 20 s, only while the core runs and the protection is on
calls=0
failover_bg() { calls=$((calls + 1)); }
guard() { :; }; core_guard() { :; }; publish_state() { :; }; diag_tick() { :; }; diag_bg() { :; }; netbird_bg() { :; }
CORE_STATE=on; PROT=on; STANDBY=0
for i in $(seq 0 59); do watch_pass "$i"; done
[ "$calls" = 3 ] && ok "watchdog: a failover pass every 20 s" || bad "watchdog calls: $calls"
calls=0; PROT=off; for i in $(seq 0 59); do watch_pass "$i"; done
STANDBY=1; PROT=on; for i in $(seq 0 59); do watch_pass "$i"; done
CORE_STATE=off; STANDBY=0; for i in $(seq 0 59); do watch_pass "$i"; done
[ "$calls" = 0 ] && ok "  none while the protection is off, in standby next to another VPN, or the core is down" || bad "  calls: $calls"

# --- the setting
printf 'failover=0\nfailover=1\n' > "$T/set"
settings_lines_ok "$T/set" && ok "settings: failover=0|1 is ours" || bad "failover line refused"
echo failover=2 > "$T/set"
settings_lines_ok "$T/set" && bad "failover=2 accepted" || ok "settings: failover=2 refused"

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
