#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Transport escalation with Xray (ADR 0030, issue #20): when the running host stops answering, the
# failover pass (ADR 0023) first tries another TLS fingerprint for the same server, then another
# transport the subscription offers for that same server (another outbound of the host, or another
# host at the same address), then another server of the country. Each step only when the
# observatory saw the alternative answer while the running one did not; what worked is remembered
# per host until the network changes. Nothing new goes past the VPN: the same servers, the same
# DIRECT signature. pfctl, launchctl and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-xray-escalate.sh   (XRAY=/path/to/xray to check the configs for real)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
DIR="$T"; CORE_DIR="$T/core"; mkdir -p "$CORE_DIR"
SETTINGS="$DIR/settings"; EVENTS="$DIR/events.log"; REPORT="$CORE_DIR/routing.json"; DIAG="$T/diag"; mkdir -p "$DIAG"
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$T/c}"; }
# hosts: 0 🇱🇹Литва (the fixture: LT_1 over tcp first, LT_1_FB over xhttp to the same server, both
# Reality with the chrome fingerprint), 1 🇱🇹Литва 2 (another address), 2 🇱🇹Литва XHTTP (the
# fixture's server with LT_1_FB first: the same server, another transport), 3 🇩🇪Германия;
# $1: perl run on $a after
hosts() { /usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $c = JSON::PP->new;
  my $b = $c->decode($c->encode($a->[0])); $b->{remarks} = "🇱🇹Литва 2"; $_->{settings}{vnext}[0]{address} = "203.0.113.11" for @{ $b->{outbounds} }[0, 1];
  my $x = $c->decode($c->encode($a->[0])); $x->{remarks} = "🇱🇹Литва XHTTP"; @{ $x->{outbounds} }[0, 1] = @{ $x->{outbounds} }[1, 0];
  my $d = $c->decode($c->encode($a->[0])); $d->{remarks} = "🇩🇪Германия"; $_->{settings}{vnext}[0]{address} = "de.example.com" for @{ $d->{outbounds} }[0, 1];
  push @$a, $b, $x, $d; eval $ARGV[0]; die $@ if $@; print JSON::PP->new->encode($a)' "${1:-}" < "$fx/xray-panel.json" > "$T/p.json"; }
gen() { core_generate_xray "$T/p.json" "$T/c" "$T/s" 2>"$T/err"; }
xtest() {
  if [ -x "$XRAY" ]; then
    if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
    else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
  else echo "skip  $1: xray run -test (no $XRAY)"; fi
}
tags() { j 'join ",", map { $_->{tag} } grep { $_->{tag} =~ /\Aks-ping-0-/ } @{ $c->{outbounds} }'; }
out_of() { T1=$1 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o'; }
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }

# --- the config: probes of the running host's alternatives, only what the subscription offers
hosts
put_setting escalate 0; gen || bad "escalate=0 refused: $(cat "$T/err")"
cp "$T/c.direct" "$T/direct.off"; cp "$T/c.egress" "$T/egress.off"; cp "$T/s" "$T/servers.off"
[ -z "$(tags)" ] && [ "$(j 'exists $c->{servers}[0]{variants} ? 1 : 0' "$T/c.report")" = 0 ] &&
  ok "escalate=0: no probes of alternatives, nothing in the report" || bad "escalate=0: $(tags)"
drop_setting escalate; gen || bad "escalate on refused: $(cat "$T/err")"
[ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari,ks-ping-0-t1 ] &&
  ok "on by default: the running host's server with two other fingerprints, and its other transport" || bad "variants: $(tags)"
[ "$(j 'scalar grep { $_->{tag} =~ /\Aks-ping-[1-9]-/ } @{ $c->{outbounds} }')" = 0 ] && ok "  for the running host only" || bad "  others: $(j '[map { $_->{tag} } @{ $c->{outbounds} }]')"
[ "$(j 'my ($o) = grep { $_->{tag} eq "ks-ping-0-fp-firefox" } @{ $c->{outbounds} }; my ($l) = grep { $_->{tag} eq "LT_1" } @{ $c->{outbounds} };
  $o = { %$o, tag => "" }; $l = JSON::PP->new->decode(JSON::PP->new->encode({ %$l, tag => "" })); $l->{streamSettings}{realitySettings}{fingerprint} = "firefox";
  JSON::PP->new->canonical->encode($o) eq JSON::PP->new->canonical->encode($l) ? "same" : "differs"')" = same ] &&
  ok "  a fingerprint probe: the running server (pinned) with nothing but the fingerprint changed" || bad "  fp probe: $(out_of ks-ping-0-fp-firefox)"
[ "$(j 'my ($o) = grep { $_->{tag} eq "ks-ping-0-t1" } @{ $c->{outbounds} }; my ($l) = grep { $_->{tag} eq "LT_1_FB" } @{ $c->{outbounds} };
  JSON::PP->new->canonical->encode({ %$o, tag => "" }) eq JSON::PP->new->canonical->encode({ %$l, tag => "" }) ? "same" : "differs"')" = same ] &&
  ok "  a transport probe: a copy of the host's other outbound to the same server (xhttp)" || bad "  transport probe: $(out_of ks-ping-0-t1)"
[ "$(j 'scalar grep { my $r = $_; grep { !ref && /ks-ping/ } values %$r } @{ $c->{routing}{rules} }')" = 0 ] &&
  ok "  no rule leads to them: they carry probes only" || bad "  a rule to a probe"
[ "$(j 'JSON::PP->new->canonical->encode($c->{servers}[0]{variants})' "$T/c.report")" = \
  '[{"kind":"fingerprint","tag":"ks-ping-0-fp-firefox","value":"firefox"},{"kind":"fingerprint","tag":"ks-ping-0-fp-safari","value":"safari"},{"kind":"transport","outbound":"LT_1_FB","tag":"ks-ping-0-t1","value":"xhttp"}]' ] &&
  ok "report: the running host's alternatives" || bad "report variants: $(j '$c->{servers}[0]' "$T/c.report")"
[ "$(j 'join "|", map { "$_->{name}=" . ($_->{transport} // "") . "@" . ($_->{endpoint} // "") } @{ $c->{servers} }' "$T/c.report")" = \
  "🇱🇹Литва=tcp@0|🇱🇹Литва 2=tcp@1|🇱🇹Литва XHTTP=xhttp@0|🇩🇪Германия=tcp@3" ] && [ "$(j '$c->{servers}[0]{fingerprint}' "$T/c.report")" = chrome ] &&
  ok "  each host's transport and server (the first host at its address), the running one's fingerprint" || bad "  servers: $(j '$c->{servers}' "$T/c.report")"
cmp -s "$T/c.direct" "$T/direct.off" && cmp -s "$T/c.egress" "$T/egress.off" && cmp -s "$T/s" "$T/servers.off" &&
  ok "  the DIRECT signature, egress and the servers for pf are the same as without (KS-10)" || bad "  direct/egress/servers changed"
xtest "the probes of alternatives" "$T/c"
hosts '$_->{streamSettings}{security} = "none", delete $_->{streamSettings}{realitySettings} for @{ $a->[0]{outbounds} }[0, 1]'
gen && [ "$(tags)" = ks-ping-0-t1 ] && ok "no TLS on the server: no fingerprint to change, the transport only" || bad "no tls: $(cat "$T/err") $(tags)"
hosts '$a->[0]{outbounds} = [ grep { $_->{tag} ne "LT_1_FB" } @{ $a->[0]{outbounds} } ]'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "one transport in the host: none other is invented" || bad "one transport: $(tags)"
hosts '$a->[0]{outbounds}[1]{settings}{vnext}[0]{address} = "203.0.113.99"'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "another outbound to another server: not a transport of this one" || bad "other address: $(tags)"
hosts '$a->[0]{outbounds}[0]{proxySettings} = { tag => "LT_1_FB" }'
gen && [ "$(tags)" = "" ] && ok "the server reached through another outbound: nothing to escalate (no probe of its own either)" || bad "chained: $(cat "$T/err") $(tags)"

# --- what worked is remembered per host ($CORE_DIR/escalation) and built into the config
MEM="$CORE_DIR/escalation"
hosts; gen; cp "$T/c" "$T/c.plain"
printf 'net=en0 192.168.1.1\n🇱🇹Литва\tfp\tfirefox\n' > "$MEM"
gen || bad "fp memory refused: $(cat "$T/err")"
[ "$(T1=LT_1 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = firefox ] &&
  [ "$(T1=ks-ping-0 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = firefox ] &&
  ok "a fingerprint that worked: the running server and its probe use it" || bad "fp memory: $(out_of LT_1)"
[ "$(tags)" = ks-ping-0-fp-chrome,ks-ping-0-fp-safari,ks-ping-0-t1 ] && [ "$(j '$c->{servers}[0]{fingerprint}' "$T/c.report")" = firefox ] &&
  ok "  the alternatives now: the subscription's own first, then another" || bad "  alternatives: $(tags)"
[ "$(T1=LT_1_FB j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = chrome ] &&
  ok "  the host's other outbound keeps its own" || bad "  LT_1_FB: $(out_of LT_1_FB)"
cmp -s "$T/c.direct" "$T/direct.off" && cmp -s "$T/s" "$T/servers.off" && ok "  DIRECT and servers unchanged" || bad "  direct changed"
xtest "another fingerprint" "$T/c"
printf 'net=en0 192.168.1.1\n🇱🇹Литва\tlead\tLT_1_FB\n🇱🇹Литва 2\tlead\tLT_1_FB\n' > "$MEM"
gen || bad "lead memory refused: $(cat "$T/err")"
[ "$(j 'join ",", map { $_->{tag} } @{ $c->{outbounds} }[0, 1]')" = LT_1_FB,LT_1 ] &&
  [ "$(j 'my ($r) = grep { ref $_->{inboundTag} && $_->{inboundTag}[0] eq "ks-fetch" } @{ $c->{routing}{rules} }; $r->{outboundTag}')" = LT_1_FB ] &&
  ok "another transport that worked: that outbound first (what no rule takes), the fetch through it" || bad "lead: $(j '[map { $_->{tag} } @{ $c->{outbounds} }]')"
[ "$(out_of ks-ping-0 | j '$c->{streamSettings}{network}' /dev/stdin)" = xhttp ] && [ "$(out_of ks-ping-1 | j '$c->{streamSettings}{network}' /dev/stdin)" = xhttp ] &&
  [ "$(out_of ks-ping-0-t1 | j '$c->{streamSettings}{network}' /dev/stdin)" = tcp ] &&
  ok "  the probes follow: each host's own on what it uses, the alternative now tcp" || bad "  probes: $(tags)"
[ "$(j '$c->{servers}[0]{transport} . " " . $c->{servers}[1]{transport}' "$T/c.report")" = "xhttp xhttp" ] && ok "  report: the transport in use" || bad "  report transport"
cmp -s "$T/c.direct" "$T/direct.off" && cmp -s "$T/s" "$T/servers.off" && cmp -s "$T/c.egress" "$T/egress.off" && ok "  DIRECT, egress and servers unchanged" || bad "  direct changed"
xtest "another transport first" "$T/c"
printf 'net=x\n🇱🇹Литва\tfp\tevil\n🇱🇹Литва\tlead\tdirect\n🇱🇹Литва\tlead\tLT_1\n🇱🇹Литва\tport\t1\nбез табуляции\n' > "$MEM"
gen && cmp -s "$T/c" "$T/c.plain" && ok "a fingerprint not on the list, a direct or unknown outbound, other keys: ignored" || bad "bad memory: $(cat "$T/err") $(diff <(j '$c' "$T/c.plain") <(j '$c') | head -5)"
printf 'net=x\n🇱🇹Литва\tfp\tfirefox\n' > "$MEM"; put_setting escalate 0; gen
[ "$(T1=LT_1 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = chrome ] &&
  ok "escalate=0: the memory is not used" || bad "memory with escalate=0"
drop_setting escalate; rm -f "$MEM"

# --- the observatory's answer: the alternatives' probes are read too
/usr/bin/perl -e 'sub vi { my $v = shift; my $o = ""; while ($v >= 128) { $o .= chr(($v & 127) | 128); $v >>= 7 } $o . chr($v) }
  sub f { my ($n, $s) = @_; vi($n * 8 + 2) . vi(length $s) . $s }
  my @st = map { vi(8) . vi(1) . vi(16) . vi(60) . f(4, $_) } qw(ks-ping-0-fp-firefox ks-ping-0-t1 ks-ping-0-x LT_1);
  my $m = f(1, join "", map { f(1, $_) } @st); print "\0", pack("N", length $m), $m' | observe_decode > "$T/obs"
[ "$(cut -f1 "$T/obs" | paste -sd' ' -)" = "ks-ping-0-fp-firefox ks-ping-0-t1" ] &&
  ok "observatory reply: the alternatives' probes read, nothing else" || bad "decoded: $(cat -t "$T/obs")"

# --- the failover pass: fingerprint, then transport, then another server of the country
core_job() { CORE_RUN=1; CORE_PID=100; }
PROBE="0 0"; diag_probe() { echo "$PROBE"; }
primary_iface() { echo en0; }
NETSIG="en0 192.168.1.1"; net_sig() { echo "$NETSIG"; }
OBS=""; xray_observe() { [ -n "$OBS" ] && printf '%s\n' "$OBS"; }
xray_select() {
  echo "$1" >> "$T/selected"; put_setting xrayserver "$1"
  /usr/bin/perl -MJSON::PP -e 'local $/; my $r = JSON::PP->new->decode(<STDIN>); $r->{selected} = $ARGV[0]; print JSON::PP->new->encode($r)' "$1" < "$REPORT" > "$REPORT.n" &&
    mv "$REPORT.n" "$REPORT"
}
REBUILD_RC=0
core_rebuild() { echo "rebuild ${2:-}" >> "$T/rebuilt"; cp "$MEM" "$T/mem.at-rebuild" 2>/dev/null; return "$REBUILD_RC"; }
reload_if_on() { :; }; core_reload() { :; }
hosts; gen; cp "$T/c.report" "$T/report.lt"
reset_esc() { rm -f "$CORE_DIR/failover" "$T/selected" "$T/rebuilt" "$MEM" "$DIAG"/events-*.jsonl; : > "$EVENTS"; cp "$T/report.lt" "$REPORT"
  put_setting core xray; put_setting xrayserver "🇱🇹Литва"; drop_setting escalate; drop_setting failover; PROBE="0 0"; NOW=1000000; }
pass() { failover_pass "$NOW"; NOW=$((NOW + 20)); }
mem() { grep -v '^net=' "$MEM" 2>/dev/null | paste -sd'|' -; }
# the running host dead, as its firefox probe; safari and its xhttp answer; so do the others
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-firefox\t0\t0\nks-ping-0-fp-safari\t1\t80\nks-ping-0-t1\t1\t50\nks-ping-1\t1\t30\nks-ping-2\t1\t40\nks-ping-3\t1\t20'
reset_esc
pass; pass
[ ! -e "$T/rebuilt" ] && ok "two failed probes: nothing yet" || bad "stepped after 2"
pass
[ "$(mem)" = "🇱🇹Литва	fp	safari" ] && [ "$(cat "$T/rebuilt" 2>/dev/null)" = "rebuild switch" ] && [ ! -e "$T/selected" ] &&
  ok "3 failed: first another fingerprint for the same server (the one whose probe answers), the server picked by hand kept" ||
  bad "fp step: mem '$(mem)' rebuilt $(cat "$T/rebuilt" 2>&1) selected $(cat "$T/selected" 2>&1)"
grep -q 'escalate (no answer): 🇱🇹Литва fingerprint chrome -> safari$' "$EVENTS" && ok "  events.log: escalate … fingerprint chrome -> safari" || bad "  events: $(cat "$EVENTS")"
grep -q '"ev":"escalate","server":"🇱🇹Литва","kind":"fingerprint","from":"chrome","to":"safari"' "$DIAG"/events-*.jsonl &&
  ok "  the diagnostics journal: an escalate event" || bad "  journal: $(cat "$DIAG"/events-*.jsonl 2>&1)"
grep -qx "net=$NETSIG" "$MEM" && ok "  the memory is tied to this network" || bad "  net: $(cat "$MEM")"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ "$(wc -l < "$T/rebuilt")" -eq 1 ] && ok "  still failing: no next step within 3 minutes" || bad "  steps too fast: $(cat "$T/rebuilt")"
pass
[ "$(mem)" = "🇱🇹Литва	lead	LT_1_FB" ] && [ ! -e "$T/selected" ] &&
  ok "then another transport the host offers for the same server (the fingerprint found for the old one forgotten)" || bad "transport step: '$(mem)'"
grep -q 'escalate (no answer): 🇱🇹Литва transport tcp -> xhttp$' "$EVENTS" && ok "  events.log: escalate … transport tcp -> xhttp" || bad "  events: $(cat "$EVENTS")"
for _ in 1 2 3 4 5 6 7 8 9; do pass; done
[ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва XHTTP" ] &&
  ok "then another server: a host at the same address first, though a farther one answers faster" || bad "server step: $(cat "$T/selected" 2>&1)"
grep -q 'failover (no answer, same server): 🇱🇹Литва -> 🇱🇹Литва XHTTP$' "$EVENTS" && ok "  events.log: failover (no answer, same server)" || bad "  events: $(cat "$EVENTS")"
[ "$(wc -l < "$T/rebuilt")" -eq 2 ] && ok "  each step once: no fingerprint or transport again for that host in the same outage" || bad "  rebuilt: $(cat "$T/rebuilt")"

reset_esc; put_setting escalate 0
pass; pass; pass
[ ! -e "$T/rebuilt" ] && [ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] &&
  ok "escalate=0: the server switch of ADR 0023 at once (the fastest of the country)" || bad "escalate off: $(cat "$T/selected" 2>&1) $(cat "$T/rebuilt" 2>&1)"

reset_esc; put_setting failover 0
for _ in $(seq 1 30); do pass; done
[ "$(wc -l < "$T/rebuilt")" -eq 2 ] && [ ! -e "$T/selected" ] && ! grep -q 'failover' "$EVENTS" &&
  ok "failover=0: fingerprint and transport of the same server still tried, the server never left" || bad "failover off: $(cat "$T/rebuilt" 2>&1) $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"

OBS=$'ks-ping-0\t1\t90\nks-ping-0-fp-firefox\t1\t80\nks-ping-0-fp-safari\t1\t80\nks-ping-0-t1\t1\t50\nks-ping-1\t1\t30\nks-ping-2\t1\t40'
reset_esc; pass; pass; pass
[ ! -e "$T/rebuilt" ] && [ -e "$T/selected" ] &&
  ok "its own probe answers while the requests fail: not the fingerprint or transport, another server as before" || bad "lead alive: $(cat "$T/rebuilt" 2>&1)"

OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-firefox\t0\t0\nks-ping-0-fp-safari\t0\t0\nks-ping-0-t1\t0\t0\nks-ping-1\t1\t30\nks-ping-2\t0\t0'
reset_esc; pass; pass; pass
[ ! -e "$T/rebuilt" ] && [ "$(cat "$T/selected" 2>/dev/null)" = "🇱🇹Литва 2" ] &&
  ok "no alternative answers (the address blocked): straight to another server, as fast as before" || bad "all dead: $(cat "$T/selected" 2>&1) $(cat "$T/rebuilt" 2>&1)"

OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80'
reset_esc; pass; pass; pass
PROBE="90 1"; pass
PROBE="0 0"; for _ in $(seq 1 9); do pass; done
[ "$(wc -l < "$T/rebuilt")" -eq 2 ] && ok "an answer in between ends the outage: the fingerprint may be tried again later" || bad "episode: $(cat "$T/rebuilt")"

reset_esc; REBUILD_RC=1
printf 'net=%s\n🇱🇹Литва 2\tfp\tfirefox\n' "$NETSIG" > "$MEM"
pass; pass; pass
[ "$(mem)" = "🇱🇹Литва 2	fp	firefox" ] && grep -q 'escalate failed: 🇱🇹Литва fingerprint chrome -> safari, kept$' "$EVENTS" &&
  ok "a step whose config cannot be built: the memory as it was, logged" || bad "failed step: '$(mem)' $(cat "$EVENTS")"
REBUILD_RC=0

# --- a new network: what worked is forgotten (another network may block something else)
reset_esc
printf 'net=wi-fi 10.0.0.1\n🇱🇹Литва\tfp\tfirefox\n' > "$MEM"
PROBE="90 1"; pass
[ "$(cat "$MEM")" = "net=$NETSIG" ] && [ "$(cat "$T/rebuilt" 2>/dev/null)" = "rebuild switch" ] &&
  grep -q 'escalate reset (network changed)$' "$EVENTS" &&
  ok "network changed: memory cleared, the config rebuilt as in the subscription, logged" || bad "net change: $(cat "$MEM") $(cat "$T/rebuilt" 2>&1) $(cat "$EVENTS")"
pass
[ "$(wc -l < "$T/rebuilt")" -eq 1 ] && ok "  once" || bad "  again: $(cat "$T/rebuilt")"
reset_esc; PROBE="90 1"; pass
[ "$(cat "$MEM")" = "net=$NETSIG" ] && [ ! -e "$T/rebuilt" ] && [ ! -s "$EVENTS" ] &&
  ok "nothing remembered: a new network is noted, nothing rebuilt" || bad "empty memory: $(cat "$MEM") $(cat "$T/rebuilt" 2>&1)"

# --- slow is not a reason to change the fingerprint or the transport
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80\nks-ping-1\t1\t30'
reset_esc; put_setting xrayserver ""; PROBE="100 1"
for _ in 1 2 3 4 5 6; do pass; done
PROBE="450 1"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ ! -e "$T/rebuilt" ] && ok "slow (auto host): no fingerprint or transport step" || bad "slow tuned: $(cat "$T/rebuilt")"

# --- the setting
printf 'escalate=0\nescalate=1\n' > "$T/set"
settings_lines_ok "$T/set" && ok "settings: escalate=0|1 is ours" || bad "escalate line refused"
echo escalate=2 > "$T/set"
settings_lines_ok "$T/set" && bad "escalate=2 accepted" || ok "settings: escalate=2 refused"
core_lock_wanted set escalate && ok "ks set escalate runs under the core lock (it rebuilds)" || bad "set escalate not locked"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
