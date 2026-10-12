#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The Xray config generator of Helper/ks (ADR 0020) on the panel's Xray JSON (a fixture made from
# the owner's Remnawave answer with every secret replaced); no root, no network.
#   Helper/tests/core-xray.sh   (XRAY=/path/to/xray to check with "xray run -test"; geodata next to it)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
# the probes of the running host's alternatives (ADR 0030) are tested in core-xray-escalate.sh
eval "ks_$(declare -f setting)"; setting() { if [ "$1" = escalate ]; then echo 0; else ks_setting "$@"; fi; }
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
resolve_host() { case "$1" in lt.example.com) echo 203.0.113.40 ;; de.example.com) echo 203.0.113.20 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
# j <perl expression over $c, the generated config> [file]: prints its value
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$tmp/c}"; }
q() { j "$1" "$tmp/c.report"; }
gen() { core_generate_xray "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
# edit <perl over $a, the fixture array>: a changed copy in $tmp/p.json
edit() { /usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); eval $ARGV[0]; die $@ if $@;
           print JSON::PP->new->encode($a)' "$1" < "$fx/xray-panel.json" > "$tmp/p.json"; }
xtest() {  # xtest <name> <config>
  if [ -x "$XRAY" ]; then
    if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
    else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
  else echo "skip  $1: xray run -test (no $XRAY)"; fi
}

gen "$fx/xray-panel.json" || bad "panel config refused: $(cat "$tmp/err")"
[ "$(cat "$tmp/s")" = 203.0.113.10 ] && ok "servers: the outbounds' addresses" || bad "servers: $(cat "$tmp/s")"
[ ! -s "$tmp/c.pins" ] && ok "addresses already IPs: nothing pinned" || bad "pins: $(cat "$tmp/c.pins")"
[ "$(j 'join ",", sort keys %$c')" = "api,burstObservatory,dns,inbounds,log,outbounds,policy,routing,stats" ] &&
  ok "top level: the template's sections, our inbounds, log and stats API (ADR 0021), no remarks" || bad "keys: $(j 'join ",", sort keys %$c')"
[ "$(j 'join ",", map { "$_->{tag}:$_->{protocol}" } @{ $c->{inbounds} }')" = "ks-tun:tun,ks-dns:dokodemo-door,ks-fetch:http" ] &&
  ok "inbounds: ours only (the template's socks/http on 10808/10809 gone)" || bad "inbounds: $(j '$c->{inbounds}')"
[ "$(j '$c->{inbounds}[0]{settings}{gateway}[0]')" = 198.18.128.0/30 ] && [ "$CORE_TUN_ADDR" = 198.18.128.1 ] &&
  [ "$(j 'join ",", @{ $c->{inbounds}[0]{settings}{autoSystemRoutingTable} }')" = 0.0.0.0/0 ] &&
  [ "$(j '$c->{inbounds}[0]{settings}{autoOutboundsInterface}')" = auto ] &&
  ok "tun: utun gets 198.18.128.1 (CORE_TUN_ADDR, so pf and the watchdog know it), IPv4 routes, own sockets on the physical interface" ||
  bad "tun: $(j '$c->{inbounds}[0]')"
[ "$(j '$c->{inbounds}[0]{sniffing}{routeOnly} ? "route" : "override"')" = route ] &&
  [ "$(j 'join ",", @{ $c->{inbounds}[0]{sniffing}{destOverride} }')" = http,tls,quic ] &&
  ok "tun: the template's sniffing, routing only" || bad "sniffing: $(j '$c->{inbounds}[0]{sniffing}')"
[ "$(j '"$c->{inbounds}[1]{listen}:$c->{inbounds}[1]{port}"')" = 127.0.0.1:53 ] &&
  [ "$(j '"$c->{inbounds}[2]{listen}:$c->{inbounds}[2]{port}"')" = "127.0.0.1:$FETCH_PORT" ] &&
  ok "the system DNS (127.0.0.1:53) and the app's fetch (127.0.0.1:47890) on loopback" || bad "dns/fetch: $(j '$c->{inbounds}')"
[ "$(j 'JSON::PP->new->canonical->encode($c->{routing}{rules}[0])')" = '{"inboundTag":["ks-dns"],"outboundTag":"dns-out"}' ] &&
  ok "routing: the system's DNS goes to the template's dns-out first" || bad "dns rule: $(j '$c->{routing}{rules}[0]')"
[ "$(j 'JSON::PP->new->canonical->encode($c->{routing}{rules}[1])')" = '{"inboundTag":["ks-fetch"],"outboundTag":"LT_1"}' ] &&
  ok "routing: the fetch always to a server, never direct (ADR 0016)" || bad "fetch rule: $(j '$c->{routing}{rules}[1]')"
[ "$(j '$c->{routing}{rules}[2]{inboundTag}[0]')" = direct-dns ] && [ "$(j 'scalar @{ $c->{routing}{rules} }')" = 21 ] &&
  ok "routing: then the subscription's 19 rules, in order" || bad "rules: $(j 'scalar @{ $c->{routing}{rules} }')"
[ "$(j '$c->{routing}{balancers}[0]{tag}')" = country-lb ] && [ "$(j '$c->{routing}{domainStrategy}')" = AsIs ] &&
  ok "routing: balancer and domain strategy kept" || bad "balancers: $(j '$c->{routing}')"
[ "$(j '"$c->{log}{loglevel} $c->{log}{access}"')" = "warning none" ] && ok "log: warnings only, no access log (no visited sites)" ||
  bad "log: $(j '$c->{log}')"
[ "$(j 'join ",", map { $_->{tag} } @{ $c->{outbounds} }')" = "LT_1,LT_1_FB,direct,block,dns-out,ks-ping-0" ] &&
  ok "outbounds: the template's, in order, then the host's probe (ADR 0023)" || bad "outbounds: $(j 'join ",", map { $_->{tag} } @{ $c->{outbounds} }')"
[ "$(paste -sd, - < "$tmp/c.egress")" = rules,dns ] && ok "egress: direct rules and DNS servers reached directly" ||
  bad "egress: $(cat "$tmp/c.egress")"
grep -q '^rule	' "$tmp/c.direct" && grep -q '"outboundTag":"direct"' "$tmp/c.direct" && ok "direct signature: the rules to freedom" ||
  bad "direct sig: $(head -3 "$tmp/c.direct")"
grep -qE '00000000-0000-4000|Z84J2Iel|0123abcd|fake-path' "$tmp/c.direct" && bad "direct signature holds a secret" || ok "direct signature: no secret"
# KS-15: ks-dns goes to the subscription's dns outbound; its settings could send queries out by
# themselves, outside the DIRECT signature: ours only, A/AAAA to the DNS above, the rest refused
[ "$(j 'JSON::PP->new->canonical->encode([ map { $_->{settings} } grep { $_->{protocol} eq "dns" } @{ $c->{outbounds} } ])')" = '[{"nonIPQuery":"reject"}]' ] &&
  ok "dns outbound: settings are ours, non-A/AAAA refused (KS-15)" || bad "dns outbound: $(j '[ grep { $_->{protocol} eq "dns" } @{ $c->{outbounds} } ]')"
cp "$tmp/c" "$tmp/c-before"; cp "$tmp/c.direct" "$tmp/direct-before"
edit '$_->{settings} = { address => "8.8.8.8", port => 53, nonIPQuery => "skip" } for grep { $_->{protocol} eq "dns" } @{ $a->[0]{outbounds} }'
gen "$tmp/p.json" && cmp -s "$tmp/c" "$tmp/c-before" && cmp -s "$tmp/c.direct" "$tmp/direct-before" &&
  ok "  the subscription's own dns outbound settings change nothing" || bad "  dns outbound settings: $(j '[ grep { $_->{protocol} eq "dns" } @{ $c->{outbounds} } ]')"
gen "$fx/xray-panel.json"
grep -qE '00000000-0000-4000|Z84J2Iel|0123abcd|fake-path' "$tmp/c.report" && bad "report holds a secret" || ok "report: no uuid, key, short id or path"
[ "$(q 'join "|", map { $_->{from} . ":" . ($_->{index} // "") } @{ $r = $c->{rules} }[0..3]')" = "killswitch:|killswitch:|subscription:0|subscription:1" ] &&
  ok "report: our rules, then the subscription's with their index" || bad "report rules: $(q '[@{ $c->{rules} }[0..3]]')"
# «Проверить адрес» with Xray (#33, ADR 0027): each rule as the core has it, and where each tag leads
[ "$(q 'JSON::PP->new->canonical->encode($c->{rules}[0]{xray})')" = '{"inboundTag":["ks-dns"],"outboundTag":"dns-out"}' ] &&
  [ "$(q 'JSON::PP->new->canonical->encode($c->{rules}[5]{xray})')" = '{"network":"udp","outboundTag":"block","port":"443","type":"field"}' ] &&
  [ "$(q 'scalar grep { ref $_->{xray} ne "HASH" } @{ $c->{rules} }')" = 0 ] &&
  ok "report: every rule also as the core's object (for «Проверить адрес»)" || bad "report xray rules: $(q '[@{ $c->{rules} }[0..5]]')"
[ "$(q 'join ",", map { "$_:$c->{targets}{$_}" } sort keys %{ $c->{targets} }')" = "LT_1:vpn,LT_1_FB:vpn,block:block,direct:direct,dns-out:dns" ] &&
  [ "$(q '$c->{fallback}')" = LT_1 ] &&
  ok "report: where each outbound leads, and the one no rule takes (the first)" || bad "report targets: $(q '$c->{targets}') $(q '$c->{fallback}')"
grep -qE '00000000-0000-4000|Z84J2Iel|0123abcd|fake-path' "$tmp/c.report" && bad "report holds a secret after the rule objects" || ok "  still no secret in the report"
edit 'unshift @{ $a->[0]{outbounds} }, { protocol => "freedom" };
  unshift @{ $a->[0]{routing}{rules} }, { domain => [ map { "domain:d$_.example" } 1 .. 2000 ], outboundTag => "block" }'
gen "$tmp/p.json" || bad "untagged first freedom refused: $(cat "$tmp/err")"
[ "$(q '"[$c->{fallback}]:" . $c->{targets}{$c->{fallback}}')" = "[]:direct" ] &&
  ok "  an untagged freedom first: the fallback says direct, not nothing" || bad "  fallback: $(q '$c->{fallback}') $(q '$c->{targets}')"
[ "$(q 'exists $c->{rules}[2]{xray} ? "kept" : "left out"')" = "left out" ] && [ "$(q 'exists $c->{rules}[3]{xray} ? "kept" : "left out"')" = kept ] &&
  [ "$(wc -c < "$tmp/c.report")" -lt 200000 ] && ok "  a rule object over 16 KB is left out of the report (the app says it cannot tell)" ||
  bad "  big rule: $(wc -c < "$tmp/c.report")"
# a host's name ends up in settings (xrayserver=) and the report: control characters or more than
# 256 bytes refuse the subscription, as a damaged one; a tab or a line break becomes a space (0.19.1,
# #37: one name must not become two in the lists)
edit '$a->[0]{remarks} = "Литва\tвход"'
gen "$tmp/p.json" && [ "$(q '$c->{servers}[0]{name}')" = "Литва вход" ] && ok "a tab in a host name: a space" || bad "a tab in a host name: $(cat "$tmp/err") $(q '$c->{servers}')"
edit '$a->[0]{remarks} = "x" x 257'
gen "$tmp/p.json" && bad "a 257-byte host name accepted" || ok "a host name over 256 bytes: refused"
edit '$a->[0]{remarks} = "x" . "я" x 200'
gen "$tmp/p.json"; iconv -f UTF-8 -t UTF-8 < "$tmp/err" >/dev/null 2>&1 && grep -q 'я…' "$tmp/err" &&
  ok "  the refusal names it cut on a character, not mid-letter" || bad "  cut: $(od -c < "$tmp/err" | head -3)"
gen "$fx/xray-panel.json"
[ "$(q 'join ",", map { "$_->{name}:$_->{type}" } @{ $c->{proxies} }')" = "LT_1:vless,LT_1_FB:vless" ] &&
  [ "$(q 'join ",", map { "$_->{name}:" . join "+", @{ $_->{proxies} } } @{ $c->{groups} }')" = "country-lb:LT_1+LT_1_FB" ] &&
  ok "report: servers and the balancer with its members" || bad "report proxies/groups: $(q '$c->{proxies}') $(q '$c->{groups}')"
[ "$(q '$c->{core}')" = xray ] && [ "$(q 'join ",", @{ $c->{egress} }')" = rules,dns ] && [ "$(q '$c->{sniffer}{from}')" = subscription ] &&
  ok "report: core, egress, sniffer from the subscription" || bad "report: $(q '$c->{egress}') $(q '$c->{sniffer}')"
[ "$(q 'join ",", @{ $c->{dns}{servers} }')" = "77.88.8.8,8.8.8.8,1.1.1.1" ] && ok "report: DNS servers by address" || bad "report dns: $(q '$c->{dns}')"
[ "$(stat -f %Lp "$tmp/c")" = 600 ] && ok "config root-only (it holds the servers' keys)" || bad "config mode $(stat -f %Lp "$tmp/c")"
xtest panel "$tmp/c"

# --- a server by name: pinned to the address pf lets through, the name stays for TLS/Reality
edit '$a->[0]{outbounds}[0]{settings}{vnext}[0]{address} = "lt.example.com"; delete $a->[0]{outbounds}[0]{streamSettings}{realitySettings}{serverName}'
gen "$tmp/p.json" || bad "named server refused: $(cat "$tmp/err")"
[ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}')" = 203.0.113.40 ] && [ "$(cat "$tmp/c.pins")" = "lt.example.com	203.0.113.40" ] &&
  [ "$(paste -sd, - < "$tmp/s")" = 203.0.113.10,203.0.113.40 ] && ok "named server: pinned, in the servers" || bad "named: $(cat "$tmp/c.pins") / $(cat "$tmp/s")"
[ "$(j '$c->{outbounds}[0]{streamSettings}{realitySettings}{serverName}')" = lt.example.com ] &&
  ok "named server without serverName: the name kept for Reality" || bad "serverName: $(j '$c->{outbounds}[0]{streamSettings}{realitySettings}')"
printf 'lt.example.com\t203.0.113.41\n' > "$tmp/pins"
resolve_host() { echo "DNS asked" >> "$tmp/dns"; return 1; }
KS_PINS="$tmp/pins" gen "$tmp/p.json" && [ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}')" = 203.0.113.41 ] && [ ! -e "$tmp/dns" ] &&
  ok "rebuild: addresses from the pins, no DNS" || bad "rebuild: $(cat "$tmp/err")"
gen "$tmp/p.json" && bad "unresolvable server accepted" || { grep -q 'lt.example.com' "$tmp/err" && ok "unresolvable server: refused, named" || bad "unresolvable: $(cat "$tmp/err")"; }
resolve_host() { case "$1" in lt.example.com) echo 203.0.113.40 ;; de.example.com) echo 203.0.113.20 ;; *) return 1 ;; esac; }

