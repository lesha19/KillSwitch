#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Named routing profiles (ADR 0034, issue #30): the person's chosen profile reaches ks inside the
# subscription's profile as "x-ks-routing" (mihomo: a top-level key; Xray: in the first config).
# Its block, proxy and direct lists become rules in front of the subscription's, labelled as the
# profile's in the report. Its DIRECT part is in the DIRECT signature, so a profile that sends
# anything past the VPN needs the admin, as a subscription's DIRECT does (ADR 0013); block and proxy
# entries change nothing pf lets out. No root, no network.
#   Helper/tests/core-routing-profile.sh   (XRAY=/MIHOMO= to check the configs with the real binaries)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
fx="$here/fixtures"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
DIR="$T"; CORE_DIR="$T/core"; mkdir -p "$CORE_DIR" "$T/home"
SETTINGS="$DIR/settings"; EVENTS="$DIR/events.log"
# the shipped geodata: GEOSITE/GEOIP entries are taken only with it
for f in geosite.dat geoip.metadb geoip.dat; do [ ! -s "$here/../$f" ] || { cp "$here/../$f" "$CORE_DIR/" && cp "$here/../$f" "$T/home/"; }; done
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; fi.example.com) echo 203.0.113.30 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "$2"; }
# with_routing <in> <out> <perl: the hint as $h> [xray]: the profile with "x-ks-routing" set
with_routing() { /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $h; eval $ARGV[0]; die $@ if $@;
  if ($ARGV[1]) { $p->[0]{"x-ks-routing"} = $h } else { $p->{"x-ks-routing"} = $h } print JSON::PP->new->encode($p)' "$3" "${4:-}" < "$1" > "$2"; }
FULL='$h = { name => "RU напрямую", order => ["block", "proxy", "direct"],
  block => { sites => ["domain:ads.example.com"], ips => [] },
  proxy => { sites => ["geosite:youtube", "full:www.example.org"], ips => ["203.0.113.0/24"] },
  direct => { sites => ["domain:ru", "keyword:yandex"], ips => ["geoip:ru"] } }'

# --- mihomo. The fixture's server group also holds DIRECT; base.json is it without, so that
# "proxy" really means through the VPN
printf 'core=mihomo\n' > "$SETTINGS"
gm() { core_generate_mihomo "$1" "$T/$2" "$T/$2.srv" 2>"$T/err"; }
/usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); for (@{ $p->{"proxy-groups"} }) { $_->{proxies} = [ grep { $_ ne "DIRECT" } @{ $_->{proxies} } ] } print JSON::PP->new->encode($p)' \
  < "$fx/ok-full.json" > "$T/base.json"
gm "$T/base.json" m-none || bad "no profile refused: $(cat "$T/err")"
with_routing "$T/base.json" "$T/full.json" "$FULL"
gm "$T/full.json" m-full || bad "profile refused: $(cat "$T/err")"
[ "$(j 'join " | ", @{ $c->{rules} }[1 .. 7]' "$T/m-full")" = \
  "DOMAIN-SUFFIX,ads.example.com,REJECT | GEOSITE,youtube,🚀 Выбор сервера | DOMAIN,www.example.org,🚀 Выбор сервера | IP-CIDR,203.0.113.0/24,🚀 Выбор сервера | DOMAIN-SUFFIX,ru,DIRECT | DOMAIN-KEYWORD,yandex,DIRECT | GEOIP,RU,DIRECT" ] &&
  ok "mihomo: block, proxy (where the subscription sends the rest), direct, in the profile's order" || bad "rules: $(j '$c->{rules}' "$T/m-full")"
[ "$(j '$c->{rules}[0]' "$T/m-full")" = "IP-CIDR,198.18.0.0/16,REJECT,no-resolve" ] && [ "$(j '$c->{rules}[8]' "$T/m-full")" = "RULE-SET,ru-blocked,🚀 Выбор сервера" ] &&
  ok "  after KillSwitch's own, before the subscription's" || bad "  around: $(j '$c->{rules}' "$T/m-full")"
[ "$(j 'join ",", map { $_->{from} } @{ $c->{rules} }[0 .. 8]' "$T/m-full.report")" = killswitch,profile,profile,profile,profile,profile,profile,profile,subscription ] &&
  [ "$(j 'join ",", map { $_->{profile} // "" } @{ $c->{rules} }[1 .. 7]' "$T/m-full.report")" = "RU напрямую,RU напрямую,RU напрямую,RU напрямую,RU напрямую,RU напрямую,RU напрямую" ] &&
  ok "  report: each rule from the profile, named" || bad "  report: $(j '[ @{ $c->{rules} }[0 .. 8] ]' "$T/m-full.report")"
