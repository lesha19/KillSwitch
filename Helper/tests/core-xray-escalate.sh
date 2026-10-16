#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Transport escalation with Xray (ADR 0030, issue #20): when the running host stops answering, the
# watchdog's escalation pass first tries another TLS fingerprint for the same server, then another
# transport the host offers for that same server (another outbound of the host). The server itself
# is never left (ADR 0036: no automatic server replacement). Each step only when the observatory
# saw the alternative answer while the running one did not; what worked is remembered per host
# until the network changes. Nothing new goes past the VPN: the same servers, the same DIRECT
# signature. pfctl, launchctl and DNS are replaced here, nothing is loaded.
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
drop_setting() { grep -v "^$1=" "$SETTINGS" > "$SETTINGS.d" 2>/dev/null; mv "$SETTINGS.d" "$SETTINGS"; }   # back to the default

# --- the config: probes of the running host's alternatives, only while it is failing (armed by
# the escalation pass: "<host>\tprobe" in the memory), only what the subscription offers
MEM="$CORE_DIR/escalation"
arm() { printf 'net=en0 192.168.1.1\n🇱🇹Литва\tprobe\t1\t1000000\n%s' "${1:-}" > "$MEM"; }
hosts
put_setting escalate 0; arm; gen || bad "escalate=0 refused: $(cat "$T/err")"
cp "$T/c.direct" "$T/direct.off"; cp "$T/c.egress" "$T/egress.off"; cp "$T/s" "$T/servers.off"
[ -z "$(tags)" ] && [ "$(j 'exists $c->{servers}[0]{variants} || exists $c->{servers}[0]{escalable} ? 1 : 0' "$T/c.report")" = 0 ] &&
  ok "escalate=0: no probes of alternatives, nothing in the report (the memory not read)" || bad "escalate=0: $(tags)"
drop_setting escalate; rm -f "$MEM"; gen || bad "escalate on refused: $(cat "$T/err")"
[ -z "$(tags)" ] && [ "$(j '$c->{servers}[0]{escalable}' "$T/c.report")" = 3 ] && [ "$(j 'exists $c->{servers}[0]{variants} ? 1 : 0' "$T/c.report")" = 0 ] &&
  ok "on, the server answering: no extra probes (no extra handshakes), the report says 3 alternatives exist" || bad "unarmed: $(tags) $(j '$c->{servers}[0]' "$T/c.report")"
[ "$(j '$c->{servers}[0]{lead}' "$T/c.report")" = LT_1 ] && ok "  and which outbound leads" || bad "  lead: $(j '$c->{servers}[0]' "$T/c.report")"
arm; gen || bad "armed refused: $(cat "$T/err")"
[ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari,ks-ping-0-t1 ] &&
  ok "armed: the running host's server with two other fingerprints, and its other transport" || bad "variants: $(tags)"
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
put_setting multihop "🇩🇪Германия"; gen || bad "double VPN refused: $(cat "$T/err")"
[ "$(j 'join ",", map { $_->{tag} . "=" . ($_->{streamSettings}{sockopt}{dialerProxy} // "-") } grep { $_->{tag} =~ /\Aks-ping-0-/ } @{ $c->{outbounds} }')" = \
  "ks-ping-0-fp-firefox=ks-entry,ks-ping-0-fp-safari=ks-entry,ks-ping-0-t1=ks-entry" ] &&
  ok "double VPN (ADR 0027): the alternatives' probes go through the entry too, never straight to the exit" ||
  bad "double VPN probes: $(j '[map { [$_->{tag}, $_->{streamSettings}{sockopt}{dialerProxy}] } @{ $c->{outbounds} }]')"
xtest "the probes of alternatives through the entry" "$T/c"
put_setting multihop off
hosts '$_->{streamSettings}{security} = "none", delete $_->{streamSettings}{realitySettings} for @{ $a->[0]{outbounds} }[0, 1]'
gen && [ "$(tags)" = ks-ping-0-t1 ] && ok "no TLS on the server: no fingerprint to change, the transport only" || bad "no tls: $(cat "$T/err") $(tags)"
hosts '$a->[0]{outbounds} = [ grep { $_->{tag} ne "LT_1_FB" } @{ $a->[0]{outbounds} } ]'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "one transport in the host: none other is invented" || bad "one transport: $(tags)"
hosts '$a->[0]{outbounds}[1]{settings}{vnext}[0]{address} = "203.0.113.99"'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "another outbound to another server: not a transport of this one" || bad "other address: $(tags)"
hosts '$a->[0]{outbounds}[0]{proxySettings} = { tag => "LT_1_FB" }'
gen && [ "$(tags)" = "" ] && [ "$(j '$c->{servers}[0]{escalable}' "$T/c.report")" = 0 ] &&
  ok "the server reached through another outbound: nothing to escalate (no probe of its own either)" || bad "chained: $(cat "$T/err") $(tags)"
