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
grep -q $'^profile-rule\tDOMAIN-SUFFIX,ru,DIRECT$' "$T/m-full.direct" && grep -q $'^profile-rule\tGEOIP,RU,DIRECT$' "$T/m-full.direct" &&
  ! grep -v '^profile' "$T/m-full.direct" | grep -q 'REJECT\|example.org' &&
  ok "  its DIRECT rules in the DIRECT signature (an import or refresh with them needs the admin)" || bad "  direct: $(cat "$T/m-full.direct")"
[ "$(grep $'^profile\t' "$T/m-full.direct")" = "profile	$(j 'JSON::PP->new->canonical->encode([ @{ $c->{rules} }[1 .. 7] ])' "$T/m-full")" ] &&
  ok "  and the whole profile in order, block and proxy rules too (they shadow the direct ones)" || bad "  profile line: $(grep $'^profile\t' "$T/m-full.direct")"
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
gm "$T/dgroup.json" m-dgroup && grep -q $'^profile-rule\tDOMAIN-SUFFIX,example.org,' "$T/m-dgroup.direct" &&
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
[ "$(grep $'^profile\t' "$T/x-full.direct")" = "profile	$(j 'JSON::PP->new->canonical->encode([ @{ $c->{routing}{rules} }[2 .. 6] ])' "$T/x-full")" ] &&
  ok "  and the whole profile in order (block and proxy rules shadow the direct ones)" || bad "  profile line: $(grep $'^profile\t' "$T/x-full.direct")"
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

