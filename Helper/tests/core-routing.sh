#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Routing only from the subscription (ADR 0013): rules the core cannot take are left out with the
# reason, the subscription's sniffer and DNS policy are taken key by key, the core may leave the
# tunnel only for what the subscription sends direct (egress), and the report for the app says all
# of it without a secret of the profile. No root, no network.
#   Helper/tests/core-routing.sh   (MIHOMO=/path/to/mihomo for "mihomo -t")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
echo site > "$CORE_DIR/geosite.dat"; echo ip > "$CORE_DIR/geoip.metadb"   # present; content does not matter here
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; fi.example.com) echo 203.0.113.30 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
val() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
gen() { core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
# q <perl expression over $r, the report>: prints its value
q() { /usr/bin/perl -MJSON::PP -e 'local $/; my $r = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "$tmp/c.report"; }

gen "$fx/ok-routing.json" || bad "ok-routing refused: $(cat "$tmp/err")"

# --- rules: the subscription's, in its order; what the core cannot take left out with the reason
[ "$(q 'join "|", map { $_->{from} . ":" . ($_->{index} // "") } @{ $r->{rules} }')" = \
  "subscription:0|subscription:1|subscription:2|subscription:3|subscription:4|subscription:10|subscription:11|subscription:12|subscription:13" ] &&
  ok "report: every rule from the subscription with its index, in order" || bad "report rules: $(q '$r->{rules}')"
[ "$(q 'join "|", map { "$_->{index}=$_->{reason}" } grep { $_->{section} eq "rules" } @{ $r->{dropped} }')" = \
  "5=type:FOO|6=target:NoSuchGroup|7=provider:nope|8=sub-rule|9=geodata:asn" ] &&
  ok "report: unknown type, missing group, missing provider, SUB-RULE, IP-ASN left out with reasons" ||
  bad "dropped rules: $(q '[grep { $_->{section} eq "rules" } @{ $r->{dropped} }]')"
[ "$(val rules.5 "$tmp/c")" = "GEOSITE,category-ru,DIRECT" ] && ok "config: the rest of the subscription still there" || bad "config rules"
[ "$(q 'join ",", map { $_->{item} } grep { $_->{section} eq "profile" } @{ $r->{dropped} }')" = mixed-port ] &&
  ok "report: a section the config does not take (mixed-port)" || bad "profile sections: $(q '$r->{dropped}')"

# --- sniffer: the subscription's own, key by key
[ "$(val sniffer.parse-pure-ip "$tmp/c")" = true ] && [ "$(val sniffer.sniff.HTTP.override-destination "$tmp/c")" = true ] &&
  [ "$(val sniffer.force-domain.0 "$tmp/c")" = "+.v2ex.com" ] && ! plutil -type sniffer.sniff.SSH "$tmp/c" >/dev/null 2>&1 &&
  ! plutil -type sniffer.skip-src-address "$tmp/c" >/dev/null 2>&1 && ok "sniffer: taken from the subscription, unknown parts left out" ||
  bad "sniffer: $(plutil -extract sniffer json -o - "$tmp/c")"
[ "$(q '$r->{sniffer}{from}')" = subscription ] && ok "report: sniffer from the subscription" || bad "report sniffer: $(q '$r->{sniffer}')"
[ "$(q 'join "|", map { "$_->{item}=$_->{reason}" } grep { $_->{section} eq "sniffer" } @{ $r->{dropped} }')" = \
  "skip-domain: Mijia Cloud=bad-value|skip-domain: rule-set:missing=provider:missing|skip-src-address=not-allowed|sniff.SSH=not-allowed" ] &&
  ok "report: sniffer parts left out with reasons" || bad "sniffer dropped: $(q '[grep { $_->{section} eq "sniffer" } @{ $r->{dropped} }]')"

# --- dns: our resolvers through the tunnel, the subscription's policy on top
[ "$(val dns.listen "$tmp/c")" = 127.0.0.1:53 ] && [ "$(val dns.nameserver.0 "$tmp/c")" = "https://1.1.1.1/dns-query#KS-DNS" ] &&
  [ "$(val dns.default-nameserver.0 "$tmp/c")" = "https://1.1.1.1/dns-query#KS-DNS" ] && [ "$(val dns.nameserver "$tmp/c")" = 2 ] &&
  ok "dns: listen, nameserver and default-nameserver are ours (DoH through KS-DNS)" || bad "dns: $(plutil -extract dns json -o - "$tmp/c")"
[ "$(val dns.fake-ip-filter "$tmp/c")" = 4 ] && [ "$(val dns.nameserver-policy.+\\.ru.0 "$tmp/c")" = "https://dns.yandex.ru/dns-query" ] &&
  [ "$(val dns.direct-nameserver "$tmp/c")" = 2 ] && [ "$(val dns.respect-rules "$tmp/c")" = true ] &&
  [ "$(val dns.proxy-server-nameserver.0 "$tmp/c")" = "https://1.1.1.1/dns-query#KS-DNS" ] &&
  ok "dns: fake-ip-filter, nameserver-policy, direct-nameserver, respect-rules taken (with our proxy-server-nameserver)" ||
  bad "dns taken: $(plutil -extract dns json -o - "$tmp/c")"
grep -qE 'dhcp://|"system"|192\.168\.1\.1|geoip:ru|bad pattern' "$tmp/c" && bad "dns: a LAN or system resolver or a bad pattern taken" ||
  ok "dns: dhcp://, system, the LAN's resolver and bad patterns left out"
[ "$(q 'join "|", sort map { "$_->{item}=$_->{reason}" } grep { $_->{section} eq "dns" } @{ $r->{dropped} }')" = \
  "default-nameserver=managed|direct-nameserver: system=bad-value|enable=managed|fake-ip-filter: bad pattern=bad-value|listen=managed|nameserver-policy: geoip:ru=bad-value|nameserver-policy: rule-set:ru-inline: dhcp://en0=bad-value|nameserver=managed" ] &&
  ok "report: dns parts left out with reasons" || bad "dns dropped: $(q '[grep { $_->{section} eq "dns" } @{ $r->{dropped} }]')"
[ "$(q '$r->{dns}{taken}{"nameserver-policy"}{"+.ru"}[0]')" = "https://dns.yandex.ru/..." ] &&
  [ "$(q '$r->{dns}{taken}{"direct-nameserver"}[1]')" = "https://common.dot.dns.yandex.net/...#DIRECT" ] &&
  ok "report: dns values shown without their path" || bad "report dns: $(q '$r->{dns}')"
grep -q '^dns	.*direct-nameserver' "$tmp/c.direct" && ok "signature: the DNS servers outside the tunnel need the admin like DIRECT rules" ||
  bad "signature: $(cat "$tmp/c.direct")"
[ "$(paste -sd, - < "$tmp/c.egress")" = rules,dns ] && [ "$(q 'join ",", @{ $r->{egress} }')" = rules,dns ] &&
  ok "egress: DIRECT rules and direct DNS" || bad "egress: $(cat "$tmp/c.egress")"
if [ -x "$MIHOMO" ]; then
  # GEOSITE/GEOIP would need the real geodata: checked without them (core-features.sh has them)
  rm "$CORE_DIR/geosite.dat" "$CORE_DIR/geoip.metadb"; gen "$fx/ok-routing.json"; mkdir -p "$tmp/home"
  if out=$("$MIHOMO" -t -d "$tmp/home" -f "$tmp/c" 2>&1); then ok "ok-routing: mihomo -t"; else bad "ok-routing: mihomo -t: $(tail -2 <<<"$out")"; fi
  echo site > "$CORE_DIR/geosite.dat"; echo ip > "$CORE_DIR/geoip.metadb"
else echo "skip  ok-routing: mihomo -t"; fi

# --- DNS policy only: the core still may leave the tunnel, the signature still holds it
/usr/bin/perl -MJSON::PP -e 'local $/; my $j = JSON::PP->new->decode(<STDIN>); $j->{rules} = ["MATCH,Сервер"];
  $j->{"proxy-groups"}[0]{proxies} = ["LT", "DE"]; delete $j->{"rule-providers"}; delete $j->{sniffer};
  $j->{dns} = { "direct-nameserver" => ["77.88.8.8"] }; print JSON::PP->new->encode($j)' < "$fx/ok-routing.json" > "$tmp/p.json"
gen "$tmp/p.json" || bad "dns only: refused: $(cat "$tmp/err")"
[ "$(cat "$tmp/c.egress")" = dns ] && [ "$(grep -c . "$tmp/c.direct")" = 1 ] && ok "dns only: egress dns, one signature line" ||
  bad "dns only: egress $(cat "$tmp/c.egress"), sig $(cat "$tmp/c.direct")"
[ "$(val sniffer.enable "$tmp/c")" = true ] && [ "$(val sniffer.override-destination "$tmp/c")" = false ] &&
  [ "$(val sniffer.parse-pure-ip "$tmp/c")" = true ] && [ "$(val sniffer.sniff.QUIC.ports.0 "$tmp/c")" = 443 ] &&
  [ "$(val sniffer.sniff.HTTP.ports.1 "$tmp/c")" = 8080-8880 ] && [ "$(val sniffer.sniff.TLS.ports.1 "$tmp/c")" = 8443 ] &&
  ok "no sniffer in the subscription: ours, routing only (override-destination false)" || bad "default sniffer: $(plutil -extract sniffer json -o - "$tmp/c")"
[ "$(q '$r->{sniffer}{from}')" = killswitch ] && [ "$(q 'join ",", map { $_->{kind} } @{ $r->{added} }')" = "dns-group,dns-servers,pinning,sniffer" ] &&
  ok "report: our sniffer, DNS group and servers, pinning under «Добавлено KillSwitch»" || bad "added: $(q '$r->{added}')"
# nothing direct at all: the core stays in the tunnel
/usr/bin/perl -MJSON::PP -e 'local $/; my $j = JSON::PP->new->decode(<STDIN>); delete $j->{dns}; print JSON::PP->new->encode($j)' < "$tmp/p.json" > "$tmp/p2.json"
gen "$tmp/p2.json" && [ ! -s "$tmp/c.egress" ] && [ ! -s "$tmp/c.direct" ] && ok "nothing direct: empty egress and signature" ||
  bad "nothing direct: egress $(cat "$tmp/c.egress"), sig $(cat "$tmp/c.direct")"

# --- the app's additions are named as such, the rest is the subscription's
printf 'adblock=1\nsplitapps=Telegram\n' > "$SETTINGS"
gen "$fx/ok-full.json" || bad "ok-full refused: $(cat "$tmp/err")"
[ "$(q 'join "|", map { $_->{from} } @{ $r->{rules} }[0..3]')" = "killswitch|killswitch|killswitch|subscription" ] &&
  ok "report: ad block and apps outside the VPN marked as KillSwitch's" || bad "report from: $(q '$r->{rules}')"
[ "$(q 'join ",", map { $_->{kind} } @{ $r->{added} }')" = "dns-group,dns-servers,pinning,unbound,provider-path,provider-proxy,sniffer,adblock,splitapps" ] &&
  ok "report: everything KillSwitch added or changed, by kind" || bad "added: $(q '[map { $_->{kind} } @{ $r->{added} }]')"
[ "$(q 'join ",", map { "$_->{name}:$_->{from}" } @{ $r->{groups} }')" = "Bad#name:subscription,🚀 Выбор сервера:subscription,auto:subscription,KS-DNS:killswitch" ] &&
  ok "report: groups with where they come from" || bad "groups: $(q '$r->{groups}')"
[ "$(q 'my ($p) = grep { $_->{name} eq "ru-blocked" } @{ $r->{providers} }; "$p->{host} $p->{proxy}"')" = "example.com KS-DNS" ] &&
  [ "$(q 'my ($p) = grep { $_->{name} eq "local-inline" } @{ $r->{providers} }; "$p->{count} @{ $p->{payload} }"')" = "1 +.example.net" ] &&
  ok "report: http provider by host, inline provider with its entries" || bad "providers: $(q '$r->{providers}')"
grep -qE 'a3482e88|J1sRwuk4|6ba85179|"password"|"uuid"|reality-opts|example\.com/ru\.txt' "$tmp/c.report" &&
  bad "report holds a secret or a provider URL" || ok "report: no uuid, key, short-id, password or provider URL"
gen "$fx/ok-routing.json"
grep -qE 'user:token|secret|ru\.mrs' "$tmp/c.report" && bad "report: provider URL credentials leaked" || ok "report: provider URL reduced to its host"
rm -f "$SETTINGS"

# --- a rule the generator itself adds when the subscription has none
gen "$fx/ok-minimal.json"
[ "$(q '$r->{rules}[0]{rule} . " " . $r->{rules}[0]{from}')" = "MATCH,only killswitch" ] &&
  [ "$(q 'join ",", map { $_->{kind} } @{ $r->{added} }')" = "dns-group,dns-servers,default-rule,sniffer" ] &&
  ok "report: the default rule of a profile without rules is KillSwitch's" || bad "default rule: $(q '$r->{rules}') $(q '$r->{added}')"

# --- split_rule reads rules as mihomo does
sr() { /usr/bin/perl -MJSON::PP -e "$KS_RULES_PL"'print join "|", split_rule($ARGV[0])' "$1"; }
[ "$(sr 'DOMAIN-SUFFIX, ru ,DIRECT')" = "DOMAIN-SUFFIX|ru|DIRECT" ] && ok "split_rule: spaces trimmed" || bad "split_rule: $(sr 'DOMAIN-SUFFIX, ru ,DIRECT')"
[ "$(sr 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT')" = "AND|((NETWORK,UDP),(DST-PORT,443))|REJECT" ] && ok "split_rule: logic rule" || bad "split_rule AND"
[ "$(sr 'ip-cidr,10.0.0.0/8,DIRECT,no-resolve')" = "IP-CIDR|10.0.0.0/8|DIRECT|no-resolve" ] && ok "split_rule: type upper-cased, options kept" || bad "split_rule options"
[ -z "$(sr 'AND,((NETWORK,UDP),DIRECT')" ] && [ -z "$(sr 'DOMAIN,x.com')" ] && ok "split_rule: unbalanced or short rules unread" || bad "split_rule bad"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