# --- what is refused outright
echo '{"proxies":[]}' > "$tmp/m.json"
gen "$tmp/m.json" && bad "a mihomo profile accepted" || { grep -q 'Xray' "$tmp/err" && ok "not the Xray JSON (a mihomo profile): refused" || bad "mihomo: $(cat "$tmp/err")"; }
echo '[]' > "$tmp/m.json"
gen "$tmp/m.json" && bad "empty array accepted" || ok "empty array: refused"
edit 'push @{ $a->[0]{outbounds} }, { tag => "h", protocol => "hysteria", settings => {} }'
gen "$tmp/p.json" && bad "unknown protocol accepted" || { grep -q 'hysteria' "$tmp/err" && ok "unknown outbound protocol: refused, named" || bad "protocol: $(cat "$tmp/err")"; }
edit '$a->[0]{outbounds}[0]{settings}{vnext}[0]{address} = "2001:db8::1"'
gen "$tmp/p.json" && bad "IPv6 server accepted" || ok "IPv6 server address: refused (no IPv6 through pf)"
edit '$a->[0]{outbounds}[0]{proxySettings} = { tag => "nope" }'
gen "$tmp/p.json" && bad "dialer to a missing outbound accepted" || ok "proxySettings to a missing outbound: refused"

# --- what is left out with a reason
edit 'unshift @{ $a->[0]{routing}{rules} }, { webhook => { url => "http://x" }, outboundTag => "direct" }, { domain => ["a.example"], outboundTag => "nope" };
      $a->[0]{api} = { tag => "api" }; $a->[0]{stats} = {}; $a->[0]{reverse} = {};
      $a->[0]{outbounds}[0]{sendThrough} = "192.168.1.5"; $a->[0]{outbounds}[2]{streamSettings}{sockopt}{interface} = "en0";
      push @{ $a->[0]{dns}{servers} }, "localhost", "fakedns"'