# --- Xray: the subscription's freedom outbound is in the signature whenever something goes
# direct through it, also when only the profile or split apps do (review S1): a "redirect" added to
# it sends the person's direct traffic elsewhere
printf 'core=xray\n' > "$SETTINGS"
s1panel() { /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $c = $p->[0];
  $c->{routing}{rules} = [ grep { ($_->{outboundTag} // "") ne "direct" } @{ $c->{routing}{rules} } ]; delete $c->{dns};
  for (@{ $c->{outbounds} }) { $_->{settings} = { redirect => $ARGV[0] } if $_->{protocol} eq "freedom" && length $ARGV[0] }
  $#$p = 0; print JSON::PP->new->encode($p)' "$1" < "$fx/xray-panel.json"; }
s1panel "" > "$T/s1-plain.json"; s1panel "198.51.100.7:443" > "$T/s1-redir.json"
for v in plain redir; do
  with_routing "$T/s1-$v.json" "$T/s1-$v-p.json" '$h = { name => "P", direct => { sites => ["domain:example.com"] } }' 1
  gx "$T/s1-$v-p.json" s1-$v-p || bad "s1 $v: $(cat "$T/err")"
done
! cmp -s "$T/s1-plain-p.direct" "$T/s1-redir-p.direct" && grep -q '^outbound	.*redirect' "$T/s1-redir-p.direct" &&
  ok "Xray: the freedom outbound the profile's direct rules use is in the signature" || bad "s1 profile: $(cat "$T/s1-redir-p.direct")"
put_setting splitapps /Applications/Foo.app
for v in plain redir; do gx "$T/s1-$v.json" s1-$v-a || bad "s1 apps $v: $(cat "$T/err")"; done
put_setting splitapps ""
! cmp -s "$T/s1-plain-a.direct" "$T/s1-redir-a.direct" && grep -q '^outbound	.*redirect' "$T/s1-redir-a.direct" &&
  ok "  and the one split apps use" || bad "s1 apps: $(cat "$T/s1-redir-a.direct")"

# --- a name of up to 64 characters, as the app allows, whatever the script (review S2: the
# helper counted UTF-8 bytes, so 33 Cyrillic letters refused every import and refresh)
s2name() { /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>);
  my $h = { name => "я" x $ARGV[0], block => { sites => ["domain:ads.example.com"] } }; utf8::decode($h->{name});
  if ($ARGV[1]) { $p->[0]{"x-ks-routing"} = $h } else { $p->{"x-ks-routing"} = $h } print JSON::PP->new->utf8->encode($p)' "$2" "${3:-}" < "$1"; }
printf 'core=mihomo\n' > "$SETTINGS"
s2name "$T/base.json" 64 > "$T/s2.json"; gm "$T/s2.json" s2-m && ok "mihomo: a name of 64 Cyrillic letters" || bad "mihomo 64 letters: $(cat "$T/err")"
[ "$(j '$c->{rules}[1]' "$T/s2-m")" = "DOMAIN-SUFFIX,ads.example.com,REJECT" ] && ok "  its rules applied" || bad "  rules: $(j '$c->{rules}' "$T/s2-m")"
s2name "$T/base.json" 65 > "$T/s2.json"; if gm "$T/s2.json" s2-m65; then bad "mihomo: 65 letters taken"; else ok "  65: refused"; fi
printf 'core=xray\n' > "$SETTINGS"
s2name "$fx/xray-panel.json" 64 1 > "$T/s2x.json"; gx "$T/s2x.json" s2-x && ok "Xray: a name of 64 Cyrillic letters" || bad "xray 64 letters: $(cat "$T/err")"
s2name "$fx/xray-panel.json" 65 1 > "$T/s2x.json"; if gx "$T/s2x.json" s2-x65; then bad "xray: 65 letters taken"; else ok "  65: refused"; fi

# --- a geosite or geoip code the shipped geodata does not have is left out with the reason, like
# any entry the core cannot take (review S3): the core refused the whole config, so an active
# profile with one refused every import and refresh
if [ -s "$here/../geosite.dat" ] && [ -s "$here/../geoip.dat" ]; then
  S3='$h = { name => "x", direct => { sites => ["geosite:nonexistent-zzz", "geosite:YouTube"], ips => ["geoip:zz", "geoip:ru"] } }'
  printf 'core=mihomo\n' > "$SETTINGS"
  with_routing "$T/base.json" "$T/s3.json" "$S3"
  gm "$T/s3.json" s3-m || bad "mihomo unknown codes: $(cat "$T/err")"
  [ "$(j 'join " | ", grep { /\AGEO/ } @{ $c->{rules} }' "$T/s3-m")" = "GEOSITE,youtube,DIRECT | GEOIP,ZZ,DIRECT | GEOIP,RU,DIRECT" ] &&
    [ "$(j 'join ",", map { "$_->{item}=$_->{reason}" } grep { $_->{section} eq "routing-profile" } @{ $c->{dropped} }' "$T/s3-m.report")" = "geosite:nonexistent-zzz=geodata-code:geosite" ] &&
    ok "mihomo: an unknown geosite code left out with the reason (GEOIP of an unknown country only never matches)" || bad "mihomo s3: $(j '$c->{rules}' "$T/s3-m") $(j '$c->{dropped}' "$T/s3-m.report")"
  if [ -x "$MIHOMO" ]; then out=$("$MIHOMO" -t -d "$T/home" -f "$T/s3-m" 2>&1) && ok "  mihomo -t" || bad "  mihomo -t: $(tail -2 <<<"$out")"; fi
  printf 'core=xray\n' > "$SETTINGS"
  with_routing "$fx/xray-panel.json" "$T/s3x.json" "$S3" 1
  gx "$T/s3x.json" s3-x || bad "xray unknown codes: $(cat "$T/err")"
  [ "$(j 'JSON::PP->new->canonical->encode([ map { $_->{domain} // $_->{ip} } @{ $c->{routing}{rules} }[2, 3] ])' "$T/s3-x")" = '[["geosite:youtube"],["geoip:ru"]]' ] &&
    [ "$(j 'join ",", map { "$_->{item}=$_->{reason}" } grep { $_->{section} eq "routing-profile" } @{ $c->{dropped} }' "$T/s3-x.report")" = "geosite:nonexistent-zzz=geodata-code:geosite,geoip:zz=geodata-code:geoip" ] &&
    ok "Xray: unknown geosite and geoip codes left out with the reason" || bad "xray s3: $(j '$c->{routing}{rules}' "$T/s3-x") $(j '$c->{dropped}' "$T/s3-x.report")"
  if [ -x "$XRAY" ]; then out=$(XRAY_LOCATION_ASSET=$CORE_DIR "$XRAY" run -test -format json -c "$T/s3-x" 2>&1) && ok "  xray run -test" || bad "  xray run -test: $(tail -2 <<<"$out")"; fi
else echo "skip  unknown geodata codes (no Helper/geosite.dat, geoip.dat: Helper/fetch-geodata.sh)"; fi

# --- turning a direct profile off needs no password (review S5): a signature whose every line
# is in the approved one sends past the VPN only what was approved (ADR 0034). The profile's own
# direct rules are marked as the profile's, so a subscription cannot take them over
# s5 <core> <gen> <base> [xray]
s5() {
  local core=$1 gen=$2 base=$3 x=${4:-} rc
  printf 'core=%s\n' "$core" > "$SETTINGS"
  with_routing "$base" "$T/s5-on.json" '$h = { name => "A", proxy => { sites => ["domain:a.example.com"] }, direct => { sites => ["domain:example.com", "domain:example.net"] } }' "$x"
  with_routing "$base" "$T/s5-less.json" '$h = { name => "A", proxy => { sites => ["domain:a.example.com"] }, direct => { sites => ["domain:example.com"] } }' "$x"
  with_routing "$base" "$T/s5-safe.json" '$h = { name => "B", block => { sites => ["domain:ads.example.com"] } }' "$x"
  "$gen" "$T/s5-on.json" "s5-$core-on" || bad "s5 on: $(cat "$T/err")"
  "$gen" "$base" "s5-$core-off" || bad "s5 off: $(cat "$T/err")"
  "$gen" "$T/s5-less.json" "s5-$core-less" || bad "s5 less: $(cat "$T/err")"
  "$gen" "$T/s5-safe.json" "s5-$core-safe" || bad "s5 safe: $(cat "$T/err")"
  grep -q '^profile-rule	' "$T/s5-$core-on.direct" && ! grep -q '^rule	.*example\.com' "$T/s5-$core-on.direct" &&
    ok "$core: the profile's direct rules are marked as its own in the signature" || bad "$core: marks: $(cat "$T/s5-$core-on.direct")"
  SERVERS="$T/s5-$core-on.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/s5-$core-on.direct"; : > "$T/pins"
  refresh_check "$T/s5-$core-off.srv" "$T/pins" "$T/s5-$core-off.direct" 2>/dev/null && ok "$core: the direct profile turned off («Как в подписке»): no password" || bad "$core: turning it off needs the admin"
  refresh_check "$T/s5-$core-safe.srv" "$T/pins" "$T/s5-$core-safe.direct" 2>/dev/null && ok "$core: replaced by a profile that only blocks: no password" || bad "$core: block-only replacement needs the admin"
  refresh_check "$T/s5-$core-less.srv" "$T/pins" "$T/s5-$core-less.direct" 2>/dev/null; rc=$?
  [ "$rc" = 3 ] && ok "$core: the profile itself changed (even narrower): the admin (its whole content is approved)" || bad "$core: changed profile rc $rc"
  # the subscription now sends what was the profile's direct rule, with the profile off
  if [ -z "$x" ]; then
    /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); unshift @{ $p->{rules} }, "DOMAIN-SUFFIX,example.com,DIRECT"; print JSON::PP->new->encode($p)' < "$base" > "$T/s5-takeover.json"
  else
    /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); unshift @{ $p->[0]{routing}{rules} }, { domain => ["domain:example.com", "domain:example.net"], outboundTag => "direct" }; print JSON::PP->new->encode($p)' < "$base" > "$T/s5-takeover.json"
  fi
  "$gen" "$T/s5-takeover.json" "s5-$core-takeover" || bad "s5 takeover: $(cat "$T/err")"
  refresh_check "$T/s5-$core-takeover.srv" "$T/pins" "$T/s5-$core-takeover.direct" 2>/dev/null; rc=$?
  [ "$rc" = 3 ] && ok "$core: the subscription taking over the profile's direct rule: the admin" || bad "$core: takeover rc $rc"
}
s5 mihomo gm "$T/base.json"
s5 xray gx "$fx/xray-panel.json" 1

# --- re-review F1/F3: only the profile's own lines may be fewer. A subscription rule to a group or
# balancer that can go direct is itself a signature line; dropping or moving it lets what it took
# fall onto an approved DIRECT rule behind it. The rest of the signature must stay as approved, in
# order
printf 'core=mihomo\n' > "$SETTINGS"
f1m() { /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $s = "🚀 Выбор сервера";
  my %r = (1 => "DOMAIN-SUFFIX,bank.ru,$s", 2 => "DOMAIN-SUFFIX,ru,DIRECT", 3 => "MATCH,$s");
  $p->{rules} = [ map { $r{$_} } split //, $ARGV[0] ]; delete $p->{"rule-providers"}; print JSON::PP->new->encode($p)' "$1" < "$fx/ok-full.json" > "$T/f1-$1.json"
  gm "$T/f1-$1.json" "f1-m$1" || bad "f1 $1: $(cat "$T/err")"; }
f1m 123; f1m 23; f1m 213
SERVERS="$T/f1-m123.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/f1-m123.direct"; : > "$T/pins"
for v in 23 213; do
  refresh_check "$T/f1-m$v.srv" "$T/pins" "$T/f1-m$v.direct" 2>/dev/null; rc=$?
  [ "$rc" = 3 ] && ok "mihomo: a rule to a group holding DIRECT dropped or moved in front of DIRECT ($v): the admin" || bad "mihomo f1 $v: rc $rc"
done
printf 'core=xray\n' > "$SETTINGS"
f1x() { /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $c = $p->[0];
  push @{ $c->{routing}{balancers} }, { tag => "vpn-lb", selector => ["LT_1"], fallbackTag => "direct" };
  my @r = ({ domain => ["domain:bank.ru"], balancerTag => "vpn-lb" }, { domain => ["domain:ru"], outboundTag => "direct" });
  unshift @{ $c->{routing}{rules} }, ($ARGV[0] eq "A" ? @r : $ARGV[0] eq "B" ? $r[1] : @r[1, 0]);
  $#$p = 0; print JSON::PP->new->encode($p)' "$1" < "$fx/xray-panel.json" > "$T/f1x-$1.json"
  gx "$T/f1x-$1.json" "f1-x$1" || bad "f1x $1: $(cat "$T/err")"; }
f1x A; f1x B; f1x C
SERVERS="$T/f1-xA.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/f1-xA.direct"; : > "$T/pins"
for v in B C; do
  refresh_check "$T/f1-x$v.srv" "$T/pins" "$T/f1-x$v.direct" 2>/dev/null; rc=$?
  [ "$rc" = 3 ] && ok "Xray: a rule to a balancer falling back to freedom dropped or moved ($v): the admin" || bad "xray f1 $v: rc $rc"
done
# F3: split app turned off, the subscription carries the same process rule
put_setting splitapps /Applications/Foo.app
gx "$fx/xray-panel.json" f3-on || bad "f3 on: $(cat "$T/err")"
put_setting splitapps ""
/usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>);
  unshift @{ $p->[0]{routing}{rules} }, { process => ["/Applications/Foo.app/"], outboundTag => "direct" }; print JSON::PP->new->encode($p)' < "$fx/xray-panel.json" > "$T/f3.json"
gx "$T/f3.json" f3-sub || bad "f3 sub: $(cat "$T/err")"
SERVERS="$T/f3-on.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/f3-on.direct"; : > "$T/pins"
refresh_check "$T/f3-sub.srv" "$T/pins" "$T/f3-sub.direct" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && ok "Xray: the subscription taking over a split app that was turned off: the admin" || bad "f3: rc $rc"

# --- re-review F2: a subscription with nothing direct of its own and a profile with direct entries:
# pf lets the core out (egress rules), or the profile's direct sites are blocked
printf 'core=mihomo\n' > "$SETTINGS"
/usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); delete $p->{"rule-providers"}; $p->{rules} = ["MATCH,🚀 Выбор сервера"]; print JSON::PP->new->encode($p)' < "$T/base.json" > "$T/f2-clean.json"
with_routing "$T/f2-clean.json" "$T/f2-p.json" '$h = { name => "P", direct => { sites => ["domain:example.com"] } }'
gm "$T/f2-clean.json" f2-none || bad "f2 clean: $(cat "$T/err")"
gm "$T/f2-p.json" f2-p || bad "f2 profile: $(cat "$T/err")"
! grep -qx rules "$T/f2-none.egress" && grep -qx rules "$T/f2-p.egress" &&
  ok "mihomo: a clean subscription with a direct profile: egress rules (pf lets its direct sites out)" || bad "f2 egress: [$(cat "$T/f2-none.egress")] [$(cat "$T/f2-p.egress")]"

# --- re-review nit: Xray without a freedom outbound and a profile that only blocks: no warnings
printf 'core=xray\n' > "$SETTINGS"
/usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $c = $p->[0];
  $c->{routing}{rules} = [ grep { ($_->{outboundTag} // "") ne "direct" } @{ $c->{routing}{rules} } ];
  $c->{outbounds} = [ grep { $_->{protocol} ne "freedom" } @{ $c->{outbounds} } ]; delete $c->{dns};
  $#$p = 0; print JSON::PP->new->encode($p)' < "$fx/xray-panel.json" > "$T/nofree.json"
with_routing "$T/nofree.json" "$T/nofree-b.json" '$h = { name => "B", block => { sites => ["domain:ads.example.com"] } }' 1
gx "$T/nofree-b.json" nofree-b && [ ! -s "$T/err" ] && ok "Xray: no freedom outbound, a block-only profile: nothing on stderr" || bad "nofree: [$(cat "$T/err")]"

# --- re-review F4: the refusal says which part changed, so the app does not guess: [profile],
# [subscription] or both (a block/proxy-only profile too, when its "proxy" group can go direct)
printf 'core=mihomo\n' > "$SETTINGS"
SERVERS="$T/f1-m123.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/f1-m123.direct"; : > "$T/pins"
refresh_check "$T/f1-m23.srv" "$T/pins" "$T/f1-m23.direct" 2>"$T/rc.err"
grep -q '(DIRECT) \[subscription\]:' "$T/rc.err" && ok "refusal: [subscription] when only the subscription's part changed" || bad "who sub: $(cat "$T/rc.err")"
with_routing "$T/f1-123.json" "$T/f4-p.json" '$h = { name => "P", proxy => { sites => ["domain:example.org"] } }'
gm "$T/f4-p.json" f4-p || bad "f4 p: $(cat "$T/err")"
refresh_check "$T/f4-p.srv" "$T/pins" "$T/f4-p.direct" 2>"$T/rc.err"
grep -q '(DIRECT) \[profile\]:' "$T/rc.err" && ok "  [profile]: a proxy-only profile into a group that holds DIRECT" || bad "who profile: $(cat "$T/rc.err")"
with_routing "$T/f1-23.json" "$T/f4-b.json" '$h = { name => "P", direct => { sites => ["domain:example.com"] } }'
gm "$T/f4-b.json" f4-b || bad "f4 b: $(cat "$T/err")"
refresh_check "$T/f4-b.srv" "$T/pins" "$T/f4-b.direct" 2>"$T/rc.err"
grep -q '(DIRECT) \[profile,subscription\]:' "$T/rc.err" && ok "  [profile,subscription]: both" || bad "who both: $(cat "$T/rc.err")"
printf 'core=xray\n' > "$SETTINGS"
SERVERS="$T/s5-xray-off.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/s5-xray-off.direct"; : > "$T/pins"
refresh_check "$T/s5-xray-on.srv" "$T/pins" "$T/s5-xray-on.direct" 2>"$T/rc.err"
grep -q '(DIRECT) \[profile\]:' "$T/rc.err" && ok "  Xray: [profile] when a direct profile is turned on" || bad "who xray: $(cat "$T/rc.err")"

# --- re-review 2 N-A: the freedom outbounds keep their order. An untagged first one is Xray's
# default (its "default" line has no tag), so swapping two untagged ones changes where what no
# rule takes goes, with every line still approved
printf 'core=xray\n' > "$SETTINGS"
na() { /usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $c = $p->[0];
  my @o = grep { $_->{protocol} ne "freedom" } @{ $c->{outbounds} };
  my $a = { protocol => "freedom" }; my $b = { protocol => "freedom", settings => { redirect => "198.51.100.7:443" } };
  $c->{outbounds} = $ARGV[0] eq "A" ? [ $a, $b, @o ] : [ $b, $a, @o ];
  $c->{routing}{rules} = [ grep { ($_->{outboundTag} // "") ne "direct" } @{ $c->{routing}{rules} } ]; delete $c->{dns};
  $#$p = 0; print JSON::PP->new->encode($p)' "$1" < "$fx/xray-panel.json" > "$T/na-$1.json"
  gx "$T/na-$1.json" "na-$1" || bad "na $1: $(cat "$T/err")"; }
na A; na B
SERVERS="$T/na-A.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/na-A.direct"; : > "$T/pins"
refresh_check "$T/na-B.srv" "$T/pins" "$T/na-B.direct" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && ok "Xray: two untagged freedom outbounds swapped (the default moves): the admin" || bad "na: rc $rc"

# --- Codex P1: the first of two untagged freedom outbounds dropped makes the second (a redirect) the
# default; the outbound lines are all as approved, or none at all
printf 'core=xray\n' > "$SETTINGS"
/usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); my $c = $p->[0]; shift @{ $c->{outbounds} }; print JSON::PP->new->encode($p)' < "$T/na-A.json" > "$T/p1.json"
gx "$T/p1.json" p1 || bad "p1: $(cat "$T/err")"
SERVERS="$T/na-A.srv"; APPROVED_HOSTS="$T/none"; APPROVED_DIRECT="$T/na-A.direct"; : > "$T/pins"
refresh_check "$T/p1.srv" "$T/pins" "$T/p1.direct" 2>/dev/null; rc=$?
[ "$rc" = 3 ] && ok "Xray: the first of two untagged freedom outbounds dropped (a redirect becomes the default): the admin" || bad "p1: rc $rc"

# --- Codex P2: IPv6 addresses and ranges are taken, both cores
V6='$h = { name => "v6", block => { ips => ["2001:db8::1"] }, direct => { ips => ["2001:DB8:1::/48"] } }'
printf 'core=mihomo\n' > "$SETTINGS"
with_routing "$T/base.json" "$T/v6.json" "$V6"
gm "$T/v6.json" v6-m || bad "v6 mihomo: $(cat "$T/err")"
[ "$(j 'join " | ", @{ $c->{rules} }[1, 2]' "$T/v6-m")" = "IP-CIDR6,2001:db8::1/128,REJECT | IP-CIDR6,2001:db8:1::/48,DIRECT" ] &&
  ok "mihomo: an IPv6 address and range" || bad "v6 mihomo: $(j '$c->{rules}' "$T/v6-m") $(j '$c->{dropped}' "$T/v6-m.report")"
if [ -x "$MIHOMO" ]; then out=$("$MIHOMO" -t -d "$T/home" -f "$T/v6-m" 2>&1) && ok "  mihomo -t" || bad "  mihomo -t: $(tail -2 <<<"$out")"; fi
printf 'core=xray\n' > "$SETTINGS"
with_routing "$fx/xray-panel.json" "$T/v6x.json" "$V6" 1
gx "$T/v6x.json" v6-x || bad "v6 xray: $(cat "$T/err")"
[ "$(j 'JSON::PP->new->canonical->encode([ map { $_->{ip} } @{ $c->{routing}{rules} }[2, 3] ])' "$T/v6-x")" = '[["2001:db8::1/128"],["2001:db8:1::/48"]]' ] &&
  ok "Xray: an IPv6 address and range" || bad "v6 xray: $(j '$c->{routing}{rules}' "$T/v6-x")"
if [ -x "$XRAY" ]; then out=$(XRAY_LOCATION_ASSET=$CORE_DIR "$XRAY" run -test -format json -c "$T/v6-x" 2>&1) && ok "  xray run -test" || bad "  xray run -test: $(tail -2 <<<"$out")"; fi

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
