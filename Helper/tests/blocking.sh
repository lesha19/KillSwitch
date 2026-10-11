#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Content blocking by category and the user's own DNS-over-HTTPS server (#14, ADR 0031), for both
# cores: blocking only refuses (REJECT / blackhole), the DoH server is only reached through the
# VPN, neither changes the DIRECT signature, the egress reasons or pf. No root, no network.
#   Helper/tests/blocking.sh   (MIHOMO=…, XRAY=… to check the configs with the cores)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"
SETTINGS="$tmp/settings"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; fi.example.com) echo 203.0.113.30 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
put() { { grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$SETTINGS.new"; mv "$SETTINGS.new" "$SETTINGS"; }
# j <perl expression over $c> [file]: its value (JSON for references)
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$tmp/c}"; }
q() { j "$1" "$tmp/c.report"; }
site=""; [ -r "$here/../geosite.dat" ] && site="$here/../geosite.dat"
geo_on() { if [ -n "$site" ]; then cp "$site" "$CORE_DIR/geosite.dat"; else echo fake > "$CORE_DIR/geosite.dat"; fi; }
mt() {  # mt <desc> <config>
  [ -x "$MIHOMO" ] && [ -n "$site" ] || { echo "skip  $1: mihomo -t (no mihomo or geosite.dat)"; return; }
  local out
  if out=$("$MIHOMO" -t -d "$CORE_DIR" -f "$2" 2>&1); then ok "$1: mihomo -t"; else bad "$1: mihomo -t: $(tail -2 <<<"$out")"; fi
}
xtest() {  # xtest <desc> <config>
  [ -x "$XRAY" ] || { echo "skip  $1: xray run -test (no xray)"; return; }
  local out
  if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
  else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
}
genm() { core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
genx() { core_generate_xray "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }

# --- the settings lines ks writes (fail closed on anything else, ADR 0015)
lines_ok() { printf '%s\n' "$1" > "$tmp/lines"; settings_lines_ok "$tmp/lines"; }
for l in blockadult=1 blocksocial=0 blockbetting=1 adblock=1 doh= doh=https://dns.example.com/q%2Fx%20y \
         doh=https://dns.example.com/dns-query doh=https://dns.nextdns.io/abc123 doh=https://9.9.9.9/dns-query \
         doh=https://dns.example.com:8443/q/x_y~z doh=https://d.adguard-dns.com/dns-query/a1b2; do
  lines_ok "$l" && ok "settings: takes $l" || bad "settings: refused $l"
done
for l in blockadult=2 blockmalware=1 doh=http://dns.example.com/dns-query doh=https://user@dns.example.com/dns-query \
         "doh=https://dns.example.com/dns query" doh=https://dns.example.com/dns-query?x=1 doh=https://dns.example.com/a#b \
         doh=https://localhost/dns-query doh=https://127.0.0.1/dns-query doh=https://192.168.1.1/dns-query \
         doh=https://10.0.0.1/dns-query doh=https://198.18.0.1/dns-query doh=https://[::1]/dns-query \
         doh=https://dns.example.com:0/x doh=https://dns.example.com:99999/x doh=https://300.1.1.1/x doh=https://dns/x \
         "doh=https://dns.example.com/$(printf 'a%.0s' $(seq 300))" doh=dns.example.com 'doh=https://-bad.example.com/x' \
         'doh=https://dns.example.com/%zz' 'doh=https://dns.example.com/%' 'doh=https://dns.example.com/a%2' \
         doh=https://Router.LOCAL/dns-query doh=https://nas.Home.Arpa/x doh=https://box.LAN/x; do
  lines_ok "$l" && bad "settings: took $l" || ok "settings: refuses ${l:0:60}"
done

# --- mihomo: categories, from the shipped geosite.dat only
rules_of() { j 'join "|", @{ $c->{rules} }[1 .. $#{ $c->{rules} }]'; }   # rules.0 is the loop guard
put adblock 1; put blockadult 1; put blocksocial 1; put blockbetting 1
genm "$fx/ok-minimal.json"
[ "$(rules_of)" = "MATCH,only" ] && ok "mihomo: no geosite.dat, no category rule (never downloaded)" || bad "mihomo without geodata: $(rules_of)"
geo_on
genm "$fx/ok-minimal.json" || bad "mihomo categories refused: $(cat "$tmp/err")"
[ "$(rules_of)" = "GEOSITE,category-ads-all,REJECT|GEOSITE,category-porn,REJECT|GEOSITE,category-social-media-!cn,REJECT|GEOSITE,category-betting-ru,REJECT|MATCH,only" ] &&
  ok "mihomo: every chosen category refused before the subscription" || bad "mihomo categories: $(rules_of)"
[ ! -s "$tmp/c.direct" ] && [ ! -s "$tmp/c.egress" ] && ok "mihomo: categories change neither the DIRECT signature nor egress" ||
  bad "mihomo: direct $(cat "$tmp/c.direct") egress $(cat "$tmp/c.egress")"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "adblock" } @{ $c->{added} }')" = \
  "GEOSITE,category-ads-all,REJECT,GEOSITE,category-porn,REJECT,GEOSITE,category-social-media-!cn,REJECT,GEOSITE,category-betting-ru,REJECT" ] &&
  ok "mihomo report: the categories named as the person's choice" || bad "mihomo report: $(q '$c->{added}')"
mt "mihomo: four categories" "$tmp/c"
put adblock 0; put blocksocial 0
genm "$fx/ok-minimal.json"
[ "$(rules_of)" = "GEOSITE,category-porn,REJECT|GEOSITE,category-betting-ru,REJECT|MATCH,only" ] && ok "mihomo: only the categories switched on" ||
  bad "mihomo some: $(rules_of)"
rm -f "$SETTINGS"
genm "$fx/ok-minimal.json"
[ "$(rules_of)" = "MATCH,only" ] && ok "mihomo: nothing chosen, nothing blocked" || bad "mihomo none: $(rules_of)"

# --- mihomo: own DoH only, through KS-DNS. mihomo asks "fallback" at the same time as the
# nameservers (review of #14), so a fallback would overrule the own server: none.
genm "$fx/ok-minimal.json"; cp "$tmp/c.direct" "$tmp/plain.direct"; cp "$tmp/c.egress" "$tmp/plain.egress"
j '$c->{dns}' > "$tmp/plain.dns"
put doh https://dns.example.com/dns-query/abc123
genm "$fx/ok-minimal.json" || bad "mihomo doh refused: $(cat "$tmp/err")"
[ "$(j 'join ",", @{ $c->{dns}{nameserver} }')" = "https://dns.example.com/dns-query/abc123#KS-DNS" ] &&
  ok "mihomo doh: the own server, reached through KS-DNS (never DIRECT)" || bad "mihomo doh nameserver: $(j '$c->{dns}{nameserver}')"
[ "$(j 'exists $c->{dns}{fallback} || exists $c->{dns}{"fallback-filter"} ? "yes" : "no"')" = no ] &&
  ok "mihomo doh: no fallback (it would be asked at the same time and overrule it)" || bad "mihomo doh fallback: $(j '$c->{dns}')"
[ "$(j 'join ",", @{ $c->{dns}{"default-nameserver"} }')" = "https://1.1.1.1/dns-query#KS-DNS,https://8.8.8.8/dns-query#KS-DNS" ] &&
  ok "mihomo doh: its name resolved by our resolvers through the tunnel" || bad "mihomo default-nameserver: $(j '$c->{dns}{"default-nameserver"}')"
cmp -s "$tmp/c.direct" "$tmp/plain.direct" && cmp -s "$tmp/c.egress" "$tmp/plain.egress" &&
  ok "mihomo doh: DIRECT signature and egress as without it (no password on refresh, pf unchanged)" || bad "mihomo doh changed direct/egress"
grep -q abc123 "$tmp/c.report" && bad "mihomo doh: the path (an account id) in the world-readable report" ||
  ok "mihomo doh: only the host in the report"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "doh" } @{ $c->{added} }')" = dns.example.com ] &&
  ok "mihomo report: the own DoH named" || bad "mihomo doh report: $(q '$c->{added}')"
mt "mihomo: own DoH" "$tmp/c"
put doh https://9.9.9.9/dns-query
genm "$fx/ok-full.json" || bad "mihomo doh full refused: $(cat "$tmp/err")"
[ "$(j '$c->{dns}{nameserver}[0]')" = "https://9.9.9.9/dns-query#KS-DNS" ] && ok "mihomo doh: an address as the host" || bad "mihomo doh ip: $(j '$c->{dns}{nameserver}')"
mt "mihomo: own DoH with a full profile" "$tmp/c"
printf 'doh=http://dns.example.com/x\n' > "$SETTINGS"   # never written by ks; rules() locks down, the generator ignores it
genm "$fx/ok-minimal.json"
[ "$(j '$c->{dns}')" = "$(cat "$tmp/plain.dns")" ] && ok "mihomo doh: a bad value is ignored (our resolvers through the tunnel)" ||
  bad "mihomo bad doh: $(j '$c->{dns}')"
rm -f "$SETTINGS"
genm "$fx/ok-minimal.json"
[ "$(j '$c->{dns}')" = "$(cat "$tmp/plain.dns")" ] && ok "mihomo: no doh, DNS as before" || bad "mihomo no doh: $(j '$c->{dns}')"

# --- Xray: categories in one blackhole rule after ours
rm -f "$CORE_DIR/geosite.dat"
put adblock 1; put blockadult 1; put blocksocial 1; put blockbetting 1
genx "$fx/xray-panel.json" || bad "xray refused: $(cat "$tmp/err")"
[ "$(j '$c->{routing}{rules}[2]{inboundTag}[0]')" = direct-dns ] && ok "xray: no geosite.dat, no category rule" || bad "xray without geodata: $(j '$c->{routing}{rules}[2]')"
geo_on
genx "$fx/xray-panel.json" || bad "xray categories refused: $(cat "$tmp/err")"
[ "$(j '$c->{routing}{rules}[2]')" = '{"domain":["geosite:category-ads-all","geosite:category-porn","geosite:category-social-media-!cn","geosite:category-betting-ru"],"outboundTag":"block"}' ] &&
  ok "xray: the chosen categories to the blackhole before the subscription" || bad "xray categories: $(j '$c->{routing}{rules}[2]')"
cp "$tmp/c.direct" "$tmp/xcat.direct"; cp "$tmp/c.egress" "$tmp/xcat.egress"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "adblock" } @{ $c->{added} }')" = \
  "geosite:category-ads-all → block,geosite:category-porn → block,geosite:category-social-media-!cn → block,geosite:category-betting-ru → block" ] &&
  ok "xray report: the categories named" || bad "xray report: $(q '$c->{added}')"