gen "$tmp/p.json" || bad "panel with extras refused: $(cat "$tmp/err")"
[ "$(q 'join "|", map { "$_->{section}:" . ($_->{index} // $_->{item}) . "=$_->{reason}" } @{ $c->{dropped} }')" = \
  "profile:api=not-allowed|profile:inbounds=managed|profile:remarks=managed|profile:reverse=not-allowed|profile:stats=not-allowed|profile:burstObservatory.pingConfig.connectivity=not-allowed|rules:0=not-allowed|rules:1=target:nope|dns:localhost=bad-value|dns:fakedns=bad-value" ] &&
  ok "left out with reasons: api, stats, reverse, the connectivity URL, a webhook rule, a rule to nowhere, system and fake DNS" || bad "dropped: $(q '$c->{dropped}')"
[ "$(j 'exists $c->{reverse} || $c->{api}{tag} ne "ks-api" || $c->{api}{listen} !~ /\A127\.0\.0\.1:/ ? "kept" : "gone"')" = gone ] &&
  [ "$(j 'exists $c->{outbounds}[0]{sendThrough} || exists $c->{outbounds}[2]{streamSettings}{sockopt}{interface} ? "kept" : "gone"')" = gone ] &&
  ok "config: the subscription's api/stats/reverse gone (ours only), no sendThrough or bound interface" || bad "extras: $(j '[keys %$c]')"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "unbound" } @{ $c->{added} }')" = "LT_1,direct" ] &&
  ok "report: unbound outbounds named" || bad "unbound: $(q '$c->{added}')"