# xHTTP with a separate download server: that address is not checked like the servers' (the
# hardening branch handles it in the parser); the ladder never probes nor picks such an outbound
hosts '$a->[0]{outbounds}[1]{streamSettings}{xhttpSettings}{downloadSettings} = { address => "198.51.100.7", port => 443, network => "xhttp" }'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "an outbound with an xHTTP download server: never an alternative" || bad "download: $(cat "$T/err") $(tags)"
hosts '$a->[0]{outbounds}[1]{streamSettings}{xhttpSettings}{extra}{downloadSettings} = { address => "198.51.100.7", port => 443 }'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "  also when it is under extra" || bad "  extra download: $(tags)"
hosts '$a->[0]{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings} = { address => "198.51.100.7", port => 443 }'
gen && [ "$(tags)" = "" ] && [ "$(j '$c->{servers}[0]{escalable}' "$T/c.report")" = 0 ] &&
  ok "  the running server itself with one: nothing escalated, nothing copied" || bad "  lead download: $(tags)"
hosts '$a->[0]{outbounds}[1]{tag} = "LT\t1"; $a->[0]{routing}{balancers} = []'
gen && [ "$(tags)" = ks-ping-0-fp-firefox,ks-ping-0-fp-safari ] && ok "an outbound tag with a tab: never an alternative (it would shift the pass's fields)" || bad "tab tag: $(cat "$T/err") $(tags)"