grep -q $'^rule\tDOMAIN-SUFFIX,ru,DIRECT$' "$T/m-full.direct" && grep -q $'^rule\tGEOIP,RU,DIRECT$' "$T/m-full.direct" &&
  ! grep -v '^profile' "$T/m-full.direct" | grep -q 'REJECT\|example.org' &&
  ok "  its DIRECT rules in the DIRECT signature (an import or refresh with them needs the admin)" || bad "  direct: $(cat "$T/m-full.direct")"
[ "$(grep '^profile' "$T/m-full.direct")" = "profile	$(j 'JSON::PP->new->canonical->encode([ @{ $c->{rules} }[1 .. 7] ])' "$T/m-full")" ] &&
  ok "  and the whole profile in order, block and proxy rules too (they shadow the direct ones)" || bad "  profile line: $(grep '^profile' "$T/m-full.direct")"
grep -qx rules "$T/m-full.egress" && ok "  egress: rules" || bad "  egress: $(cat "$T/m-full.egress")"
cmp -s "$T/m-full.srv" "$T/m-none.srv" && ok "  the servers for pf unchanged" || bad "  servers"
if [ -x "$MIHOMO" ]; then out=$("$MIHOMO" -t -d "$T/home" -f "$T/m-full" 2>&1) && ok "  mihomo -t" || bad "  mihomo -t: $(tail -2 <<<"$out")"
else echo "skip  mihomo -t (no $MIHOMO)"; fi
with_routing "$T/base.json" "$T/safe.json" '$h = { name => "Без рекламы", block => { sites => ["domain:ads.example.com"] }, proxy => { ips => ["geoip:us"] } }'
gm "$T/safe.json" m-safe || bad "block/proxy profile refused: $(cat "$T/err")"
cmp -s "$T/m-safe.direct" "$T/m-none.direct" && cmp -s "$T/m-safe.egress" "$T/m-none.egress" &&
  ok "a profile that only blocks or sends through the VPN: DIRECT and egress as without it (no password)" || bad "safe: $(diff "$T/m-none.direct" "$T/m-safe.direct")"
[ "$(j 'join " | ", @{ $c->{rules} }[1, 2]' "$T/m-safe")" = "DOMAIN-SUFFIX,ads.example.com,REJECT | GEOIP,US,🚀 Выбор сервера" ] &&
  ok "  default order block, proxy, direct" || bad "  order: $(j '$c->{rules}' "$T/m-safe")"
with_routing "$T/base.json" "$T/odd.json" '$h = { name => "x", direct => { sites => ["regexp:.*\\.ru", "ext:foo.dat:bar", "geosite:category-ru", "domain:bad,comma"], ips => ["geoip:!ru", "300.1.1.1/8", "10.0.0.0/8"] } }'
gm "$T/odd.json" m-odd || bad "odd entries refused the import: $(cat "$T/err")"
[ "$(j 'join " | ", grep { /DIRECT$/ && !/ru-blocked|local-inline|DOMAIN-SUFFIX,ru,/ } @{ $c->{rules} }' "$T/m-odd")" = "GEOSITE,category-ru,DIRECT | IP-CIDR,10.0.0.0/8,DIRECT" ] &&
  [ "$(j 'join ",", map { "$_->{item}=$_->{reason}" } grep { $_->{section} eq "routing-profile" } @{ $c->{dropped} }' "$T/m-odd.report")" = \
    "regexp:.*\\.ru=unsupported,ext:foo.dat:bar=unsupported,domain:bad,comma=bad-value,geoip:!ru=unsupported,300.1.1.1/8=bad-value" ] &&
  ok "entries it cannot take: left out with the reason (regexp, ext:, negation, a bad value)" || bad "odd: $(j '$c->{rules}' "$T/m-odd") $(j '$c->{dropped}' "$T/m-odd.report")"
CORE_DIR="$T/nogeo"; mkdir -p "$CORE_DIR"
gm "$T/full.json" m-nogeo || bad "no geodata: $(cat "$T/err")"
[ "$(j 'scalar grep { /\AGEO(SITE|IP),/ } @{ $c->{rules} }' "$T/m-nogeo")" = 0 ] &&
  [ "$(j 'join ",", map { $_->{reason} } grep { $_->{section} eq "routing-profile" } @{ $c->{dropped} }' "$T/m-nogeo.report")" = "geodata:geosite,geodata:geoip" ] &&
  ok "  GEOSITE/GEOIP without the shipped geodata: left out (never downloaded)" || bad "  nogeo: $(j '$c->{rules}' "$T/m-nogeo")"