xtest "xray: four categories" "$tmp/c"
rm -f "$SETTINGS"
genx "$fx/xray-panel.json"
cmp -s "$tmp/c.direct" "$tmp/xcat.direct" && cmp -s "$tmp/c.egress" "$tmp/xcat.egress" &&
  ok "xray: categories change neither the DIRECT signature nor egress" || bad "xray: categories changed direct/egress"
put blockadult 1
genx "$fx/xray-panel.json"
[ "$(j '$c->{routing}{rules}[2]')" = '{"domain":["geosite:category-porn"],"outboundTag":"block"}' ] && ok "xray: one category" || bad "xray one: $(j '$c->{routing}{rules}[2]')"
rm -f "$SETTINGS"

# --- Xray: own DoH first among the servers, routed to a server by its tag and its host
genx "$fx/xray-panel.json"; cp "$tmp/c.direct" "$tmp/x.direct"; cp "$tmp/c.egress" "$tmp/x.egress"
put doh https://dns.example.com/dns-query/abc123
genx "$fx/xray-panel.json" || bad "xray doh refused: $(cat "$tmp/err")"
[ "$(j '$c->{dns}{servers}[0]')" = '{"address":"https://dns.example.com/dns-query/abc123","tag":"ks-doh"}' ] &&
  [ "$(j '$c->{dns}{servers}[1]')" = '{"address":"https://1.1.1.1/dns-query","tag":"ks-doh"}' ] &&
  ok "xray doh: the own server first, Cloudflare DoH through a server when it fails" || bad "xray doh servers: $(j '$c->{dns}{servers}')"