# --- what worked is remembered per host ($CORE_DIR/escalation) and built into the config
hosts; rm -f "$MEM"; gen; cp "$T/c" "$T/c.plain"
arm '🇱🇹Литва	fp	firefox	1000000
'
gen || bad "fp memory refused: $(cat "$T/err")"
[ "$(T1=LT_1 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = firefox ] &&
  [ "$(T1=ks-ping-0 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = firefox ] &&
  ok "a fingerprint that worked: the running server and its probe use it" || bad "fp memory: $(out_of LT_1)"
[ "$(tags)" = ks-ping-0-fp-chrome,ks-ping-0-fp-safari,ks-ping-0-t1 ] && [ "$(j '$c->{servers}[0]{fingerprint}' "$T/c.report")" = firefox ] &&
  ok "  the alternatives now: the subscription's own first, then another" || bad "  alternatives: $(tags)"
[ "$(j 'join ",", map { $_->{tag} } grep { $_->{original} } @{ $c->{servers}[0]{variants} }' "$T/c.report")" = ks-ping-0-fp-chrome ] &&
  ok "  the subscription's own way marked as the original (to go back once it works again)" || bad "  original: $(j '$c->{servers}[0]{variants}' "$T/c.report")"
[ "$(T1=LT_1_FB j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}')" = chrome ] &&
  ok "  the host's other outbound keeps its own" || bad "  LT_1_FB: $(out_of LT_1_FB)"
cmp -s "$T/c.direct" "$T/direct.off" && cmp -s "$T/s" "$T/servers.off" && ok "  DIRECT and servers unchanged" || bad "  direct changed"
xtest "another fingerprint" "$T/c"
arm '🇱🇹Литва	lead	LT_1_FB	1000000
🇱🇹Литва 2	lead	LT_1_FB	1000000
'
gen || bad "lead memory refused: $(cat "$T/err")"
[ "$(j 'join ",", map { $_->{tag} } @{ $c->{outbounds} }[0, 1]')" = LT_1_FB,LT_1 ] &&
  [ "$(j 'my ($r) = grep { ref $_->{inboundTag} && $_->{inboundTag}[0] eq "ks-fetch" } @{ $c->{routing}{rules} }; $r->{outboundTag}')" = LT_1_FB ] &&
  ok "another transport that worked: that outbound first (what no rule takes), the fetch through it" || bad "lead: $(j '[map { $_->{tag} } @{ $c->{outbounds} }]')"
[ "$(out_of ks-ping-0 | j '$c->{streamSettings}{network}' /dev/stdin)" = xhttp ] && [ "$(out_of ks-ping-1 | j '$c->{streamSettings}{network}' /dev/stdin)" = xhttp ] &&
  [ "$(out_of ks-ping-0-t1 | j '$c->{streamSettings}{network}' /dev/stdin)" = tcp ] &&
  ok "  the probes follow: each host's own on what it uses, the alternative now tcp" || bad "  probes: $(tags)"
[ "$(j 'join ",", map { $_->{tag} } grep { $_->{original} } @{ $c->{servers}[0]{variants} }' "$T/c.report")" = ks-ping-0-t1 ] &&
  ok "  the original: the subscription's first outbound" || bad "  original: $(j '$c->{servers}[0]{variants}' "$T/c.report")"
[ "$(j '$c->{servers}[0]{transport} . " " . $c->{servers}[1]{transport}' "$T/c.report")" = "xhttp xhttp" ] && ok "  report: the transport in use" || bad "  report transport"
cmp -s "$T/c.direct" "$T/direct.off" && cmp -s "$T/s" "$T/servers.off" && cmp -s "$T/c.egress" "$T/egress.off" && ok "  DIRECT, egress and servers unchanged" || bad "  direct changed"
xtest "another transport first" "$T/c"
# a balancer with a direct member (Remnawave's fallbackTag direct): its members keep the
# subscription's order, so the DIRECT signature does not move when another outbound leads
hosts '$_->{routing}{balancers}[0]{fallbackTag} = "direct" for @$a'
rm -f "$MEM"; gen; cp "$T/c.direct" "$T/direct.bal"
arm '🇱🇹Литва	lead	LT_1_FB	1000000
'
gen && [ "$(j 'join ",", map { $_->{tag} } @{ $c->{outbounds} }[0, 1]')" = LT_1_FB,LT_1 ] && grep -q direct "$T/c.direct" && cmp -s "$T/c.direct" "$T/direct.bal" &&
  ok "a balancer with a direct member: the same DIRECT signature with another outbound first (no refused step)" || bad "balancer order: $(diff "$T/direct.bal" "$T/c.direct")"
# three outbounds to the same server: LT_1 tcp, LT_1_FB xhttp, LT_2 tcp on another port. Once
# LT_1_FB leads, LT_2 (tcp) is its other transport; a remembered LT_2 is built in
hosts 'my $l2 = JSON::PP->new->decode(JSON::PP->new->encode($a->[0]{outbounds}[0])); $l2->{tag} = "LT_2"; $l2->{settings}{vnext}[0]{port} = 8443;
  splice @{ $a->[0]{outbounds} }, 2, 0, $l2'
arm '🇱🇹Литва	lead	LT_1_FB	1000000
'
gen && [ "$(j 'join ",", map { $_->{outbound} // $_->{value} } @{ $c->{servers}[0]{variants} }' "$T/c.report")" = firefox,safari,LT_1,LT_2 ] &&
  ok "LT_1, LT_1_FB, LT_2: with LT_1_FB first, LT_2 and the original LT_1 are its alternatives" || bad "three: $(cat "$T/err") $(j '$c->{servers}[0]{variants}' "$T/c.report")"
arm '🇱🇹Литва	lead	LT_2	1000000
'
gen && [ "$(j 'join ",", map { $_->{tag} } @{ $c->{outbounds} }[0 .. 2]')" = LT_2,LT_1_FB,LT_1 ] && [ "$(j '$c->{servers}[0]{lead}' "$T/c.report")" = LT_2 ] &&
  ok "  a remembered LT_2 (same server, same network as the original): built in, not ignored" || bad "  lead LT_2: $(j '[map { $_->{tag} } @{ $c->{outbounds} }]')"
hosts; rm -f "$MEM"
printf 'net=x\n🇱🇹Литва\tfp\tevil\t1\n🇱🇹Литва\tlead\tdirect\t1\n🇱🇹Литва\tlead\tLT_1\t1\n🇱🇹Литва\tport\t1\t1\nбез табуляции\n' > "$MEM"
gen && cmp -s "$T/c" "$T/c.plain" && ok "a fingerprint not on the list, a direct or unknown outbound, other keys: ignored" || bad "bad memory: $(cat "$T/err") $(diff <(j '$c' "$T/c.plain") <(j '$c') | head -5)"
arm '🇱🇹Литва	fp	firefox	1
'; put_setting escalate 0; gen
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

# --- a routing profile with block, proxy and direct entries (#30): its proxy rules go to whichever
# outbound leads, so the transport step must still pass the KS-10 gate (core_rebuild switch) as
# the step's own code does, not be refused as a change of what goes direct. Imported for real, in a
# subshell (its own files), then the step's rebuild with the memory the pass prepared
# (without 🇱🇹Литва XHTTP: its config, LT_1_FB first, would be approved at import for a switch)
hosts '$a->[0]{"x-ks-routing"} = { name => "p", block => { sites => ["domain:ads.example.com"] }, proxy => { sites => ["full:www.example.org"] }, direct => { sites => ["domain:ru"] } };
  splice @$a, 2, 1'
( SERVERS="$T/g/servers"; SERVERS_MANUAL="$T/g/servers-manual"; SERVERS_CORE="$T/g/servers-core"; ALLOW="$T/g/allow"; TSRELAYS="$T/g/none"
  CORE_DIR="$T/g/core"; CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"; APPROVED_HOSTS="$CORE_DIR/approved-hosts"
  APPROVED_DIRECT="$CORE_DIR/approved-direct"; CORE_EGRESS="$CORE_DIR/egress"; REPORT="$CORE_DIR/routing.json"; CORE_PLIST="$T/g/p.plist"
  SETTINGS="$T/g/settings"; mkdir -p "$CORE_DIR/ctl"; : > "$SERVERS_MANUAL"
  printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/xray"; chmod 755 "$CORE_DIR/xray"
  install() { :; }; pfctl() { cat >/dev/null; }; dscl() { return 0; }; vpn_ifaces() { :; }; ts_ifaces() { :; }; loaded() { return 1; }
  launchctl() { return 1; }; sleep() { :; }; xray_observe() { return 1; }
  put_setting core xray
  core_import "$T/p.json" import >/dev/null 2>"$T/g.err" || { echo "import: $(cat "$T/g.err")"; exit 1; }
  printf 'net=en0 192.168.1.1\n🇱🇹Литва\tprobe\t1\t1000000\n🇱🇹Литва\tlead\tLT_1_FB\t1000000\n' > "$CORE_DIR/escalation.next"
  KS_ESC_FILE="$CORE_DIR/escalation.next" core_rebuild "$PINS" switch >/dev/null 2>"$T/g.err" || { echo "rc $?: $(cat "$T/g.err")"; exit 1; }
  [ "$(j '$c->{outbounds}[0]{tag}' "$(core_conf)")" = LT_1_FB ] || { echo "not led by LT_1_FB"; exit 1; }
) > "$T/gate" 2>&1 && ok "a routing profile with block, proxy and direct: the transport step passes the KS-10 gate" || bad "gate: $(cat "$T/gate")"
hosts

# --- the escalation pass: probes armed after 2 failures, then fingerprint, transport; never another server
core_job() { CORE_RUN=1; CORE_PID=100; }
PROBE="0 0"; diag_probe() { echo "$PROBE"; }
primary_iface() { echo en0; }
NETSIG="en0 192.168.1.1"; net_sig() { echo "$NETSIG"; }
OBS=""; xray_observe() { [ -n "$OBS" ] && printf '%s\n' "$OBS"; }
# the real generator, from the settings and the memory the step would use (KS_ESC_FILE); the
# report it writes is what the next pass reads. DIRECT must never change.
regen() {
  core_generate_xray "$T/p.json" "$T/r" "$T/rs" 2>"$T/rerr" || return 1
  cmp -s "$T/r.direct" "$T/direct.run" || echo "$NOW" >> "$T/direct-changes"
  cp "$T/r.report" "$REPORT"
}
REBUILD_RC=0
core_rebuild() { echo "$NOW" >> "$T/rebuilt"; [ "$REBUILD_RC" = 0 ] || return "$REBUILD_RC"; regen; }
REFUSE=""
xray_select() {
  echo "$1" >> "$T/selected"
  [ "$1" != "$REFUSE" ] || return 3
  put_setting xrayserver "$1"; regen
}
reload_if_on() { :; }; core_reload() { :; }
hosts
reset_esc() { rm -f "$CORE_DIR"/escalation* "$T/selected" "$T/rebuilt" "$T/direct-changes" "$DIAG"/events-*.jsonl; : > "$EVENTS"
  put_setting core xray; put_setting xrayserver "🇱🇹Литва"; drop_setting escalate; PROBE="0 0"; NOW=1000000; REBUILD_RC=0; REFUSE=""; STEP=20
  regen; cp "$T/r.direct" "$T/direct.run"; rm -f "$T/direct-changes"; }
pass() { escalate_pass "$NOW"; NOW=$((NOW + ${STEP:-20})); }   # STEP: seconds between passes (20, the watchdog's)
mem() { awk -F'\t' '!/^net=/ { print $1 "\t" $2 "\t" $3 }' "$MEM" 2>/dev/null | sort | paste -sd'|' -; }
rebuilds() { if [ -e "$T/rebuilt" ]; then wc -l < "$T/rebuilt" | tr -d ' '; else echo 0; fi; }
nodirect() { [ ! -e "$T/direct-changes" ]; }
# the running host dead, as its firefox probe; safari and its xhttp answer; so do the others
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-firefox\t0\t0\nks-ping-0-fp-safari\t1\t80\nks-ping-0-t1\t1\t50\nks-ping-1\t1\t30\nks-ping-2\t1\t40\nks-ping-3\t1\t20'
reset_esc
pass
[ "$(rebuilds)" = 0 ] && ok "one failed check: nothing" || bad "stepped after 1"
pass
[ "$(mem)" = "🇱🇹Литва	probe	1" ] && [ "$(rebuilds)" = 1 ] && [ "$(j 'scalar @{ $c->{servers}[0]{variants} }' "$REPORT")" = 3 ] &&
  ok "two in a row, its own probe dead: the alternatives' probes armed (one rebuild; Xray answers for them within a second)" || bad "arm: '$(mem)' $(rebuilds)"
grep -q 'escalate probing: 🇱🇹Литва$' "$EVENTS" && ok "  events.log: escalate probing" || bad "  events: $(cat "$EVENTS")"
pass
[ "$(mem)" = "🇱🇹Литва	fp	safari|🇱🇹Литва	left-fp	chrome|🇱🇹Литва	probe	1" ] && [ "$(rebuilds)" = 2 ] && [ ! -e "$T/selected" ] &&
  ok "3 failed: another fingerprint for the same server (the one whose probe answers), the one left noted, the pick by hand kept" ||
  bad "fp step: mem '$(mem)' rebuilds $(rebuilds) selected $(cat "$T/selected" 2>&1)"
[ "$(T1=LT_1 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}' "$T/r")" = safari ] &&
  ok "  the running config uses it" || bad "  config: $(T1=LT_1 out_of LT_1)"
grep -q 'escalate (no answer): 🇱🇹Литва fingerprint chrome -> safari$' "$EVENTS" && ok "  events.log: escalate … fingerprint chrome -> safari" || bad "  events: $(cat "$EVENTS")"
grep -q '"ev":"escalate","server":"🇱🇹Литва","kind":"fingerprint","from":"chrome","to":"safari"' "$DIAG"/events-*.jsonl &&
  ok "  the diagnostics journal: an escalate event" || bad "  journal: $(cat "$DIAG"/events-*.jsonl 2>&1)"
grep -qx "net=$NETSIG" "$MEM" && ok "  the memory is tied to this network" || bad "  net: $(cat "$MEM")"
# the state the pass prepared (escalation-state.next) is committed once the step ran: the step
# done, the failures and the cooldown start over (PR #70 review)
ST="$CORE_DIR/escalation-state"
grep -qx 'esc=fingerprint' "$ST" && grep -qx 'fails=0' "$ST" && grep -qx "last=$((NOW - 20))" "$ST" && [ ! -e "$ST.next" ] &&
  ok "  the escalation state committed: the step done, failures and cooldown from it" || bad "  state: $(cat "$ST" 2>&1) next: $(cat "$ST.next" 2>&1)"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ "$(rebuilds)" = 2 ] && ok "  still failing: no next step within 3 minutes" || bad "  steps too fast: $(rebuilds)"
pass
[ "$(mem)" = "🇱🇹Литва	lead	LT_1_FB|🇱🇹Литва	left-fp	chrome|🇱🇹Литва	left-lead	LT_1|🇱🇹Литва	probe	1" ] && [ ! -e "$T/selected" ] &&
  ok "then another transport the host offers for the same server (the fingerprint found for the old one forgotten)" || bad "transport step: '$(mem)'"
grep -q 'escalate (no answer): 🇱🇹Литва transport tcp -> xhttp$' "$EVENTS" && ok "  events.log: escalate … transport tcp -> xhttp" || bad "  events: $(cat "$EVENTS")"
for _ in $(seq 1 30); do pass; done
[ ! -e "$T/selected" ] && ! grep -q 'failover' "$EVENTS" &&
  ok "then, still failing: the server is never left (ADR 0036), though a host at the same address and others answer" || bad "server step: $(cat "$T/selected" 2>&1) $(cat "$EVENTS")"
[ "$(rebuilds)" = 3 ] && ok "  each step once: no fingerprint or transport again for that host in the same outage" || bad "  rebuilds: $(rebuilds)"
nodirect && ok "  DIRECT the same in every config of the ladder (real generator)" || bad "  DIRECT changed at $(cat "$T/direct-changes")"

reset_esc; put_setting escalate 0
for _ in $(seq 1 12); do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -e "$T/selected" ] && [ ! -s "$EVENTS" ] &&
  ok "escalate=0: nothing at all" || bad "escalate off: $(cat "$T/selected" 2>&1) $(rebuilds) $(cat "$EVENTS")"

