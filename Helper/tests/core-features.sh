#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Generator features of Helper/ks on top of the fixtures: DIRECT signature, apps outside the
# core (splitapps), double VPN (multihop), rebuilding from pinned addresses. No root, no network.
#   Helper/tests/core-features.sh   (MIHOMO=/path/to/mihomo for "mihomo -t")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"
SETTINGS="$tmp/settings"
put() { { grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$SETTINGS.new"; mv "$SETTINGS.new" "$SETTINGS"; }
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"   # no geodata until the Russian-sites part
resolve_host() {
  case "$1" in
    de.example.com) echo 203.0.113.20 ;;
    fi.example.com) echo 203.0.113.30 ;;
    *) return 1 ;;
  esac
}
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
val() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
mt()  {  # mt <desc> <config>
  [ -x "$MIHOMO" ] || { echo "skip  $1: mihomo -t"; return; }
  local out
  if out=$("$MIHOMO" -t -d "$tmp/home" -f "$2" 2>&1); then ok "$1: mihomo -t"; else bad "$1: mihomo -t: $(tail -2 <<<"$out")"; fi
}
gen() { core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
profile() { printf '%s' "$1" > "$tmp/p.json"; }
SS='"type":"ss","port":8388,"cipher":"aes-128-gcm","password":"x"'

# --- DIRECT signature
gen "$fx/ok-minimal.json" && [ ! -s "$tmp/c.direct" ] && ok "minimal: nothing direct" || bad "minimal: direct: $(cat "$tmp/c.direct")"
gen "$fx/ok-full.json"
grep -q '^group	.*"name":"🚀 Выбор сервера"' "$tmp/c.direct" && ok "full: group holding DIRECT listed" || bad "full: group"
[ "$(grep -c '^rule	' "$tmp/c.direct")" = 4 ] && ok "full: all 4 rules can go direct (3 via the group)" ||
  bad "full: rules: $(cat "$tmp/c.direct")"
grep -q 'auto' "$tmp/c.direct" && bad "full: url-test group without DIRECT listed" || ok "full: proxy-only group not listed"
grep -q 'KS-DNS' "$tmp/c.direct" && bad "full: KS-DNS in the signature" || ok "full: KS-DNS not in the signature"
cp "$tmp/c.direct" "$tmp/full.direct"
profile "{\"proxies\":[{\"name\":\"a\",\"server\":\"198.51.100.1\",$SS}],
  \"proxy-groups\":[{\"name\":\"inner\",\"type\":\"select\",\"proxies\":[\"a\",\"DIRECT\"]},
                    {\"name\":\"outer\",\"type\":\"select\",\"proxies\":[\"inner\"]},
                    {\"name\":\"filt\",\"type\":\"select\",\"include-all\":true,\"filter\":\"zzz\"}],
  \"rules\":[\"DOMAIN,x.com,outer\",\"DOMAIN,y.com,GLOBAL\",\"AND,((DOMAIN,z.com),(NETWORK,UDP)),DIRECT\",
             \"DOMAIN,v.com,filt\",\"DOMAIN,u.com,a\",\"MATCH,a\"]}"
gen "$tmp/p.json" || bad "nested: refused: $(cat "$tmp/err")"
for r in x.com y.com z.com v.com; do
  grep -q "^rule	.*$r" "$tmp/c.direct" || bad "nested: rule $r not in the signature"
done
grep -qE 'u\.com|MATCH' "$tmp/c.direct" && bad "nested: proxy-only rules listed" || ok "nested/GLOBAL/logical/filter groups caught"
mt "nested groups" "$tmp/c"

# --- rule providers behind DIRECT rules: their contents decide what goes outside the tunnel
sigof() { gen "$1" || bad "$2: refused: $(cat "$tmp/err")"; cp "$tmp/c.direct" "$tmp/$2.direct"; }
edit() { /usr/bin/perl -MJSON::PP -e 'local $/; my $j = JSON::PP->new->decode(<STDIN>); eval $ARGV[0]; die $@ if $@; print JSON::PP->new->encode($j)' "$1"; }
grep -q '^provider	.*"local-inline".*example\.net' "$tmp/full.direct" && ok "providers: inline provider of a DIRECT rule in the signature" ||
  bad "providers: inline: $(cat "$tmp/full.direct")"
grep -q '^provider	.*"ru-blocked".*example\.com/ru\.txt' "$tmp/full.direct" && ok "providers: provider of a rule to a DIRECT-holding group in the signature" ||
  bad "providers: http: $(cat "$tmp/full.direct")"
edit '$j->{"rule-providers"}{"local-inline"}{payload} = ["+.example.net", "+.com"]' < "$fx/ok-full.json" > "$tmp/p.json"
sigof "$tmp/p.json" payload
cmp -s "$tmp/full.direct" "$tmp/payload.direct" && bad "providers: wider inline payload left the signature unchanged" || ok "providers: inline payload change changes the signature"
edit '$j->{"rule-providers"}{"ru-blocked"}{url} = "https://example.com/everything.txt"' < "$fx/ok-full.json" > "$tmp/p.json"
sigof "$tmp/p.json" url
cmp -s "$tmp/full.direct" "$tmp/url.direct" && bad "providers: new url left the signature unchanged" || ok "providers: url change changes the signature"
edit '$j->{"rule-providers"}{"other"} = {type=>"http", behavior=>"domain", url=>"https://example.com/o.txt"}; unshift @{$j->{rules}}, "RULE-SET,other,auto"' \
  < "$fx/ok-full.json" > "$tmp/p.json"
sigof "$tmp/p.json" proxied
cmp -s "$tmp/full.direct" "$tmp/proxied.direct" && ok "providers: a provider of proxy-only rules stays out" || bad "providers: proxied: $(diff "$tmp/full.direct" "$tmp/proxied.direct")"
edit '$j->{"rule-providers"}{"other"} = {type=>"http", behavior=>"domain", url=>"https://example.com/o.txt", proxy=>"DIRECT"}; unshift @{$j->{rules}}, "RULE-SET,other,auto"' \
  < "$fx/ok-full.json" > "$tmp/p.json"
sigof "$tmp/p.json" pdirect
grep -q '^provider-proxy	other	DIRECT$' "$tmp/pdirect.direct" && ok "providers: a provider downloaded with proxy DIRECT in the signature" ||
  bad "providers: proxy DIRECT: $(cat "$tmp/pdirect.direct")"
edit '$j->{"rule-providers"}{"other"} = {type=>"http", behavior=>"domain", url=>"https://example.com/o.txt", proxy=>"auto"}; unshift @{$j->{rules}}, "RULE-SET,other,auto"' \
  < "$fx/ok-full.json" > "$tmp/p.json"
sigof "$tmp/p.json" pauto
grep -q '^provider-proxy	other	auto$' "$tmp/pauto.direct" && ok "providers: any proxy set by the profile is in the signature" ||
  bad "providers: proxy auto: $(cat "$tmp/pauto.direct")"
grep -q 'provider-proxy	ru-blocked' "$tmp/full.direct" && bad "providers: our own KS-DNS proxy in the signature" || ok "providers: our KS-DNS default stays out"
# direct_sig on its own: an http provider with no proxy at all is a direct download
echo '[]' > "$tmp/g.json"; echo '["MATCH,a"]' > "$tmp/r.json"
echo '{"np":{"type":"http","url":"https://example.com/np.txt"},"il":{"type":"inline","payload":["a.com"]}}' > "$tmp/rp.json"
[ "$(direct_sig "$tmp/g.json" "$tmp/r.json" "$tmp/rp.json")" = "provider-proxy	np	DIRECT" ] &&
  ok "providers: http provider without proxy = DIRECT download, in the signature" ||
  bad "providers: no proxy: $(direct_sig "$tmp/g.json" "$tmp/r.json" "$tmp/rp.json")"
# the generator never leaves one without: KS-DNS goes in, and the signature stays empty
profile "{\"proxies\":[{\"name\":\"a\",\"server\":\"198.51.100.1\",$SS}],
  \"rule-providers\":{\"np\":{\"type\":\"http\",\"behavior\":\"domain\",\"url\":\"https://example.com/np.txt\",\"path\":\"/etc/x\"},
                      \"il\":{\"type\":\"inline\",\"behavior\":\"domain\",\"payload\":[\"+.example.net\"],\"path\":\"/etc/y\"}},
  \"rules\":[\"RULE-SET,np,a\",\"RULE-SET,il,a\",\"MATCH,a\"]}"
if gen "$tmp/p.json"; then
  [ "$(val rule-providers.np.proxy "$tmp/c")" = KS-DNS ] && [ ! -s "$tmp/c.direct" ] &&
    ok "providers: KS-DNS added, nothing direct" || bad "providers: np proxy $(val rule-providers.np.proxy "$tmp/c"), direct: $(cat "$tmp/c.direct")"
  plutil -type rule-providers.np.path "$tmp/c" >/dev/null 2>&1 || plutil -type rule-providers.il.path "$tmp/c" >/dev/null 2>&1 &&
    bad "providers: path kept" || ok "providers: path dropped from http and inline"
else bad "providers: refused: $(cat "$tmp/err")"; fi
# a provider name with a line break was missed by the old listing of names and copied unchecked
profile "{\"proxies\":[{\"name\":\"a\",\"server\":\"198.51.100.1\",$SS}],
  \"rule-providers\":{\"ok\":{\"type\":\"inline\",\"behavior\":\"domain\",\"payload\":[\"+.example.net\"]},
                      \"x\\ny\":{\"type\":\"http\",\"behavior\":\"domain\",\"url\":\"https://example.com/x.txt\",\"proxy\":\"DIRECT\"}},
  \"rules\":[\"RULE-SET,ok,a\",\"MATCH,a\"]}"
gen "$tmp/p.json" && bad "providers: name with a line break accepted" || ok "providers: name with a line break refused ($(cat "$tmp/err"))"
edit '$j->{rules}[1] = "AND,((RULE-SET,local-inline),(NETWORK,TCP)),DIRECT"' < "$fx/ok-full.json" > "$tmp/p.json"
sigof "$tmp/p.json" logical
grep -q '^provider	.*"local-inline"' "$tmp/logical.direct" && ok "providers: provider inside a logical DIRECT rule in the signature" ||
  bad "providers: logical: $(cat "$tmp/logical.direct")"

# --- splitapps
put splitapps "Telegram,Google Chrome"
gen "$fx/ok-full.json"
[ "$(val rules.0 "$tmp/c")" = "PROCESS-NAME,Telegram,DIRECT" ] && [ "$(val rules.1 "$tmp/c")" = "PROCESS-NAME,Google Chrome,DIRECT" ] &&
  [ "$(val rules.2 "$tmp/c")" = 'PROCESS-NAME-REGEX,^Telegram Helper.*$,DIRECT' ] &&
  [ "$(val rules.3 "$tmp/c")" = 'PROCESS-NAME-REGEX,^Google Chrome Helper.*$,DIRECT' ] &&
  [ "$(val rules.4 "$tmp/c")" = "RULE-SET,ru-blocked,🚀 Выбор сервера" ] &&
  ok "splitapps: PROCESS-NAME and their helpers, then the subscription's own rules" || bad "splitapps: $(val rules.0 "$tmp/c") | $(val rules.4 "$tmp/c")"
cmp -s "$tmp/c.direct" "$tmp/full.direct" && ok "splitapps rules stay out of the DIRECT signature" || bad "splitapps in signature"
mt "splitapps" "$tmp/c"
put splitapps 'a.b (x)+[y]'
gen "$fx/ok-minimal.json"
[ "$(val rules.1 "$tmp/c")" = 'PROCESS-NAME-REGEX,^a\.b \(x\)\+\[y\] Helper.*$,DIRECT' ] && ok "splitapps: helper regex quotes the name" ||
  bad "splitapps regex: $(val rules.1 "$tmp/c")"
mt "splitapps regex" "$tmp/c"
# apps by bundle path: every process inside the bundle, wherever its name came from
put splitapps "/Applications/Telegram.app,Steam"
gen "$fx/ok-minimal.json"
[ "$(val rules.0 "$tmp/c")" = 'PROCESS-PATH-REGEX,^/Applications/Telegram\.app/,DIRECT' ] &&
  [ "$(val rules.1 "$tmp/c")" = "PROCESS-NAME,Steam,DIRECT" ] && [ "$(val rules.2 "$tmp/c")" = 'PROCESS-NAME-REGEX,^Steam Helper.*$,DIRECT' ] &&
  ok "splitapps: a bundle path matches its processes by path; old names keep working" ||
  bad "splitapps paths: $(val rules.0 "$tmp/c") | $(val rules.1 "$tmp/c") | $(val rules.2 "$tmp/c")"
mt "splitapps by path" "$tmp/c"
put splitapps "/Applications/Google Chrome (beta)+.app"
gen "$fx/ok-minimal.json"
[ "$(val rules.0 "$tmp/c")" = 'PROCESS-PATH-REGEX,^/Applications/Google Chrome \(beta\)\+\.app/,DIRECT' ] &&
  ok "splitapps: path quoted for the regex" || bad "splitapps path regex: $(val rules.0 "$tmp/c")"
rm -f "$SETTINGS"

valid_apps() { splitapps_parse "$1" >/dev/null 2>&1; }
valid_apps "/Applications/Telegram.app" && ok "bundle path accepted" || bad "bundle path refused"
valid_apps "/Users/me/Applications/Long Name $(printf 'x%.0s' $(seq 100)).app" && ok "path up to 255 bytes" || bad "long path refused"
valid_apps "/$(printf 'x%.0s' $(seq 256)).app" && bad "path over 255 bytes accepted" || ok "path over 255 bytes refused"
valid_apps "/Applications/Telegram" && bad "path that is not an .app accepted" || ok "path not ending in .app refused"
valid_apps "/Applications/../tmp/x.app" && bad "path with .. accepted" || ok "path with .. refused"
valid_apps "Applications/Telegram.app" && bad "relative path accepted" || ok "name with a slash refused"
[ "$(splitapps_parse ' Telegram , Google Chrome,Telegram')" = "$(printf 'Telegram\nGoogle Chrome')" ] &&
  ok "splitapps_parse trims and dedupes" || bad "splitapps_parse: $(splitapps_parse ' Telegram , Google Chrome,Telegram')"
[ -z "$(splitapps_parse '')" ] && valid_apps '' && ok "empty list clears" || bad "empty list"
valid_apps "$(printf 'a\tb')" && bad "control char accepted" || ok "control char refused"
valid_apps "$(printf 'a\nb')" && bad "newline accepted" || ok "newline refused"
valid_apps 'a,,b' && bad "empty entry accepted" || ok "empty entry refused"
valid_apps "$(printf 'x%.0s' $(seq 65))" && bad "65 bytes accepted" || ok "name over 64 bytes refused"
valid_apps "$(printf 'x%.0s' $(seq 64))" && ok "64 bytes accepted" || bad "64 bytes refused"
valid_apps "$(printf 'я%.0s' $(seq 33))" && bad "66 bytes of Cyrillic accepted" || ok "length counted in bytes"
valid_apps "$(seq 1 51 | paste -sd, -)" && bad "51 entries accepted" || ok "51 entries refused"
valid_apps "$(seq 1 50 | paste -sd, -)" && ok "50 entries accepted" || bad "50 entries refused"

# --- multihop
put multihop "NL reality"
gen "$fx/ok-full.json" || bad "multihop: refused: $(cat "$tmp/err")"
plutil -type proxies.0.dialer-proxy "$tmp/c" >/dev/null 2>&1 && bad "multihop: entry dials through itself" || ok "multihop: entry dials directly"
[ "$(val proxies.1.dialer-proxy "$tmp/c")" = "NL reality" ] && [ "$(val proxies.2.dialer-proxy "$tmp/c")" = "NL reality" ] &&
  ok "multihop: exits dial through the entry" || bad "multihop: dialer-proxy"
[ "$(cat "$tmp/s")" = 203.0.113.10 ] && ok "multihop: core reaches only the entry server" || bad "multihop: servers $(paste -sd' ' "$tmp/s")"
grep -q '"203.0.113.20/32"' "$tmp/c" && bad "multihop: exit excluded from the TUN" || ok "multihop: exits not excluded from the TUN"
[ "$(cut -f1 "$tmp/c.pins" | sort | paste -sd' ' -)" = "de.example.com fi.example.com" ] && ok "multihop: exit names still pinned" ||
  bad "multihop: pins"
mt "multihop" "$tmp/c"
put multihop nope
gen "$fx/ok-full.json" && bad "multihop: missing entry accepted" || ok "multihop: missing entry refused: $(cat "$tmp/err")"
put multihop "🚀 Выбор сервера"
gen "$fx/ok-full.json" && bad "multihop: group as entry accepted" || ok "multihop: group as entry refused"
profile "{\"proxies\":[{\"name\":\"in\",\"server\":\"198.51.100.1\",\"dialer-proxy\":\"out\",$SS},{\"name\":\"out\",\"server\":\"198.51.100.2\",$SS}]}"
put multihop in
gen "$tmp/p.json" && bad "multihop: entry with its own dialer-proxy accepted" || ok "multihop: entry with dialer-proxy refused"
put multihop off
gen "$fx/ok-full.json" && ! plutil -type proxies.1.dialer-proxy "$tmp/c" >/dev/null 2>&1 && ok "multihop=off: plain" || bad "multihop=off"
rm -f "$SETTINGS"

# --- ADR 0013: KillSwitch writes no routing of its own. With every old switch on and the geodata
# in place, the config holds the subscription's rules exactly, in its order, and nothing else.
rules_of() { local i=0 out=""; while r=$(val "rules.$i" "$1"); do out+="$r|"; i=$((i + 1)); done; echo "${out%|}"; }
for f in geoip.metadb geosite.dat; do
  if [ -r "$here/../$f" ]; then cp "$here/../$f" "$CORE_DIR/$f"; else echo fake > "$CORE_DIR/$f"; fi
done
printf 'coredirect=1\nlan=1\n' > "$SETTINGS"
gen "$fx/ok-minimal.json"
[ "$(rules_of "$tmp/c")" = "MATCH,only" ] && [ "$(val geo-auto-update "$tmp/c")" = false ] &&
  ok "no app routing: coredirect=1 adds nothing (no GEOSITE/GEOIP RU, no private networks)" || bad "app routing: $(rules_of "$tmp/c")"
gen "$fx/ok-full.json"
want=$(/usr/bin/perl -MJSON::PP -e 'local $/; print join "|", @{ JSON::PP->new->decode(<STDIN>)->{rules} }' < "$fx/ok-full.json")
[ "$(rules_of "$tmp/c")" = "$want" ] && ok "no app routing: the subscription's rules exactly, in order" || bad "order: $(rules_of "$tmp/c")"
gen "$fx/ok-routing.json"
want="AND,((NETWORK,UDP),(DST-PORT,443)),REJECT|IP-CIDR,10.0.0.0/8,DIRECT,no-resolve|RULE-SET,ru-inline,DIRECT|RULE-SET,ru-http,DIRECT|DOMAIN-SUFFIX,storkvpn.online,DIRECT"
want="$want|GEOSITE,category-ru,DIRECT|GEOIP,RU,DIRECT,no-resolve|OR,((DOMAIN,a.example),(GEOSITE,youtube)),Сервер|MATCH,Сервер"
[ "$(rules_of "$tmp/c")" = "$want" ] && ok "routing: the subscription's GEOSITE/GEOIP rules kept with the shipped geodata, order kept" ||
  bad "routing rules: $(rules_of "$tmp/c")"
if [ -r "$here/../geoip.metadb" ] && [ -r "$here/../geosite.dat" ] && [ -x "$MIHOMO" ]; then
  if out=$("$MIHOMO" -t -d "$CORE_DIR" -f "$tmp/c" 2>&1); then ok "routing: mihomo -t with the shipped geodata"; else bad "routing: mihomo -t: $(tail -2 <<<"$out")"; fi
else echo "skip  routing: mihomo -t with geodata (Helper/fetch-geodata.sh, Helper/fetch-mihomo.sh)"; fi
rm -f "$CORE_DIR/geosite.dat" "$CORE_DIR/geoip.metadb"
gen "$fx/ok-routing.json"
grep -q GEOSITE "$tmp/c" || grep -q 'GEOIP,' "$tmp/c" && bad "no geodata: GEOSITE/GEOIP rules kept" ||
  ok "no geodata: GEOSITE/GEOIP rules left out (the core never downloads geodata)"
mt "routing without geodata" "$tmp/c"
rm -f "$SETTINGS"

# --- ads and trackers blocked (adblock=1), from the shipped geosite.dat only; REJECT is not DIRECT
site=""; [ -r "$here/../geosite.dat" ] && site="$here/../geosite.dat"
put adblock 1
rm -f "$CORE_DIR/geosite.dat"
gen "$fx/ok-minimal.json"
[ "$(rules_of "$tmp/c")" = "MATCH,only" ] && ok "ads: no geodata, no rule (never downloaded)" || bad "ads without geodata: $(rules_of "$tmp/c")"
if [ -n "$site" ]; then cp "$site" "$CORE_DIR/geosite.dat"; else echo fake > "$CORE_DIR/geosite.dat"; fi
gen "$fx/ok-minimal.json"
[ "$(rules_of "$tmp/c")" = "GEOSITE,category-ads-all,REJECT|MATCH,only" ] && ok "ads: REJECT first" || bad "ads: $(rules_of "$tmp/c")"
[ ! -s "$tmp/c.direct" ] && ok "ads: not in the DIRECT signature" || bad "ads: signature $(cat "$tmp/c.direct")"
[ "$(val geo-auto-update "$tmp/c")" = false ] && ok "ads: geodata never auto-updated" || bad "ads: geo-auto-update"
put splitapps Telegram
gen "$fx/ok-minimal.json"
[ "$(rules_of "$tmp/c" | cut -d'|' -f1)" = "GEOSITE,category-ads-all,REJECT" ] && ok "ads: before the apps outside the VPN" ||
  bad "ads with splitapps: $(rules_of "$tmp/c")"
if [ -n "$site" ] && [ -x "$MIHOMO" ]; then
  if out=$("$MIHOMO" -t -d "$CORE_DIR" -f "$tmp/c" 2>&1); then ok "ads: mihomo -t with geosite.dat"; else bad "ads: mihomo -t: $(tail -2 <<<"$out")"; fi
else echo "skip  ads: mihomo -t (no geosite.dat or mihomo)"; fi
put adblock 0
gen "$fx/ok-minimal.json"
[ "$(rules_of "$tmp/c" | grep -c REJECT)" = 0 ] && ok "ads: off, no rule" || bad "ads off: $(rules_of "$tmp/c")"
printf '[]' > "$tmp/g.json"; printf '["GEOSITE,category-ads-all,REJECT","DOMAIN,ad.example,REJECT-DROP","MATCH,only"]' > "$tmp/r.json"
[ -z "$(direct_sig "$tmp/g.json" "$tmp/r.json")" ] && ok "direct_sig: REJECT rules are not direct" || bad "direct_sig: $(direct_sig "$tmp/g.json" "$tmp/r.json")"
rm -f "$SETTINGS"

# --- pins
gen "$fx/ok-full.json"
[ "$(sort "$tmp/c.pins" | paste -sd' ' -)" = "de.example.com	203.0.113.20 fi.example.com	203.0.113.30" ] &&
  ok "pins: one line per host name" || bad "pins: $(cat "$tmp/c.pins")"
printf 'de.example.com\t198.51.100.20\nfi.example.com\t203.0.113.30\n' > "$tmp/pins"
resolve_host() { echo "DNS asked for $1" >> "$tmp/dns"; return 1; }
KS_PINS="$tmp/pins" gen "$fx/ok-full.json" || bad "rebuild from pins refused: $(cat "$tmp/err")"
[ "$(val proxies.1.server "$tmp/c")" = 198.51.100.20 ] && [ "$(val proxies.1.sni "$tmp/c")" = de.example.com ] &&
  grep -qx 198.51.100.20 "$tmp/s" && ! grep -qx 203.0.113.20 "$tmp/s" && ok "rebuild uses the pinned address" || bad "rebuild"
[ -e "$tmp/dns" ] && bad "rebuild asked DNS" || ok "rebuild asks no DNS"
printf 'fi.example.com\t203.0.113.30\n' > "$tmp/pins"
KS_PINS="$tmp/pins" gen "$fx/ok-full.json" && bad "rebuild with an unpinned name accepted" || ok "rebuild with an unpinned name refused"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