CORE_DIR="$T/core"
for h in '$h = []' '$h = { name => "x", direct => [] }' '$h = { name => "x", direct => { sites => [ {} ] } }' '$h = { name => "", block => {} }' \
         '$h = { name => "x", via => { sites => ["domain:a.b"] } }' '$h = { name => "x", order => ["direct"] }' \
         '$h = { name => "x", direct => { sites => [ map { "domain:a$_.example" } 1 .. 10001 ] } }' '$h = { name => "a\nb" }'; do
  with_routing "$T/base.json" "$T/bad.json" "$h"
  if gm "$T/bad.json" m-bad; then bad "malformed hint taken: $h"; fi
done
ok "a malformed profile hint refuses the import (shape, unknown key or action, name, more than 10000 entries)"
with_routing "$fx/ok-full.json" "$T/dgroup.json" '$h = { name => "x", proxy => { sites => ["domain:example.org"] } }'
gm "$T/dgroup.json" m-dgroup && grep -q $'^rule\tDOMAIN-SUFFIX,example.org,' "$T/m-dgroup.direct" &&
  ok "\"proxy\" into a group that also holds DIRECT: in the signature too (it can go direct)" || bad "dgroup: $(cat "$T/m-dgroup.direct")"

# --- the DIRECT part needs the admin, the rest does not: refresh_check against the last import
SERVERS="$T/m-none.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/m-none.direct"; : > "$T/pins"
refresh_check "$T/m-safe.srv" "$T/pins" "$T/m-safe.direct" 2>/dev/null && ok "refresh to a block/proxy profile: no password" || bad "safe profile needs the admin"
if refresh_check "$T/m-full.srv" "$T/pins" "$T/m-full.direct" 2>"$T/rc.err"; then bad "a profile with DIRECT passed without the admin"
else grep -q 'DIRECT' "$T/rc.err" && ok "refresh to a profile with DIRECT: exit 3, the admin approves it (as a subscription's DIRECT)" || bad "reason: $(cat "$T/rc.err")"; fi

# --- Xray: the hint in the first config; rules after KillSwitch's own, before the subscription's
printf 'core=xray\n' > "$SETTINGS"
gx() { core_generate_xray "$1" "$T/$2" "$T/$2.srv" 2>"$T/err"; }
gx "$fx/xray-panel.json" x-none || bad "xray no profile: $(cat "$T/err")"
with_routing "$fx/xray-panel.json" "$T/xfull.json" "$FULL" 1
gx "$T/xfull.json" x-full || bad "xray profile refused: $(cat "$T/err")"
[ "$(j 'JSON::PP->new->canonical->encode([ map { { %$_ } } @{ $c->{routing}{rules} }[2 .. 7] ])' "$T/x-full")" = \
  '[{"domain":["domain:ads.example.com"],"outboundTag":"block"},{"domain":["geosite:youtube","full:www.example.org"],"outboundTag":"LT_1"},{"ip":["203.0.113.0/24"],"outboundTag":"LT_1"},{"domain":["domain:ru","keyword:yandex"],"outboundTag":"direct"},{"ip":["geoip:ru"],"outboundTag":"direct"},{"inboundTag":["direct-dns"],"outboundTag":"direct","type":"field"}]' ] &&
  ok "Xray: block, proxy (the running server), direct rules after KillSwitch's own, then the subscription's" || bad "xray rules: $(j '$c->{routing}{rules}' "$T/x-full")"
[ "$(j 'exists $c->{"x-ks-routing"} ? 1 : 0' "$T/x-full")" = 0 ] && ok "  the hint itself not in the config" || bad "  hint left in the config"
[ "$(j 'join ",", map { $_->{from} . ":" . ($_->{profile} // "") } @{ $c->{rules} }[2 .. 6]' "$T/x-full.report")" = \
  "profile:RU напрямую,profile:RU напрямую,profile:RU напрямую,profile:RU напрямую,profile:RU напрямую" ] &&
  ok "  report: from the profile, named" || bad "  report: $(j '$c->{rules}' "$T/x-full.report")"
grep -q 'domain:ru' "$T/x-full.direct" && grep -q 'geoip:ru' "$T/x-full.direct" && ! grep -v '^profile' "$T/x-full.direct" | grep -q 'ads.example\|youtube' &&
  ok "  its DIRECT rules in the signature" || bad "  direct: $(cat "$T/x-full.direct")"