OBS=$'ks-ping-0\t1\t90\nks-ping-1\t1\t30\nks-ping-2\t1\t40'
reset_esc; for _ in $(seq 1 12); do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -e "$T/selected" ] &&
  ok "its own probe answers while the requests fail: nothing armed, no other server" || bad "lead alive: $(rebuilds) $(cat "$T/selected" 2>&1)"
OBS=$'ks-ping-1\t1\t30\nks-ping-2\t1\t40'
reset_esc; for _ in $(seq 1 12); do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -e "$T/selected" ] &&
  ok "no result for its own probe (the observatory after a restart): not taken as dead, nothing armed" || bad "missing own: $(rebuilds)"

OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-firefox\t0\t0\nks-ping-0-fp-safari\t0\t0\nks-ping-0-t1\t0\t0\nks-ping-1\t1\t30\nks-ping-2\t0\t0'
reset_esc; for _ in $(seq 1 12); do pass; done
[ "$(rebuilds)" = 1 ] && [ ! -e "$T/selected" ] &&
  ok "no alternative answers (the address blocked): only the arming, no other server" || bad "all dead: $(cat "$T/selected" 2>&1) $(rebuilds)"

OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80\nks-ping-0-t1\t1\t50\nks-ping-1\t1\t30\nks-ping-3\t0\t0'
reset_esc; put_setting multihop "🇩🇪Германия"; regen; cp "$T/r.direct" "$T/direct.run"
for _ in 1 2 3 4 5 6; do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -e "$T/selected" ] &&
  ok "double VPN with the entry's probe dead: nothing armed, no fingerprint or transport for the exit, no switch" || bad "entry dead: $(rebuilds) $(cat "$T/selected" 2>&1)"
