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

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
