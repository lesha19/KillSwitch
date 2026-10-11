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
[ "$(dialers)" = "LT_1=ks-entry,LT_1_FB=ks-entry,ks-ping-0=-,ks-ping-1=-,ks-entry=-" ] &&
  ok "every server of the running host is dialed through ks-entry; the probes and the entry are not" || bad "chain: $(dialers)"
[ "$(j 'my ($e) = grep { $_->{tag} eq "ks-entry" } @{ $c->{outbounds} }; "$e->{protocol}:$e->{settings}{vnext}[0]{address}:" . ($e->{streamSettings}{realitySettings}{serverName} // "")')" = "vless:203.0.113.20:www.example.com" ] &&
  ok "  ks-entry: the entry host's first server, its name pinned to the approved address" || bad "  entry: $(j '[grep { $_->{tag} eq "ks-entry" } @{ $c->{outbounds} }]' | head -c 400)"
[ "$(j '$c->{outbounds}[0]{tag}')" = LT_1 ] && ok "  the running host's first outbound stays first (what no rule takes)" || bad "  first: $(j '$c->{outbounds}[0]{tag}')"
[ "$(j 'scalar grep { ($_->{outboundTag} // "") eq "ks-entry" } @{ $c->{routing}{rules} }')" = 0 ] &&
  ok "  no rule sends traffic to the entry alone" || bad "  a rule to ks-entry"
[ "$(j 'join ",", map { $_->{tag} } grep { ($_->{streamSettings}{sockopt}{dialerProxy} // "") eq "ks-entry" } @{ $c->{outbounds} }')" = LT_1,LT_1_FB ] &&
  [ "$(j '$c->{routing}{rules}[1]{outboundTag}')" = LT_1 ] && ok "  the fetch inbound goes to a chained server" || bad "  fetch: $(j '$c->{routing}{rules}[1]')"
cmp -s "$T/c.direct" "$T/direct.single" && cmp -s "$T/c.egress" "$T/egress.single" && cmp -s "$T/s" "$T/servers.single" &&
  ok "nothing new past the VPN: servers for pf, DIRECT signature and egress as without it" || bad "differs: $(cat "$T/c.egress") $(cat "$T/s")"
[ "$(j 'join "|", map { $_->{kind} . ":" . join(",", @{ $_->{items} }) } grep { $_->{kind} eq "multihop" } @{ $c->{added} }' "$T/c.report")" = "multihop:🇩🇪Германия" ] &&
  ok "report: «Двойной VPN — твой выбор» with the entry" || bad "report: $(j '$c->{added}' "$T/c.report")"
[ "$(j 'scalar grep { $_->{name} eq "ks-entry" } @{ $c->{proxies} }' "$T/c.report")" = 0 ] && ok "  ks-entry not listed as a proxy of the subscription" || bad "  proxies"
xtest "double VPN" "$T/c"

# the running host is the entry itself: one hop, nothing to chain
printf 'core=xray\nmultihop=🇩🇪Германия\nxrayserver=🇩🇪Германия\n' > "$SETTINGS"
gen && [ "$(dialers)" = "DE_1=-,DE_1_FB=-,ks-ping-0=-,ks-ping-1=-" ] && ok "the entry is the running host: one hop" || bad "entry = exit: $(cat "$T/err") $(dialers)"

# fail closed: never a silent single hop when the entry is gone, never a chain we cannot see through
printf 'core=xray\nmultihop=🇳🇱Нидерланды\n' > "$SETTINGS"
gen && bad "a missing entry accepted" || { grep -q 'Двойной VPN' "$T/err" && ok "an entry not in the subscription: refused" || bad "missing entry: $(cat "$T/err")"; }
printf 'core=xray\nmultihop=🇩🇪Германия\n' > "$SETTINGS"
hosts '$a->[1]{outbounds}[0]{proxySettings} = { tag => "DE_1_FB" }'
gen && bad "an entry with its own chain accepted" || { grep -q 'Двойной VPN' "$T/err" && ok "an entry reached through another outbound: refused" || bad "chained entry: $(cat "$T/err")"; }
hosts '$a->[0]{outbounds}[2]{tag} = "ks-entry"; $_->{outboundTag} =~ s/\Adirect\z/ks-entry/ for grep { defined $_->{outboundTag} } @{ $a->[0]{routing}{rules} }'
gen && bad "a subscription tag ks-entry accepted" || ok "the subscription's own «ks-entry» tag: refused, not overwritten"
hosts '$a->[0]{outbounds}[1]{proxySettings} = { tag => "LT_1" }'
gen && [ "$(dialers)" = "LT_1=ks-entry,LT_1_FB=-,ks-ping-0=-,ks-ping-1=-,ks-entry=-" ] &&
  ok "a server the subscription reaches through another one is chained through that one" || bad "own chain: $(cat "$T/err") $(dialers)"

# --- ks set multihop with Xray: stored only when the config builds, then rebuilt and reloaded
printf 'core=xray\n' > "$SETTINGS"
hosts
core_import "$T/p.json" import 2>"$T/err" || bad "import: $(cat "$T/err")"
cfg="$CORE_DIR/xray.json"
set_multihop "🇩🇪Германия" 2>"$T/err" && [ "$(setting multihop off)" = "🇩🇪Германия" ] &&
  [ "$(j 'join ",", map { $_->{tag} } grep { ($_->{streamSettings}{sockopt}{dialerProxy} // "") eq "ks-entry" } @{ $c->{outbounds} }' "$cfg")" = LT_1,LT_1_FB ] &&
  ok "ks set multihop: stored and applied with Xray" || bad "set_multihop: $(cat "$T/err")"
grep -qx 203.0.113.10 "$SERVERS" && grep -qx 203.0.113.20 "$SERVERS" && ok "  servers for pf: the approved hosts, as before" || bad "  servers: $(cat "$SERVERS")"
cp "$cfg" "$T/cfg.before"
set_multihop "🇳🇱Нидерланды" 2>"$T/err" && bad "a missing entry stored" ||
  { [ "$(setting multihop off)" = "🇩🇪Германия" ] && cmp -s "$cfg" "$T/cfg.before" && ok "  a missing entry refused, the old one kept" || bad "  refusal: $(cat "$T/err")"; }
set_multihop off 2>"$T/err" && [ "$(setting multihop x)" = off ] &&
  [ "$(j 'scalar grep { $_->{streamSettings}{sockopt}{dialerProxy} } @{ $c->{outbounds} }' "$cfg")" = 0 ] &&
  ok "  off: one hop again" || bad "  off: $(cat "$T/err")"

# --- another core: the entry names a server of the other core's format, so it goes
put_setting multihop "🇩🇪Германия"
set_core mihomo 2>/dev/null && [ "$(setting multihop off)" = off ] && ok "ks set core: «Двойной VPN» off (its entry is a server of the other core)" ||
  bad "set_core kept multihop=$(setting multihop off)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