put_setting multihop off

# --- a step that cannot be built: not burned, that variant set aside, the next one tried
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-firefox\t1\t90\nks-ping-0-fp-safari\t1\t80\nks-ping-1\t1\t30'
reset_esc; pass; pass
REBUILD_RC=1; pass
[ "$(mem)" = "🇱🇹Литва	left-fp	safari|🇱🇹Литва	probe	1" ] && grep -q 'escalate failed: 🇱🇹Литва fingerprint chrome -> safari, kept$' "$EVENTS" &&
  [ "$(T1=LT_1 j 'my ($o) = grep { $_->{tag} eq $ENV{T1} } @{ $c->{outbounds} }; $o->{streamSettings}{realitySettings}{fingerprint}' "$T/r")" = chrome ] &&
  ok "a fingerprint step whose config cannot be built: the memory as it was (that one set aside), logged" || bad "failed step: '$(mem)' $(cat "$EVENTS")"
REBUILD_RC=0
for _ in $(seq 1 9); do pass; done
[ "$(mem)" = "🇱🇹Литва	fp	firefox|🇱🇹Литва	left-fp	chrome|🇱🇹Литва	left-fp	safari|🇱🇹Литва	probe	1" ] &&
  ok "  after the cooldown the fingerprint step again, with the other one (the failure did not use the step up)" || bad "  retry: '$(mem)'"