[ "$(j 'join ",", map { ref $_ ? $_->{address} : $_ } @{ $c->{dns}{servers} }')" = "77.88.8.8,8.8.8.8,1.1.1.1" ] &&
  ok "dns: system resolver (would loop into ourselves) and fakedns left out" || bad "dns servers: $(j '$c->{dns}{servers}')"

xtest "extras left out" "$tmp/c"

# --- egress follows the subscription
edit '$a->[0]{routing}{rules} = [ { port => "0-65535", balancerTag => "country-lb" } ]; $a->[0]{dns}{servers} = ["8.8.8.8"]'
gen "$tmp/p.json" && [ ! -s "$tmp/c.egress" ] && [ ! -s "$tmp/c.direct" ] && ok "nothing to freedom: empty egress and signature" ||
  bad "nothing direct: egress $(cat "$tmp/c.egress"), sig $(cat "$tmp/c.direct")"
edit '$a->[0]{routing}{rules} = []; unshift @{ $a->[0]{outbounds} }, splice(@{ $a->[0]{outbounds} }, 2, 1)'
gen "$tmp/p.json" && [ "$(cat "$tmp/c.egress")" = rules ] && grep -q '^default	direct$' "$tmp/c.direct" &&
  ok "freedom first (what no rule matches goes there): egress rules, in the signature" || bad "freedom first: $(cat "$tmp/c.egress") / $(cat "$tmp/c.direct")"
