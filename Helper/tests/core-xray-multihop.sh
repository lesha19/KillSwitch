#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# «Двойной VPN» with Xray (issue #33, ADR 0027): the entry host's server becomes the outbound
# ks-entry and every server of the running host is dialed through it (sockopt.dialerProxy). Nothing
# new may go past the VPN: the servers for pf, the DIRECT signature and egress stay as without it.
# pfctl, launchctl and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-xray-multihop.sh   (XRAY=/path/to/xray to check the config with "xray run -test")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
# the probes of the running host's alternatives (ADR 0030) are tested in core-xray-escalate.sh
eval "ks_$(declare -f setting)"; setting() { if [ "$1" = escalate ]; then echo 0; else ks_setting "$@"; fi; }
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DIR="$T"; CORE_DIR="$T/core"; mkdir -p "$CORE_DIR/ctl" "$T/ld"
SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; EVENTS="$DIR/events.log"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; SERVERS_CORE="$DIR/servers-core"
CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; APPROVED_DIRECT="$CORE_DIR/approved-direct"
CORE_EGRESS="$CORE_DIR/egress"; REPORT="$CORE_DIR/routing.json"; CORE_PLIST="$T/ld/local.killswitch.core.plist"
printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/xray"; chmod 755 "$CORE_DIR/xray"
printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/mihomo"; chmod 755 "$CORE_DIR/mihomo"
echo '<plist>mihomo</plist>' > "$CORE_DIR/plist.mihomo"; echo '<plist>xray</plist>' > "$CORE_DIR/plist.xray"
install() { :; }
pfctl() { cat >/dev/null; }
launchctl() { return 1; }
loaded() { return 1; }
xray_observe() { return 1; }
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; *) return 1 ;; esac; }
: > "$SERVERS_MANUAL"
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$T/c}"; }
# hosts: 🇱🇹Литва (the fixture) and 🇩🇪Германия (by name); $1: perl run on $a after
hosts() { /usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $c = JSON::PP->new;
  my $d = $c->decode($c->encode($a->[0])); $d->{remarks} = "🇩🇪Германия"; $_->{settings}{vnext}[0]{address} = "de.example.com" for @{ $d->{outbounds} }[0, 1];
  $_->{tag} =~ s/\ALT_/DE_/ for @{ $d->{outbounds} };
  # its balancer too, or its fallback names an outbound it lacks (a host left out, #37)
  for my $b (@{ $d->{routing}{balancers} }) { s/\ALT_/DE_/ for $b->{fallbackTag}, @{ $b->{selector} }; s/\ALT_/DE_/ for map { $_->{match} } @{ $b->{strategy}{settings}{costs} } }
  push @$a, $d; eval $ARGV[0]; die $@ if $@; print JSON::PP->new->encode($a)' "${1:-}" < "$fx/xray-panel.json" > "$T/p.json"; }
gen() { core_generate_xray "$T/p.json" "$T/c" "$T/s" 2>"$T/err"; }
xtest() {
  if [ -x "$XRAY" ]; then
    if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
    else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
  else echo "skip  $1: xray run -test (no $XRAY)"; fi
}
dialers() { j 'join ",", map { "$_->{tag}=" . ($_->{streamSettings}{sockopt}{dialerProxy} // "-") } grep { $_->{protocol} =~ /\A(vless|vmess|trojan|shadowsocks)\z/ } @{ $c->{outbounds} }'; }

# --- the generator
printf 'core=xray\n' > "$SETTINGS"
hosts; gen || bad "two hosts refused: $(cat "$T/err")"
cp "$T/c.direct" "$T/direct.single"; cp "$T/c.egress" "$T/egress.single"; cp "$T/s" "$T/servers.single"
[ "$(dialers)" = "LT_1=-,LT_1_FB=-,ks-ping-0=-,ks-ping-1=-" ] && ok "off: nothing chained" || bad "off: $(dialers)"

printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"
gen || bad "double VPN refused: $(cat "$T/err")"
[ "$(dialers)" = "LT_1=ks-entry,LT_1_FB=ks-entry,ks-ping-0=ks-entry,ks-ping-1=-,ks-entry=-" ] &&
  ok "every server of the running host and every other host's probe go through ks-entry; the entry's own probe does not" || bad "chain: $(dialers)"
[ "$(j 'my ($e) = grep { $_->{tag} eq "ks-entry" } @{ $c->{outbounds} }; "$e->{protocol}:$e->{settings}{vnext}[0]{address}:" . ($e->{streamSettings}{realitySettings}{serverName} // "")')" = "vless:203.0.113.20:www.example.com" ] &&
  ok "  ks-entry: the entry host's first server, its name pinned to the approved address" || bad "  entry: $(j '[grep { $_->{tag} eq "ks-entry" } @{ $c->{outbounds} }]' | head -c 400)"
[ "$(j '$c->{outbounds}[0]{tag}')" = LT_1 ] && ok "  the running host's first outbound stays first (what no rule takes)" || bad "  first: $(j '$c->{outbounds}[0]{tag}')"
[ "$(j 'scalar grep { ($_->{outboundTag} // "") eq "ks-entry" } @{ $c->{routing}{rules} }')" = 0 ] &&
  ok "  no rule sends traffic to the entry alone" || bad "  a rule to ks-entry"
[ "$(j '$c->{routing}{rules}[1]{outboundTag}')" = LT_1 ] && ok "  the fetch inbound goes to a chained server" || bad "  fetch: $(j '$c->{routing}{rules}[1]')"
cmp -s "$T/c.direct" "$T/direct.single" && cmp -s "$T/c.egress" "$T/egress.single" && cmp -s "$T/s" "$T/servers.single" &&
  ok "nothing new past the VPN: servers for pf, DIRECT signature and egress as without it" || bad "differs: $(cat "$T/c.egress") $(cat "$T/s")"
[ "$(j 'join "|", map { $_->{kind} . ":" . join(",", @{ $_->{items} }) } grep { $_->{kind} eq "multihop" } @{ $c->{added} }' "$T/c.report")" = "multihop:🇩🇪Германия" ] &&
  ok "report: «Двойной VPN — твой выбор» with the entry" || bad "report: $(j '$c->{added}' "$T/c.report")"
[ "$(j 'scalar grep { $_->{name} eq "ks-entry" } @{ $c->{proxies} }' "$T/c.report")" = 0 ] && ok "  ks-entry not listed as a proxy of the subscription" || bad "  proxies"
xtest "double VPN" "$T/c"

# the running host is the entry itself (an older pick, or a stale pick falling back to the first
# host): one hop, so double VPN goes off, logged, never «Литва → Литва» on screen
printf 'core=xray\nmultihop=🇩🇪Германия\nxrayserver=🇩🇪Германия\n' > "$SETTINGS"; : > "$EVENTS"
gen && [ "$(dialers)" = "DE_1=-,DE_1_FB=-,ks-ping-0=-,ks-ping-1=-" ] && [ "$(setting multihop x)" = off ] &&
  grep -q 'double VPN off: its entry «🇩🇪Германия»: it is the running server' "$EVENTS" &&
  ok "the entry is the running host: one hop, double VPN off and logged" || bad "entry = exit: $(cat "$T/err") $(dialers) $(setting multihop x)"
: > "$EVENTS"

# an entry the build cannot use (gone from the subscription, a mihomo name from before, chained, a
# tag clash): double VPN goes off, logged, so a refresh or a rebuild never stays refused for it
dropped() {  # dropped <what> [dialers]: built one hop, the setting off, the reason in events.log
  if gen && [ "$(dialers)" = "${2:-LT_1=-,LT_1_FB=-,ks-ping-0=-,ks-ping-1=-}" ] && [ "$(setting multihop x)" = off ] &&
     grep -q "double VPN off" "$EVENTS"; then ok "$1: one hop, double VPN turned off and logged"
  else bad "$1: $(cat "$T/err") $(dialers) multihop=$(setting multihop x) $(tail -1 "$EVENTS" 2>/dev/null)"; fi
  : > "$EVENTS"
}
hosts; printf 'core=xray\nmultihop=🇳🇱Нидерланды\n' > "$SETTINGS"; dropped "an entry not in the subscription"
printf 'core=xray\nmultihop=NL reality\n' > "$SETTINGS"; dropped "a mihomo proxy name from before"
printf 'core=xray\nmultihop=🇱🇹Литва\nxrayserver=🇳🇱Gone\n' > "$SETTINGS"; dropped "a stale pick that falls back to the entry host"
# a server of the running host the subscription sends through a freedom outbound would dial directly
hosts '$a->[0]{outbounds}[1]{proxySettings} = { tag => "direct" }'
printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"; dropped "a server of the exit chained through «direct»"
hosts
hosts '$a->[1]{outbounds}[0]{proxySettings} = { tag => "DE_1_FB" }'
printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"; dropped "an entry reached through another outbound" "LT_1=-,LT_1_FB=-,ks-ping-0=-"
hosts '$a->[0]{outbounds}[2]{tag} = "ks-entry"; $_->{outboundTag} =~ s/\Adirect\z/ks-entry/ for grep { defined $_->{outboundTag} } @{ $a->[0]{routing}{rules} }'
printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"
gen && [ "$(setting multihop x)" = off ] && [ "$(j 'scalar grep { ($_->{streamSettings}{sockopt}{dialerProxy} // "") eq "ks-entry" } @{ $c->{outbounds} }')" = 0 ] &&
  ok "the subscription's own «ks-entry» tag: not overwritten, double VPN off" || bad "tag clash: $(cat "$T/err")"
: > "$EVENTS"
hosts '$a->[0]{outbounds}[1]{proxySettings} = { tag => "LT_1" }'
printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"
gen && [ "$(dialers)" = "LT_1=ks-entry,LT_1_FB=-,ks-ping-0=ks-entry,ks-ping-1=-,ks-entry=-" ] &&
  ok "a server the subscription reaches through another one is chained through that one" || bad "own chain: $(cat "$T/err") $(dialers)"
# null or "" in proxySettings / dialerProxy is no chain for Xray, nor for ks (as the probes read it)
hosts '$a->[0]{outbounds}[1]{streamSettings}{sockopt}{dialerProxy} = ""; $a->[1]{outbounds}[0]{proxySettings} = undef;
  $a->[1]{outbounds}[0]{streamSettings}{sockopt}{dialerProxy} = undef'
printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"; : > "$EVENTS"
gen && [ "$(dialers)" = "LT_1=ks-entry,LT_1_FB=ks-entry,ks-ping-0=ks-entry,ks-ping-1=-,ks-entry=-" ] && [ "$(setting multihop x)" = "🇩🇪Германия" ] &&
  ok "an empty or null dialerProxy / proxySettings is no chain: the exit goes through the entry, double VPN stays" ||
  bad "empty chain: $(cat "$T/err") $(dialers) $(setting multihop x) $(cat "$EVENTS")"
xtest "empty or null chain fields" "$T/c"

# --- ks set multihop with Xray: stored only when the config builds, then rebuilt and reloaded
printf 'core=xray\n' > "$SETTINGS"
hosts
core_import "$T/p.json" import 2>"$T/err" || bad "import: $(cat "$T/err")"
cfg="$CORE_DIR/xray.json"
set_multihop "🇩🇪Германия" 2>"$T/err" && [ "$(setting multihop off)" = "🇩🇪Германия" ] &&
  [ "$(j 'join ",", map { $_->{tag} } grep { ($_->{streamSettings}{sockopt}{dialerProxy} // "") eq "ks-entry" } @{ $c->{outbounds} }' "$cfg")" = LT_1,LT_1_FB,ks-ping-0 ] &&
  ok "ks set multihop: stored and applied with Xray" || bad "set_multihop: $(cat "$T/err")"
grep -qx 203.0.113.10 "$SERVERS" && grep -qx 203.0.113.20 "$SERVERS" && ok "  servers for pf: the approved hosts, as before (not narrowed: ADR 0027)" || bad "  servers: $(cat "$SERVERS")"
cp "$cfg" "$T/cfg.before"
set_multihop "🇳🇱Нидерланды" 2>"$T/err" && bad "a missing entry stored" ||
  { [ "$(setting multihop off)" = "🇩🇪Германия" ] && cmp -s "$cfg" "$T/cfg.before" && ok "  a missing entry refused, the old one kept" || bad "  refusal: $(cat "$T/err")"; }
set_multihop "🇱🇹Литва" 2>"$T/err" && bad "the running host stored as the entry" ||
  { [ "$(setting multihop off)" = "🇩🇪Германия" ] && grep -q 'выход' "$T/err" && ok "  the running host as the entry: refused (that would be one hop)" || bad "  entry = exit: $(cat "$T/err")"; }
xray_select "🇩🇪Германия" 2>"$T/err" && bad "the entry picked as the exit" ||
  { [ -z "$(setting xrayserver "")" ] && grep -q 'вход' "$T/err" && ok "  picking the entry as the exit: refused, said why" || bad "  select entry: $(cat "$T/err")"; }
set_multihop off 2>"$T/err" && [ "$(setting multihop x)" = off ] &&
  [ "$(j 'scalar grep { $_->{streamSettings}{sockopt}{dialerProxy} } @{ $c->{outbounds} }' "$cfg")" = 0 ] &&
  ok "  off: one hop again" || bad "  off: $(cat "$T/err")"
# set by hand, strict: an entry the generator would build one hop with is refused, never stored
# (the UI would say double VPN while the exit sees the Mac's address)
hosts '$a->[1]{outbounds}[0]{proxySettings} = { tag => "DE_1_FB" }'
core_import "$T/p.json" import 2>"$T/err" || bad "import chained entry: $(cat "$T/err")"
set_multihop "🇩🇪Германия" 2>"$T/err" && bad "an entry that would be one hop stored" ||
  { [ "$(setting multihop x)" = off ] && grep -q 'через другой' "$T/err" &&
    [ "$(j 'scalar grep { ($_->{streamSettings}{sockopt}{dialerProxy} // "") eq "ks-entry" } @{ $c->{outbounds} }' "$cfg")" = 0 ] &&
    ok "  an entry the build cannot use: refused with the reason, nothing stored" || bad "  strict: $(cat "$T/err") $(setting multihop x)"; }
hosts; core_import "$T/p.json" import 2>"$T/err" || bad "import: $(cat "$T/err")"
# a name is compared as it is (awk -v would read «\m» as an escape)
cp "$REPORT" "$T/report.keep"
/usr/bin/perl -MJSON::PP -e 'local $/; my $r = JSON::PP->new->decode(<STDIN>); push @{ $r->{servers} }, { name => "Гер\\мания" }; print JSON::PP->new->encode($r)' < "$T/report.keep" > "$REPORT"
xray_pings() { printf '%s\t0\t0\n' 'Гер\мания'; }
set_multihop 'Гер\мания' 2>"$T/err"; grep -q 'не отвечает' "$T/err" && ok "  a backslash in a name: compared as it is" || bad "  backslash: $(cat "$T/err")"
cp "$T/report.keep" "$REPORT"
# a dead entry is refused; with the core running, the chain must answer after the restart
xray_pings() { printf '🇱🇹Литва\t1\t50\n🇩🇪Германия\t0\t0\n'; }
set_multihop "🇩🇪Германия" 2>"$T/err" && bad "a dead entry stored" ||
  { [ "$(setting multihop x)" = off ] && grep -q 'не отвечает' "$T/err" && ok "  an entry the observatory finds dead: refused" || bad "  dead entry: $(cat "$T/err")"; }
xray_pings() { printf '🇱🇹Литва\t1\t50\n🇩🇪Германия\t1\t60\n'; }
core_job() { CORE_RUN=1; CORE_PID=100; }
core_up() { return 0; }
PROBE="0 0"; diag_probe() { echo "$PROBE"; }
CHAIN_TRIES=2; CHAIN_WAIT=0
set_multihop "🇩🇪Германия" 2>"$T/err" && bad "a chain that does not answer kept" ||
  { [ "$(setting multihop x)" = off ] && [ "$(j 'scalar grep { $_->{streamSettings}{sockopt}{dialerProxy} } @{ $c->{outbounds} }' "$cfg")" = 0 ] &&
    grep -q 'double VPN off: no answer through' "$EVENTS" && ok "  running, no answer through the chain: back to one hop, logged" || bad "  rollback: $(cat "$T/err") $(setting multihop x)"; }
PROBE="90 1"
set_multihop "🇩🇪Германия" 2>"$T/err" && [ "$(setting multihop x)" = "🇩🇪Германия" ] && ok "  running, the chain answers: kept" || bad "  verified: $(cat "$T/err")"
# a third host; with an entry set, the others' probes go through it, so their «dead» says nothing
# of them: switching the entry is not refused for it (the chain is checked after the restart)
hosts 'my $x = $c->decode($c->encode($a->[1])); $x->{remarks} = "🇳🇱Нидерланды"; $_->{settings}{vnext}[0]{address} = "203.0.113.30" for @{ $x->{outbounds} }[0, 1];
  $_->{tag} =~ s/\ADE_/NL_/ for @{ $x->{outbounds} };
  for my $b (@{ $x->{routing}{balancers} }) { s/\ADE_/NL_/ for $b->{fallbackTag}, @{ $b->{selector} }; s/\ADE_/NL_/ for map { $_->{match} } @{ $b->{strategy}{settings}{costs} } }
  push @$a, $x'
core_import "$T/p.json" import 2>"$T/err" || bad "import three: $(cat "$T/err")"
xray_pings() { printf '🇱🇹Литва\t0\t0\n🇩🇪Германия\t0\t0\n🇳🇱Нидерланды\t0\t0\n'; }
set_multihop "🇳🇱Нидерланды" 2>"$T/err" && [ "$(setting multihop x)" = "🇳🇱Нидерланды" ] &&
  ok "  another entry while one is set: not refused for probes that went through the old one" || bad "  switch entry: $(cat "$T/err")"
# a failed change of entry keeps the old chain (checked again), not one hop
: > "$T/pn"; diag_probe() { local n; n=$(wc -l < "$T/pn"); echo x >> "$T/pn"; if [ "$n" -lt 2 ]; then echo "0 0"; else echo "90 1"; fi; }
set_multihop "🇩🇪Германия" 2>"$T/err" && bad "a chain that does not answer kept" ||
  { [ "$(setting multihop x)" = "🇳🇱Нидерланды" ] && grep -q 'double VPN back: «🇳🇱Нидерланды», no answer through «🇩🇪Германия»' "$EVENTS" &&
    grep -q 'Нидерланды' "$T/err" && ok "  a new entry that does not answer: back to the previous one, logged" || bad "  back: $(cat "$T/err") $(setting multihop x)"; }
PROBE="0 0"; diag_probe() { echo "$PROBE"; }
set_multihop "🇩🇪Германия" 2>"$T/err" && bad "kept without an answer" ||
  { [ "$(setting multihop x)" = off ] && ok "  and when the previous one does not answer either: one hop" || bad "  back fails: $(setting multihop x)"; }
core_job() { CORE_RUN=0; CORE_PID=""; }

# --- the upgrade (_regen): a multihop= from the mihomo era, read by an Xray report without targets
printf '{"version":1,"core":"xray","servers":[{"name":"🇩🇪Германия"}]}' > "$REPORT"
put_setting multihop "🇩🇪Германия"; : > "$EVENTS"
multihop_stale_drop && [ "$(setting multihop x)" = off ] && grep -q 'double VPN off' "$EVENTS" &&
  ok "upgrade: a double VPN from before this helper (a mihomo name) is turned off, logged" || bad "stale: $(setting multihop x)"
printf '{"version":1,"core":"xray","targets":{}}' > "$REPORT"; put_setting multihop "🇩🇪Германия"
multihop_stale_drop; [ "$(setting multihop x)" = "🇩🇪Германия" ] && ok "  one this helper set is kept" || bad "  kept: $(setting multihop x)"

# --- another core: the entry names a server of the other core's format, so it goes
put_setting multihop "🇩🇪Германия"
set_core mihomo 2>/dev/null && [ "$(setting multihop off)" = off ] && ok "ks set core: «Двойной VPN» off (its entry is a server of the other core)" ||
  bad "set_core kept multihop=$(setting multihop off)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
