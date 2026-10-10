#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Auto-failover groups of Helper/ks (ADR 0005): the app names same-country server sets in
# "x-ks-failover", the helper turns each into a hidden fallback group the main selector can pick.
# No root, no network.
#   Helper/tests/core-failover.sh   (MIHOMO=/path/to/mihomo for "mihomo -t")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"
SETTINGS="$tmp/settings"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
resolve_host() { return 1; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
val() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
mt()  {
  [ -x "$MIHOMO" ] || { echo "skip  $1: mihomo -t"; return; }
  local out
  if out=$("$MIHOMO" -t -d "$tmp/home" -f "$2" 2>&1); then ok "$1: mihomo -t"; else bad "$1: mihomo -t: $(tail -2 <<<"$out")"; fi
}
gen() { core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
profile() { printf '%s' "$1" > "$tmp/p.json"; }
group() {  # group <name> <config>: the group's JSON, canonical
  /usr/bin/perl -MJSON::PP -e 'local $/; open my $f, "<", $ARGV[1] or die; my $c = JSON::PP->new->decode(<$f>);
    my ($g) = grep { $_->{name} eq $ARGV[0] } @{ $c->{"proxy-groups"} }; print $g ? JSON::PP->new->canonical->encode($g) : ""' "$1" "$2"
}
SS='"type":"ss","port":8388,"cipher":"aes-128-gcm","password":"x"'
PROXIES="[{\"name\":\"🇱🇹 Литва 1\",\"server\":\"198.51.100.1\",$SS},{\"name\":\"🇱🇹 Литва 2\",\"server\":\"198.51.100.2\",$SS},
  {\"name\":\"🇩🇪 Германия\",\"server\":\"198.51.100.3\",$SS},{\"name\":\"🇳🇱 NL 1\",\"server\":\"198.51.100.4\",$SS},
  {\"name\":\"🇳🇱 NL 2\",\"server\":\"198.51.100.5\",$SS}]"
PGROUPS='[{"name":"🚀 Выбор","type":"select","proxies":["⚡ Авто","🇱🇹 Литва 1","🇱🇹 Литва 2","🇩🇪 Германия","🇳🇱 NL 1","🇳🇱 NL 2","DIRECT"]},
  {"name":"⚡ Авто","type":"url-test","proxies":["🇱🇹 Литва 1","🇱🇹 Литва 2","🇩🇪 Германия"],"url":"https://www.gstatic.com/generate_204","interval":300}]'
with_hint() { profile "{\"proxies\":$PROXIES,\"proxy-groups\":$PGROUPS,\"rules\":[\"MATCH,🚀 Выбор\"],\"x-ks-failover\":$1}"; }

# --- no hint: the profile's groups only
with_hint '[]'
gen "$tmp/p.json" || bad "empty hint refused: $(cat "$tmp/err")"
grep -q 'KS-FO-' "$tmp/c" && bad "empty hint: failover group added" || ok "empty hint: no failover groups"
cp "$tmp/c.direct" "$tmp/plain.direct"

# --- one group per country set, hidden, health-checked through the proxies, offered by the main selector
with_hint '[["🇱🇹 Литва 1","🇱🇹 Литва 2"],["🇳🇱 NL 1","🇳🇱 NL 2"]]'
gen "$tmp/p.json" || bad "hint refused: $(cat "$tmp/err")"
[ "$(group KS-FO-1 "$tmp/c")" = '{"hidden":true,"interval":120,"name":"KS-FO-1","proxies":["🇱🇹 Литва 1","🇱🇹 Литва 2"],"type":"fallback","url":"https://cp.cloudflare.com/generate_204"}' ] &&
  ok "KS-FO-1: hidden fallback over the Lithuanian servers, checked every 2 min" || bad "KS-FO-1: $(group KS-FO-1 "$tmp/c")"
[ "$(group KS-FO-2 "$tmp/c" | grep -c 'NL 1","🇳🇱 NL 2')" = 1 ] &&
  ok "KS-FO-2: the Dutch servers" || bad "KS-FO-2: $(group KS-FO-2 "$tmp/c")"
main=$(group "🚀 Выбор" "$tmp/c")
grep -q '"DIRECT","KS-FO-1","KS-FO-2"\]' <<<"$main" && ok "main selector offers the failover groups after its own members" ||
  bad "main selector: $main"
[ "$(group "⚡ Авто" "$tmp/c" | grep -c KS-FO)" = 0 ] && ok "other groups untouched" || bad "url-test group changed"
cmp -s "$tmp/c.direct" "$tmp/plain.direct" && ok "the DIRECT signature ignores the failover groups (refresh needs no password)" ||
  bad "signature changed: $(diff "$tmp/plain.direct" "$tmp/c.direct")"
grep -q 'KS-FO' "$tmp/c.direct" && bad "failover group in the signature" || ok "no failover group in the signature"
grep -q 'x-ks-failover' "$tmp/c" && bad "hint key left in the config" || ok "hint key not in the config"
[ "$(paste -sd' ' - < "$tmp/s")" = "198.51.100.1 198.51.100.2 198.51.100.3 198.51.100.4 198.51.100.5" ] &&
  ok "servers unchanged" || bad "servers: $(paste -sd' ' - < "$tmp/s")"
mt "failover groups" "$tmp/c"

# --- refused hints: only the profile's own servers, each set at least two, no clashes
for h in '{"a":1}' '[["🇱🇹 Литва 1"]]' '[["🇱🇹 Литва 1","nope"]]' '[["🇱🇹 Литва 1","⚡ Авто"]]' '[["🇱🇹 Литва 1","DIRECT"]]' \
         '[["🇱🇹 Литва 1",["🇱🇹 Литва 2"]]]' '[["🇱🇹 Литва 1","🇱🇹 Литва 2"],["🇱🇹 Литва 2","🇩🇪 Германия"]]' '"x"'; do
  with_hint "$h"
  if gen "$tmp/p.json"; then bad "hint $h accepted"; else ok "hint $h refused: $(tail -1 "$tmp/err")"; fi
done
profile "{\"proxies\":[{\"name\":\"KS-FO-1\",\"server\":\"198.51.100.1\",$SS},{\"name\":\"b\",\"server\":\"198.51.100.2\",$SS}],\"x-ks-failover\":[[\"KS-FO-1\",\"b\"]]}"
gen "$tmp/p.json" && bad "profile name KS-FO-1 accepted" || ok "profile names starting with KS-FO- refused: $(tail -1 "$tmp/err")"
big=$(perl -e 'print "[", join(",", map { "[\"🇱🇹 Литва 1\",\"🇱🇹 Литва 2\"]" } 1..101), "]"')
with_hint "$big"
gen "$tmp/p.json" && bad "101 sets accepted" || ok "more than 100 sets refused"

# --- without a select group there is nothing to offer them in: hint ignored
profile "{\"proxies\":$PROXIES,\"x-ks-failover\":[[\"🇱🇹 Литва 1\",\"🇱🇹 Литва 2\"]]}"
gen "$tmp/p.json" || bad "no selector: refused: $(cat "$tmp/err")"
grep -q 'KS-FO-' "$tmp/c" && bad "no selector: failover group added" || ok "no selector: hint ignored"

# --- the kept profile carries the hint: a rebuild (rotation, settings) keeps the groups
with_hint '[["🇱🇹 Литва 1","🇱🇹 Литва 2"]]'
: > "$tmp/pins"
KS_PINS="$tmp/pins" gen "$tmp/p.json" || bad "rebuild refused: $(cat "$tmp/err")"
[ -n "$(group KS-FO-1 "$tmp/c")" ] && ok "rebuild keeps the failover group" || bad "rebuild lost the failover group"
# double VPN: the exits of a set dial through the entry like every other proxy
put_setting multihop "🇩🇪 Германия"
gen "$tmp/p.json" || bad "multihop: refused: $(cat "$tmp/err")"
[ "$(val proxies.0.dialer-proxy "$tmp/c")" = "🇩🇪 Германия" ] && [ -n "$(group KS-FO-1 "$tmp/c")" ] &&
  ok "multihop and failover together" || bad "multihop with failover"
mt "multihop and failover" "$tmp/c"
rm -f "$SETTINGS"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