edit '$a->[0]{routing}{balancers}[0]{selector} = ["LT_", "dir"]; $a->[0]{routing}{rules} = [ { port => "0-65535", balancerTag => "country-lb" } ]; $a->[0]{dns}{servers} = ["8.8.8.8"]'
gen "$tmp/p.json" && [ "$(cat "$tmp/c.egress")" = rules ] && ok "a balancer that holds freedom: egress rules" || bad "balancer direct: $(cat "$tmp/c.egress")"
edit 'splice @{ $a->[0]{outbounds} }, 4, 1; $a->[0]{routing}{rules} = [ grep { ($_->{outboundTag} // "") ne "dns-out" } @{ $a->[0]{routing}{rules} } ]'
gen "$tmp/p.json" && [ "$(j '$c->{routing}{rules}[0]{outboundTag}')" = ks-dns-out ] && [ "$(j '(grep { $_->{tag} !~ /\Aks-ping-/ } @{ $c->{outbounds} })[-1]{protocol}')" = dns ] &&
  ok "no dns outbound in the template: ours added for the system's DNS" || bad "dns-out: $(j '$c->{routing}{rules}[0]')"

# --- several hosts: all approved, the chosen one runs
edit 'my $b = JSON::PP->new->decode(JSON::PP->new->encode($a->[0])); $b->{remarks} = "DE"; $b->{outbounds}[0]{settings}{vnext}[0]{address} = "de.example.com";
      $b->{outbounds}[1]{settings}{vnext}[0]{address} = "203.0.113.21"; push @$a, $b'