# --- when the pass runs at all: the core up, Xray, a network (a local outage says nothing of the server)
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80'
reset_esc; core_job() { CORE_RUN=0; CORE_PID=""; }
for _ in $(seq 1 6); do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -s "$EVENTS" ] && ok "core not running: nothing" || bad "core down: $(rebuilds)"
core_job() { CORE_RUN=1; CORE_PID=100; }
reset_esc; put_setting core mihomo
for _ in $(seq 1 6); do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -s "$EVENTS" ] && ok "mihomo: nothing" || bad "pass with mihomo: $(rebuilds)"
reset_esc; primary_iface() { :; }
for _ in $(seq 1 10); do pass; done
[ "$(rebuilds)" = 0 ] && [ ! -s "$EVENTS" ] && ok "no network: nothing counted, nothing logged" || bad "offline: $(rebuilds) $(cat "$EVENTS")"
primary_iface() { echo en0; }; pass
[ "$(rebuilds)" = 0 ] && ok "  back online: failures while offline not counted" || bad "  counted offline: $(rebuilds)"

# --- a pick by hand («ks core select») starts over: no step within the 3-minute cooldown from it
reset_esc; pass; pass; pass
KS_NOW=$NOW core_select "$XRAY_GROUP" "🇱🇹Литва 2" 2>"$T/err" || bad "select: $(cat "$T/err")"
grep -qx 'fails=0' "$CORE_DIR/escalation-state" && grep -qx "last=$NOW" "$CORE_DIR/escalation-state" &&
  grep -qx 'server=🇱🇹Литва 2' "$CORE_DIR/escalation-state" &&
  ok "select by hand: the escalation state starts over, the cooldown from now" || bad "state: $(cat "$CORE_DIR/escalation-state")"
core_lock_wanted core select && ! core_lock_wanted core delay && ok "ks core select runs under the core lock (like import, refresh, _regen)" || bad "select not locked"
grep -q 'core_lock_exec 0 "\$0" _escalate' <(declare -f escalate_bg) && ok "  the watchdog's escalation pass under the same lock, never waiting" || bad "  escalate_bg: $(declare -f escalate_bg)"

# --- no ping-pong: a fingerprint just left is not gone back to by a step
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80'
reset_esc; pass; pass; pass
[ "$(mem)" = "🇱🇹Литва	fp	safari|🇱🇹Литва	left-fp	chrome|🇱🇹Литва	probe	1" ] || bad "setup: '$(mem)'"
PROBE="90 1"; pass
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-chrome\t1\t70\nks-ping-0-fp-firefox\t0\t0'
PROBE="0 0"; for _ in $(seq 1 12); do pass; done
[ "$(mem)" = "🇱🇹Литва	fp	safari|🇱🇹Литва	left-fp	chrome|🇱🇹Литва	probe	1" ] &&
  ok "a later outage: not back to the fingerprint just left, though its probe answers" || bad "ping-pong: '$(mem)'"