[ "$(grep '^profile' "$T/x-full.direct")" = "profile	$(j 'JSON::PP->new->canonical->encode([ @{ $c->{routing}{rules} }[2 .. 6] ])' "$T/x-full")" ] &&
  ok "  and the whole profile in order (block and proxy rules shadow the direct ones)" || bad "  profile line: $(grep '^profile' "$T/x-full.direct")"
cmp -s "$T/x-full.srv" "$T/x-none.srv" && ok "  the servers for pf unchanged" || bad "  servers"
if [ -x "$XRAY" ]; then out=$(XRAY_LOCATION_ASSET=$CORE_DIR "$XRAY" run -test -format json -c "$T/x-full" 2>&1) && ok "  xray run -test" || bad "  xray run -test: $(tail -2 <<<"$out")"
else echo "skip  xray run -test (no $XRAY)"; fi
put_setting xrayserver "#2"
with_routing "$fx/xray-panel.json" "$T/x2.json" '$h = { name => "x", direct => { sites => ["domain:ru"] } }; my $b = JSON::PP->new->decode(JSON::PP->new->encode($p->[0])); $b->{remarks} = "#2"; delete $b->{"x-ks-routing"}; push @$p, $b' 1
KS_APPROVE_ALL=1 gx "$T/x2.json" x-two || bad "two hosts: $(cat "$T/err")"
[ "$(wc -l < "$T/x-two.approved" | tr -d ' ')" = 1 ] && grep -q 'domain:ru' "$T/x-two.direct" &&
  ok "  every host gets the profile (the hint of the first config), each host's approved DIRECT includes it" || bad "  hosts: $(cat "$T/x-two.approved")"
with_routing "$fx/xray-panel.json" "$T/xsafe.json" '$h = { name => "x", block => { sites => ["domain:ads.example.com"] } }' 1
gx "$T/xsafe.json" x-safe && cmp -s "$T/x-safe.direct" "$T/x-none.direct" && ok "  a block-only profile: DIRECT as without it" || bad "  xsafe: $(diff "$T/x-none.direct" "$T/x-safe.direct")"


# --- the approval is bound to the whole profile (review B1): rules that do not go direct sit in
# front of the direct ones and shadow them, so with anything of the profile going direct, all its
# rules in order are in the signature. An exception through the VPN or a block taken away, or the
# order changed, needs the admin; the direct rules alone being the same is not enough
# b1 <core> <gen> <base> [xray]: approved A, then each change against it
b1() {
  local core=$1 gen=$2 base=$3 x=${4:-} p
  printf 'core=%s\n' "$core" > "$SETTINGS"
  with_routing "$base" "$T/b1-A.json" '$h = { name => "A", block => { sites => ["domain:ads.example.com"] }, proxy => { sites => ["domain:a.example.com"] }, direct => { sites => ["domain:example.com"] } }' "$x"
  with_routing "$base" "$T/b1-noproxy.json" '$h = { name => "A", block => { sites => ["domain:ads.example.com"] }, direct => { sites => ["domain:example.com"] } }' "$x"
  with_routing "$base" "$T/b1-noblock.json" '$h = { name => "A", proxy => { sites => ["domain:a.example.com"] }, direct => { sites => ["domain:example.com"] } }' "$x"
  with_routing "$base" "$T/b1-order.json" '$h = { name => "A", order => ["direct", "proxy", "block"], block => { sites => ["domain:ads.example.com"] }, proxy => { sites => ["domain:a.example.com"] }, direct => { sites => ["domain:example.com"] } }' "$x"
  for p in A noproxy noblock order; do "$gen" "$T/b1-$p.json" "b1-$core-$p" || bad "$core b1 $p: $(cat "$T/err")"; done
  SERVERS="$T/b1-$core-A.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/b1-$core-A.direct"; : > "$T/pins"
  refresh_check "$T/b1-$core-A.srv" "$T/pins" "$T/b1-$core-A.direct" 2>/dev/null && ok "$core: the approved profile again: no password" || bad "$core: the same profile needs the admin"
  for p in noproxy noblock order; do
    refresh_check "$T/b1-$core-$p.srv" "$T/pins" "$T/b1-$core-$p.direct" 2>/dev/null; rc=$?
    [ "$rc" = 3 ] && ok "$core: the same direct rules, $p: exit 3 (the admin)" || bad "$core: $p passed without the admin (rc $rc)"
  done
}
b1 mihomo gm "$T/base.json"
b1 xray gx "$fx/xray-panel.json" 1

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