gen "$tmp/p.json" && [ "$(paste -sd, - < "$tmp/s")" = 203.0.113.10,203.0.113.20,203.0.113.21 ] &&
  [ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}')" = 203.0.113.10 ] && ok "two hosts: servers of both, the first runs" ||
  bad "two hosts: $(cat "$tmp/s") $(cat "$tmp/err")"
echo xrayserver=DE > "$SETTINGS"
gen "$tmp/p.json" && [ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}')" = 203.0.113.20 ] && ok "xrayserver=DE: that host runs" ||
  bad "chosen: $(j '$c->{outbounds}[0]{settings}{vnext}[0]')"
[ "$(q 'join ",", map { $_->{name} } @{ $c->{servers} }')" = "🇱🇹Литва,DE" ] && [ "$(q '$c->{selected}')" = DE ] &&
  ok "report: the hosts by name and the chosen one" || bad "report servers: $(q '$c->{servers}') $(q '$c->{selected}')"
echo xrayserver=Nope > "$SETTINGS"
gen "$tmp/p.json" && [ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}')" = 203.0.113.10 ] && ok "unknown xrayserver: the first host" ||
  bad "unknown chosen: $(cat "$tmp/err")"
rm -f "$SETTINGS"

# --- the user's own choices go before the subscription's rules
echo site > "$CORE_DIR/geosite.dat"
printf 'adblock=1\nsplitapps=Telegram,/Applications/Steam.app\n' > "$SETTINGS"
gen "$fx/xray-panel.json" || bad "with choices refused: $(cat "$tmp/err")"
[ "$(j 'JSON::PP->new->canonical->encode($c->{routing}{rules}[2])')" = '{"domain":["geosite:category-ads-all"],"outboundTag":"block"}' ] &&
  ok "adblock: the shipped geosite's ads refused before the subscription" || bad "adblock: $(j '$c->{routing}{rules}[2]')"
[ "$(j 'JSON::PP->new->canonical->encode($c->{routing}{rules}[3])')" = '{"outboundTag":"direct","process":["Telegram","/Applications/Steam.app/"]}' ] &&
  ok "splitapps: programs around the VPN by name or folder" || bad "splitapps: $(j '$c->{routing}{rules}[3]')"