NOW=$((NOW + 7 * 3600)); PROBE="90 1"; pass; PROBE="0 0"; pass; pass; pass
[ "$(mem)" = "🇱🇹Литва	fp	chrome|🇱🇹Литва	left-fp	safari|🇱🇹Литва	probe	1" ] &&
  ok "  hours later it may be again" || bad "  later: '$(mem)'"

# --- a flaky network (3 failures, an answer, again): at most 3 rebuilds an hour, 10 a day per host
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-chrome\t1\t80\nks-ping-0-fp-firefox\t1\t80\nks-ping-0-fp-safari\t1\t80\nks-ping-0-t0\t1\t50\nks-ping-0-t1\t1\t50\nks-ping-0-t2\t1\t50'
reset_esc
for _ in $(seq 1 36); do PROBE="0 0"; pass; pass; pass; PROBE="90 1"; pass; NOW=$((NOW + 520)); done
hour=$(awk '{ t[NR] = $1 } END { m = 0; for (i = 1; i <= NR; i++) { n = 0; for (k = i; k <= NR; k++) if (t[k] - t[i] < 3600) n++; if (n > m) m = n } print m }' "$T/rebuilt")
[ "$hour" -le 3 ] && [ "$(rebuilds)" -le 10 ] && [ "$(rebuilds)" -ge 3 ] &&
  ok "a flaky network for 6 hours: $(rebuilds) rebuilds, at most $hour in an hour" || bad "flaky: $(rebuilds) rebuilds, $hour in an hour"
nodirect && ok "  DIRECT never changed" || bad "  DIRECT changed"

# --- back to the subscription's way once it works again; the probes off once all is well
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80'
reset_esc; pass; pass; pass
OBS=$'ks-ping-0\t1\t80\nks-ping-0-fp-chrome\t1\t70'
PROBE="90 1"; STEP=60; for _ in $(seq 1 27); do pass; done
[ "$(rebuilds)" = 2 ] && ok "the original's probe answers, but not yet 30 minutes: the fingerprint that worked kept" || bad "early revert: $(rebuilds) '$(mem)'"
for _ in $(seq 1 4); do pass; done; STEP=20
[ "$(mem)" = "" ] && [ "$(rebuilds)" = 3 ] && grep -q 'escalate settled: 🇱🇹Литва$' "$EVENTS" &&
  [ "$(j 'exists $c->{servers}[0]{variants} ? 1 : 0' "$REPORT")" = 0 ] &&
  ok "  30 minutes of answers on the subscription's way: back to it, the probes off, logged" || bad "  revert: $(rebuilds) '$(mem)' $(tail -2 "$EVENTS")"
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80'
reset_esc; pass; pass; pass
OBS=$'ks-ping-0\t1\t80\nks-ping-0-fp-chrome\t0\t0'
PROBE="90 1"; STEP=60; for _ in $(seq 1 70); do pass; done; STEP=20
[ "$(rebuilds)" = 2 ] && [ "$(mem)" = "🇱🇹Литва	fp	safari|🇱🇹Литва	left-fp	chrome|🇱🇹Литва	probe	1" ] &&
  ok "  the original still blocked after an hour: the way that works kept (no daily outage)" || bad "  kept: $(rebuilds) '$(mem)'"
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-firefox\t0\t0\nks-ping-0-fp-safari\t0\t0\nks-ping-0-t1\t0\t0'
reset_esc; pass; pass
OBS=$'ks-ping-0\t1\t80'
PROBE="90 1"; STEP=60; for _ in $(seq 1 15); do pass; done
[ "$(rebuilds)" = 1 ] && ok "armed, nothing changed, answering again: probes kept under 15 minutes" || bad "early off: $(rebuilds)"
pass; STEP=20
[ "$(rebuilds)" = 2 ] && [ "$(mem)" = "" ] && grep -q 'escalate probing off: 🇱🇹Литва$' "$EVENTS" &&
  ok "  after 15 minutes of answers: the extra probes off" || bad "  disarm: $(rebuilds) '$(mem)'"

