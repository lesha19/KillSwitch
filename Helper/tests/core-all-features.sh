#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Every 0.20.0 setting at once (#14 blocking and own DoH, #18 MTU, #20 escalation, #28 own site
# addresses, #30 routing profile, #33 double VPN): the core takes the config, and none of them
# moves what goes past the VPN — the DIRECT signature and egress are those of the routing profile
# alone (its direct entries), and stay the same across a rebuild. No root, no network.
#   Helper/tests/core-all-features.sh   (XRAY=/MIHOMO= to check the configs with the real binaries)
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
SETTINGS="$DIR/settings"; EVENTS="$DIR/events.log"; REPORT="$CORE_DIR/routing.json"
for f in geosite.dat geoip.metadb geoip.dat; do [ ! -s "$here/../$f" ] || { cp "$here/../$f" "$CORE_DIR/" && cp "$here/../$f" "$T/home/"; }; done
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; fi.example.com) echo 203.0.113.30 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "$2"; }
same() { cmp -s "$1" "$2"; }
# the same JSON, whatever the key order (Perl writes hashes in its own order)
same_json() { [ "$(j 'JSON::PP->new->canonical->encode($c)' "$1")" = "$(j 'JSON::PP->new->canonical->encode($c)' "$2")" ]; }
PROFILE='{ name => "Всё сразу", block => { sites => ["domain:ads.example.com"] }, proxy => { sites => ["full:www.example.org"] },
  direct => { sites => ["domain:ru", "keyword:yandex"], ips => ["geoip:ru", "10.0.0.0/8"] } }'
# all <file>: every new setting on, besides the core and double VPN's entry ($2)
all() {
  printf 'core=%s\nmultihop=%s\nmtu=1380\ndoh=https://dns.example.com/dns-query\nhosts=nas.home.arpa=192.168.1.10,files.example.net=203.0.113.77\nadblock=1\nblockadult=1\nblocksocial=1\nblockbetting=1\nescalate=1\nfailover=1\n' "$1" "$2" > "$SETTINGS"
}