# review of #14: a failed own DoH must never cascade to a template server routed DIRECT
# (direct-dns 77.88.8.8 → freedom): template servers stay only for their own domains
[ "$(j 'join ",", map { $_->{tag} . ":" . ($_->{skipFallback} ? "skip" : "fallback") . ":" . (ref $_->{domains} ? "domains" : "all") } @{ $c->{dns}{servers} }[2 .. $#{ $c->{dns}{servers} }]')" = \
  "direct-dns:skip:domains" ] && ok "xray doh: the template's servers only for their own domains, never as a fallback" ||
  bad "xray doh template servers: $(j '$c->{dns}{servers}')"
[ "$(q 'join ",", map { "$_->{item}:$_->{reason}" } grep { $_->{section} eq "dns" } @{ $c->{dropped} }')" = "8.8.8.8:own-doh,1.1.1.1:own-doh" ] &&
  ok "xray doh report: the template's general servers named as replaced" || bad "xray doh dropped: $(q '$c->{dropped}')"
[ "$(j '$c->{routing}{rules}[2]')" = '{"inboundTag":["ks-doh"],"outboundTag":"LT_1"}' ] &&
  [ "$(j '$c->{routing}{rules}[3]')" = '{"domain":["full:dns.example.com"],"outboundTag":"LT_1"}' ] &&
  ok "xray doh: its queries and its host to a server, before the subscription's rules" || bad "xray doh rules: $(j '[ @{ $c->{routing}{rules} }[2,3] ]')"
cmp -s "$tmp/c.direct" "$tmp/x.direct" && cmp -s "$tmp/c.egress" "$tmp/x.egress" &&
  ok "xray doh: DIRECT signature and egress as without it" || bad "xray doh changed direct/egress: $(diff "$tmp/x.direct" "$tmp/c.direct")"