xtest "ad block and programs around the VPN" "$tmp/c"
[ "$(paste -sd, - < "$tmp/c.egress")" = rules,dns,splitapps ] && ok "splitapps: in the egress reasons" || bad "egress: $(cat "$tmp/c.egress")"
[ "$(q 'join ",", map { $_->{kind} } @{ $c->{added} }')" = "adblock,splitapps,ping" ] && ok "report: the choices named (and the probes)" || bad "added: $(q '$c->{added}')"
rm -f "$SETTINGS" "$CORE_DIR/geosite.dat"
printf 'adblock=1\n' > "$SETTINGS"
gen "$fx/xray-panel.json" && [ "$(j '$c->{routing}{rules}[2]{inboundTag}[0]')" = direct-dns ] && ok "adblock without geosite.dat: no rule" ||
  bad "adblock without geodata: $(j '$c->{routing}{rules}[2]')"
rm -f "$SETTINGS"

# --- own servers added by link (#33, ADR 0027): the app appends each as a host of its own
# (App/Core/XrayManual.swift, the shape of Tests/XrayManualTests.swift): one server, DNS through it
resolve_host() { case "$1" in lt.example.com) echo 203.0.113.40 ;; pl.example.com) echo 203.0.113.50 ;; *) return 1 ;; esac; }
edit 'push @$a,
  { remarks => "Варшава (свой)", dns => { servers => ["1.1.1.1", "8.8.8.8"], queryStrategy => "UseIPv4" },
    outbounds => [{ tag => "proxy", protocol => "trojan", settings => { servers => [{ address => "pl.example.com", port => 443, password => "pw" }] },
                    streamSettings => { network => "tcp", security => "tls", tlsSettings => { serverName => "pl.example.com" } } }] },
  { remarks => "Рига (свой)", dns => { servers => ["1.1.1.1", "8.8.8.8"], queryStrategy => "UseIPv4" },
    outbounds => [{ tag => "proxy", protocol => "vless",
                    settings => { vnext => [{ address => "203.0.113.60", port => 443, users => [{ id => "00000000-0000-4000-8000-000000000002", encryption => "none" }] }] },
                    streamSettings => { network => "xhttp", security => "reality",
                      realitySettings => { serverName => "www.example.com", fingerprint => "chrome", publicKey => "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw", shortId => "ab12" },
                      xhttpSettings => { path => "/p", mode => "packet-up", extra => { xPaddingBytes => "100-1000" } } } }] }'
gen "$tmp/p.json" && [ "$(paste -sd' ' - < "$tmp/s")" = "203.0.113.10 203.0.113.50 203.0.113.60" ] &&
  ok "own servers: checked and pinned with the subscription's hosts (a new one needs the admin, like any)" || bad "own servers: $(cat "$tmp/err") $(cat "$tmp/s")"
printf 'xrayserver=Варшава (свой)\n' > "$SETTINGS"
gen "$tmp/p.json" || bad "own server refused: $(cat "$tmp/err")"
[ "$(j '"$c->{outbounds}[0]{tag}:$c->{outbounds}[0]{settings}{servers}[0]{address}"')" = proxy:203.0.113.50 ] &&
  [ "$(j 'join ",", map { $_->{outboundTag} } @{ $c->{routing}{rules} }')" = ks-dns-out,proxy ] &&
  ok "  running one: its server first (what no rule takes), only our two rules" || bad "  own: $(j '$c->{routing}')"
[ ! -s "$tmp/c.egress" ] && [ ! -s "$tmp/c.direct" ] && ok "  nothing past the VPN: no egress, an empty DIRECT signature" ||
  bad "  egress: $(cat "$tmp/c.egress") direct: $(cat "$tmp/c.direct")"
[ "$(j 'join ",", map { ref $_ ? $_->{address} : $_ } @{ $c->{dns}{servers} }')" = 1.1.1.1,8.8.8.8 ] && ok "  its DNS servers, reached through it" || bad "  dns: $(j '$c->{dns}')"
xtest "own trojan server" "$tmp/c"
printf 'xrayserver=Рига (свой)\n' > "$SETTINGS"
gen "$tmp/p.json" && xtest "own vless reality xhttp server" "$tmp/c" || bad "own vless: $(cat "$tmp/err")"
rm -f "$SETTINGS"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