# --- Xray: hosts 🇱🇹Литва (the fixture), 🇱🇹Литва XHTTP (the same server, the other transport
# first: escalation has alternatives) and 🇩🇪Германия (the double VPN entry); the profile in the first
xprof() { /usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $c = JSON::PP->new;
  my $x = $c->decode($c->encode($a->[0])); $x->{remarks} = "🇱🇹Литва XHTTP"; @{ $x->{outbounds} }[0, 1] = @{ $x->{outbounds} }[1, 0];
  my $d = $c->decode($c->encode($a->[0])); $d->{remarks} = "🇩🇪Германия"; $_->{settings}{vnext}[0]{address} = "de.example.com" for @{ $d->{outbounds} }[0, 1];
  $_->{tag} =~ s/\ALT_/DE_/ for @{ $d->{outbounds} };
  # its balancer too, or its fallback names an outbound it lacks (a host left out, #37)
  for my $b (@{ $d->{routing}{balancers} }) { s/\ALT_/DE_/ for $b->{fallbackTag}, @{ $b->{selector} }; s/\ALT_/DE_/ for map { $_->{match} } @{ $b->{strategy}{settings}{costs} } }
  push @$a, $x, $d; if ($ARGV[0]) { my $h; eval "\$h = $ARGV[0]"; die $@ if $@; $a->[0]{"x-ks-routing"} = $h }
  print JSON::PP->new->encode($a)' "$1" < "$fx/xray-panel.json" > "$2"; }
gx() { core_generate_xray "$1" "$T/$2" "$T/$2.srv" 2>"$T/err"; }
xprof "$PROFILE" "$T/xp.json"
printf 'core=xray\n' > "$SETTINGS"
gx "$T/xp.json" x-profile || bad "xray, the profile alone: $(cat "$T/err")"
all xray 🇩🇪Германия
# escalation armed (the running host failing) with a fingerprint and another outbound to the same
# server (its transport step: that one leads) that worked remembered
printf 'net=en0 192.168.1.1\n🇱🇹Литва\tprobe\t1\t1000000\n🇱🇹Литва\tlead\tLT_1_FB\t1000000\n🇱🇹Литва\tfp\tfirefox\t1000000\n' > "$CORE_DIR/escalation"
gx "$T/xp.json" x-all || bad "xray, everything on: $(cat "$T/err")"
c="$T/x-all"
[ "$(j '(grep { $_->{tag} eq "ks-tun" } @{ $c->{inbounds} })[0]{settings}{mtu}' "$c")" = 1380 ] && ok "Xray: MTU 1380 on the TUN" || bad "mtu: $(j '$c->{inbounds}' "$c")"
[ "$(j '$c->{dns}{servers}[0]{address} . " " . $c->{dns}{servers}[0]{tag}' "$c")" = "https://dns.example.com/dns-query ks-doh" ] &&
  [ "$(j 'my ($r) = grep { ref $_->{inboundTag} && $_->{inboundTag}[0] eq "ks-doh" } @{ $c->{routing}{rules} }; $r->{outboundTag}' "$c")" != direct ] &&
  ok "  own DoH first, its queries to a server" || bad "  doh: $(j '$c->{dns}' "$c")"
[ "$(j '$c->{dns}{hosts}{"full:nas.home.arpa"} . " " . $c->{dns}{hosts}{"full:files.example.net"}' "$c")" = "192.168.1.10 203.0.113.77" ] &&
  ok "  own site addresses in the DNS hosts" || bad "  hosts: $(j '$c->{dns}{hosts}' "$c")"
if [ -s "$CORE_DIR/geosite.dat" ]; then
  [ "$(j 'my ($r) = grep { ref $_->{domain} && grep { $_ eq "geosite:category-porn" } @{ $_->{domain} } } @{ $c->{routing}{rules} }; my ($o) = grep { $_->{tag} eq $r->{outboundTag} } @{ $c->{outbounds} }; $o->{protocol}' "$c")" = blackhole ] &&
    ok "  blocked categories to a blackhole" || bad "  block: $(j '$c->{routing}{rules}' "$c")"
else echo "skip  blocked categories (no shipped geosite.dat)"; fi
[ "$(j 'join ",", map { $_->{tag} } grep { ($_->{streamSettings}{sockopt}{dialerProxy} // "") eq "ks-entry" } @{ $c->{outbounds} }' "$c" | grep -c LT_1)" = 1 ] &&
  ok "  double VPN: the running server dialed through the entry" || bad "  multihop: $(j '[map { [$_->{tag}, $_->{streamSettings}{sockopt}{dialerProxy}] } @{ $c->{outbounds} }]' "$c")"
[ "$(j '$c->{outbounds}[0]{tag} . " " . $c->{outbounds}[0]{streamSettings}{realitySettings}{fingerprint}' "$c")" = "LT_1_FB firefox" ] &&
  [ -n "$(j 'join ",", map { $_->{tag} } grep { $_->{tag} =~ /\Aks-ping-0-/ } @{ $c->{outbounds} }' "$c")" ] &&
  ok "  escalation: the other outbound leads with the remembered fingerprint, the alternatives probed" || bad "  escalation: $(j '[map { $_->{tag} } @{ $c->{outbounds} }]' "$c")"
grep -q $'^profile-rule\t' "$c.direct" && grep -q $'^profile\t' "$c.direct" && ok "  the profile's direct entries in the DIRECT signature" || bad "  profile sig: $(cat "$c.direct")"
same "$c.direct" "$T/x-profile.direct" && same "$c.egress" "$T/x-profile.egress" &&
  ok "  DIRECT signature and egress: the profile's alone (nothing else on adds a way past the VPN)" || bad "  direct differs: $(diff "$T/x-profile.direct" "$c.direct")"
gx "$T/xp.json" x-again || bad "xray rebuild: $(cat "$T/err")"
same "$T/x-again.direct" "$c.direct" && same "$T/x-again.egress" "$c.egress" && same_json "$T/x-again" "$c" &&
  ok "  a rebuild: the same config, signature and egress" || bad "  rebuild differs: $(diff "$c.direct" "$T/x-again.direct")"
if [ -x "$XRAY" ]; then out=$(XRAY_LOCATION_ASSET=$CORE_DIR "$XRAY" run -test -format json -c "$c" 2>&1) && ok "  xray run -test" || bad "  xray run -test: $(tail -3 <<<"$out")"
else echo "skip  xray run -test (no $XRAY)"; fi

# --- mihomo: base.json is the fixture without DIRECT in its groups (so "proxy" is the VPN)
rm -f "$CORE_DIR/escalation"
/usr/bin/perl -MJSON::PP -e 'local $/; my $p = JSON::PP->new->decode(<STDIN>); for (@{ $p->{"proxy-groups"} }) { $_->{proxies} = [ grep { $_ ne "DIRECT" } @{ $_->{proxies} } ] }
  my $h; eval "\$h = $ARGV[0]"; die $@ if $@; $p->{"x-ks-routing"} = $h; print JSON::PP->new->encode($p)' "$PROFILE" < "$fx/ok-full.json" > "$T/mp.json"
gm() { core_generate_mihomo "$1" "$T/$2" "$T/$2.srv" 2>"$T/err"; }
printf 'core=mihomo\n' > "$SETTINGS"
gm "$T/mp.json" m-profile || bad "mihomo, the profile alone: $(cat "$T/err")"
all mihomo "NL reality"
gm "$T/mp.json" m-all || bad "mihomo, everything on: $(cat "$T/err")"
c="$T/m-all"
[ "$(j '$c->{tun}{mtu}' "$c")" = 1380 ] && ok "mihomo: tun.mtu 1380" || bad "mihomo mtu: $(j '$c->{tun}' "$c")"
[ "$(j '$c->{dns}{nameserver}[0]' "$c")" = "https://dns.example.com/dns-query#$KS_DNS" ] && ok "  own DoH through KillSwitch's group" || bad "  doh: $(j '$c->{dns}' "$c")"
[ "$(j '$c->{hosts}{"nas.home.arpa"}' "$c")" = 192.168.1.10 ] && ok "  own site addresses" || bad "  hosts: $(j '$c->{hosts}' "$c")"
if [ -s "$CORE_DIR/geosite.dat" ]; then
  j 'join "\n", @{ $c->{rules} }' "$c" | grep -qx 'GEOSITE,category-porn,REJECT' && ok "  blocked categories rejected" || bad "  block: $(j '$c->{rules}' "$c")"
else echo "skip  blocked categories (no shipped geosite.dat)"; fi
[ "$(j 'join ",", map { $_->{name} } grep { ($_->{"dialer-proxy"} // "") eq "NL reality" } @{ $c->{proxies} }' "$c")" != "" ] &&
  ok "  double VPN: the other servers dialed through the entry" || bad "  multihop: $(j '$c->{proxies}' "$c")"
grep -q $'^profile-rule\tDOMAIN-SUFFIX,ru,DIRECT$' "$c.direct" && ok "  the profile's direct entries in the DIRECT signature" || bad "  profile sig: $(cat "$c.direct")"
same "$c.direct" "$T/m-profile.direct" && same "$c.egress" "$T/m-profile.egress" &&
  ok "  DIRECT signature and egress: the profile's alone" || bad "  direct differs: $(diff "$T/m-profile.direct" "$c.direct")"
gm "$T/mp.json" m-again || bad "mihomo rebuild: $(cat "$T/err")"
same "$T/m-again.direct" "$c.direct" && same "$T/m-again.egress" "$c.egress" && same_json "$T/m-again" "$c" &&
  ok "  a rebuild: the same config, signature and egress" || bad "  rebuild differs: $(diff "$c.direct" "$T/m-again.direct")"
if [ -x "$MIHOMO" ]; then out=$("$MIHOMO" -t -d "$T/home" -f "$c" 2>&1) && ok "  mihomo -t" || bad "  mihomo -t: $(tail -3 <<<"$out")"
else echo "skip  mihomo -t (no $MIHOMO)"; fi

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