# --- what other servers remembered expires after a day; the memory never holds a broken line
reset_esc; OBS=$'ks-ping-0\t1\t80'; PROBE="90 1"
printf 'net=%s\n🇱🇹Литва 2\tfp\tfirefox\t%s\n🇩🇪Германия\tfp\tsafari\t%s\n' "$NETSIG" $((NOW - 25 * 3600)) $((NOW - 3600)) > "$MEM"
pass
[ "$(mem)" = "🇩🇪Германия	fp	safari" ] && [ "$(rebuilds)" = 0 ] && ok "another server's memory older than a day: dropped (no rebuild)" || bad "expiry: '$(mem)' $(rebuilds)"
hosts '$a->[0]{remarks} = "🇱🇹Литва\\x"'
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80'
reset_esc; put_setting xrayserver '🇱🇹Литва\x'; regen; pass; pass; pass
grep -qF "$(printf '🇱🇹Литва\\x\tfp\tsafari\t')" "$MEM" && ok "a server name with a backslash: written as it is" || bad "backslash: $(cat -t "$MEM")"
hosts

# --- a new network: what worked is forgotten (another network may block something else)
reset_esc
printf 'net=wi-fi 10.0.0.1\n🇱🇹Литва\tfp\tfirefox\t%s\n' "$NOW" > "$MEM"
PROBE="90 1"; OBS=$'ks-ping-0\t1\t80'; pass
[ "$(cat "$MEM")" = "net=$NETSIG" ] && [ "$(rebuilds)" = 1 ] &&
  grep -q 'escalate reset (network changed)$' "$EVENTS" &&
  ok "network changed: memory cleared, the config rebuilt as in the subscription, logged" || bad "net change: $(cat "$MEM") $(rebuilds) $(cat "$EVENTS")"
pass
[ "$(rebuilds)" = 1 ] && ok "  once" || bad "  again: $(rebuilds)"
reset_esc; PROBE="90 1"; pass
[ "$(cat "$MEM")" = "net=$NETSIG" ] && [ "$(rebuilds)" = 0 ] && [ ! -s "$EVENTS" ] &&
  ok "nothing remembered: a new network is noted, nothing rebuilt" || bad "empty memory: $(cat "$MEM") $(rebuilds)"

# --- slow is not a reason to change the fingerprint or the transport
OBS=$'ks-ping-0\t0\t0\nks-ping-0-fp-safari\t1\t80\nks-ping-1\t1\t30'
reset_esc; put_setting xrayserver ""; PROBE="100 1"
for _ in 1 2 3 4 5 6; do pass; done
PROBE="450 1"
for _ in 1 2 3 4 5 6 7 8; do pass; done
[ "$(rebuilds)" = 0 ] && ok "slow (auto host): nothing armed, no fingerprint or transport step" || bad "slow tuned: $(rebuilds)"

# --- the setting
printf 'escalate=0\nescalate=1\n' > "$T/set"
settings_lines_ok "$T/set" && ok "settings: escalate=0|1 is ours" || bad "escalate line refused"
echo escalate=2 > "$T/set"
settings_lines_ok "$T/set" && bad "escalate=2 accepted" || ok "settings: escalate=2 refused"
core_lock_wanted set escalate && ok "ks set escalate runs under the core lock (it rebuilds)" || bad "set escalate not locked"
# failover (the automatic server switch, gone with ADR 0036): an old line stays harmless until
# install.sh drops it; settings that refused it would block everything
printf 'failover=0\nfailover=1\n' > "$T/set"
settings_lines_ok "$T/set" && ok "settings: an old failover=0|1 line still taken (ignored)" || bad "old failover line refused"
put_setting failover 1; reset_esc; OBS=$'ks-ping-0\t0\t0\nks-ping-1\t1\t30'
for _ in $(seq 1 12); do pass; done
[ ! -e "$T/selected" ] && ok "  failover=1 in the settings: no server switch" || bad "  switched: $(cat "$T/selected")"
drop_setting failover

# --- the watchdog starts the pass every 20 s, only while the core runs and pf blocks (ADR 0035:
# protection on, or the VPN on whatever the switch says)
calls=0
escalate_bg() { calls=$((calls + 1)); }
guard() { :; }; core_guard() { :; }; publish_state() { :; }; diag_tick() { :; }; diag_bg() { :; }; netbird_bg() { :; }
CORE_STATE=on; PROT=on; BLOCKING=1; STANDBY=0
for i in $(seq 0 59); do watch_pass "$i"; done
[ "$calls" = 3 ] && ok "watchdog: an escalation pass every 20 s" || bad "watchdog calls: $calls"
calls=0; PROT=off; for i in $(seq 0 59); do watch_pass "$i"; done
[ "$calls" = 3 ] && ok "  protection off, the VPN on (pf blocks): all the same" || bad "  blocking, protection off: $calls"
calls=0; BLOCKING=0; for i in $(seq 0 59); do watch_pass "$i"; done
STANDBY=1; PROT=on; BLOCKING=1; for i in $(seq 0 59); do watch_pass "$i"; done
CORE_STATE=off; STANDBY=0; for i in $(seq 0 59); do watch_pass "$i"; done
[ "$calls" = 0 ] && ok "  none while nothing is blocked, in standby next to another VPN, or the core is down" || bad "  calls: $calls"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