grep -q abc123 "$tmp/c.report" && bad "xray doh: the path in the report" || ok "xray doh: only the host in the report"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "doh" } @{ $c->{added} }')" = dns.example.com ] &&
  ok "xray report: the own DoH named" || bad "xray doh report: $(q '$c->{added}')"
xtest "xray: own DoH" "$tmp/c"
put doh https://9.9.9.9/dns-query
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); $a->[0]{dns}{disableFallback} = JSON::PP::true; print JSON::PP->new->encode($a)' \
  < "$fx/xray-panel.json" > "$tmp/p.json"
genx "$tmp/p.json" || bad "xray doh ip refused: $(cat "$tmp/err")"
[ "$(j '$c->{routing}{rules}[3]')" = '{"ip":["9.9.9.9"],"outboundTag":"LT_1"}' ] && ok "xray doh: an address as the host" || bad "xray doh ip: $(j '$c->{routing}{rules}[3]')"
[ "$(j '$c->{dns}{disableFallback} ? "kept" : "gone"')" = kept ] && ok "xray doh: the template's disableFallback kept (own DoH alone)" ||
  bad "xray doh: disableFallback $(j '$c->{dns}{disableFallback}')"
xtest "xray: own DoH by address" "$tmp/c"
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); delete $a->[0]{dns}; print JSON::PP->new->encode($a)' \
  < "$fx/xray-panel.json" > "$tmp/p.json"
genx "$tmp/p.json" || bad "xray doh no dns refused: $(cat "$tmp/err")"
[ "$(j '$c->{dns}{servers}')" = '[{"address":"https://9.9.9.9/dns-query","tag":"ks-doh"},{"address":"https://1.1.1.1/dns-query","tag":"ks-doh"}]' ] &&
  ok "xray doh: no DNS in the template: Cloudflare DoH through a server after it" || bad "xray doh no dns: $(j '$c->{dns}')"
xtest "xray: own DoH without template DNS" "$tmp/c"
printf 'doh=https://user@dns.example.com/x\n' > "$SETTINGS"
genx "$fx/xray-panel.json"
[ "$(j '$c->{dns}{servers}[0]{tag}')" = direct-dns ] && ok "xray doh: a bad value is ignored" || bad "xray bad doh: $(j '$c->{dns}{servers}[0]')"
rm -f "$SETTINGS"

# --- a category switched on without geosite.dat blocks nothing: said and logged (review of #14)
EVENTS="$tmp/events.log"; diag_event() { :; }
rm -f "$CORE_DIR/geosite.dat"
block_geodata_note blocksocial 1 2>"$tmp/err"
grep -q 'blocksocial.*geosite.dat' "$EVENTS" && grep -q geosite.dat "$tmp/err" && ok "block without geosite.dat: logged and said" ||
  bad "block without geodata: $(cat "$EVENTS" "$tmp/err" 2>/dev/null)"
: > "$EVENTS"; block_geodata_note blocksocial 0 2>/dev/null; geo_on; block_geodata_note blocksocial 1 2>/dev/null
[ ! -s "$EVENTS" ] && ok "block: nothing logged when off or with geosite.dat" || bad "block note: $(cat "$EVENTS")"

# --- ks set doh: checked before it is written, "" clears; the config is rebuilt (core_apply_settings)
applied=0; core_apply_settings() { applied=$((applied + 1)); }
printf 'lan=1\n' > "$SETTINGS"
set_doh "https://dns.example.com/dns-query" 2>/dev/null && [ "$(setting doh "")" = https://dns.example.com/dns-query ] && [ "$applied" = 1 ] &&
  ok "set doh: written and the config rebuilt" || bad "set doh: $(cat "$SETTINGS") applied=$applied"
set_doh "http://dns.example.com/x" 2>"$tmp/err" && bad "set doh: took http" ||
  { [ "$(setting doh "")" = https://dns.example.com/dns-query ] && [ "$applied" = 1 ] && grep -q https "$tmp/err" &&
    ok "set doh: a bad address refused, nothing changed, the reason said" || bad "set doh bad: $(cat "$SETTINGS") $(cat "$tmp/err")"; }
core_apply_settings() { applied=$((applied + 1)); return 1; }
set_doh "https://other.example.com/q" 2>/dev/null && bad "set doh: a failed rebuild reported as done" ||
  { [ "$(setting doh "")" = https://dns.example.com/dns-query ] && ok "set doh: a failed rebuild puts the old value back" ||
    bad "set doh rollback: $(cat "$SETTINGS")"; }
core_apply_settings() { applied=$((applied + 1)); }
applied=1
set_doh "" && ! grep -q '^doh' "$SETTINGS" && grep -qx lan=1 "$SETTINGS" && [ "$applied" = 2 ] && ok "set doh \"\": the line gone, the rest kept" ||
  bad "set doh clear: $(cat "$SETTINGS")"
rm -f "$SETTINGS"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
