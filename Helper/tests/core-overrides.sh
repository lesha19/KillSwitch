#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Per-server transport overrides of Helper/ks (ADR 0007): the app puts «Дополнительно» choices in
# "x-ks-overrides"; the helper applies only the TLS fingerprint and multiplexing, only values it
# knows, only where mihomo supports them. No root, no network.
#   Helper/tests/core-overrides.sh   (MIHOMO=/path/to/mihomo for "mihomo -t")
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
mt()  {
  [ -x "$MIHOMO" ] || { echo "skip  $1: mihomo -t"; return; }
  local out
  if out=$("$MIHOMO" -t -d "$tmp/home" -f "$2" 2>&1); then ok "$1: mihomo -t"; else bad "$1: mihomo -t: $(tail -2 <<<"$out")"; fi
}
gen() { core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
proxy() {  # proxy <name> <config>: the proxy's JSON, canonical
  /usr/bin/perl -MJSON::PP -e 'local $/; open my $f, "<", $ARGV[1] or die; my $c = JSON::PP->new->decode(<$f>);
    my ($p) = grep { $_->{name} eq $ARGV[0] } @{ $c->{proxies} }; print $p ? JSON::PP->new->canonical->encode($p) : ""' "$1" "$2"
}
PROXIES='[{"name":"ss","type":"ss","server":"198.51.100.1","port":8388,"cipher":"aes-128-gcm","password":"x"},
  {"name":"vless","type":"vless","server":"198.51.100.2","port":443,"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","tls":true,"servername":"example.com","client-fingerprint":"chrome"},
  {"name":"vision","type":"vless","server":"198.51.100.3","port":443,"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","tls":true,"flow":"xtls-rprx-vision","servername":"example.com"},
  {"name":"trojan","type":"trojan","server":"198.51.100.4","port":443,"password":"x","sni":"example.com"},
  {"name":"hy2","type":"hysteria2","server":"198.51.100.5","port":443,"password":"x"}]'
with() { printf '%s' "{\"proxies\":$PROXIES,\"proxy-groups\":[{\"name\":\"P\",\"type\":\"select\",\"proxies\":[\"ss\",\"vless\",\"vision\",\"trojan\",\"hy2\"]}],\"rules\":[\"MATCH,P\"],\"x-ks-overrides\":$1}" > "$tmp/p.json"; }
refused() {  # refused <what> <overrides>
  with "$2"
  if gen "$tmp/p.json"; then bad "$1: accepted"; else ok "$1: refused ($(head -1 "$tmp/err"))"; fi
}

with '{}'
gen "$tmp/p.json" || bad "empty overrides refused: $(cat "$tmp/err")"
cp "$tmp/c.direct" "$tmp/plain.direct"; cp "$tmp/s" "$tmp/plain.servers"
[ "$(proxy vless "$tmp/c" | grep -c '"client-fingerprint":"chrome"')" = 1 ] && ok "no override: the subscription's fingerprint stays" ||
  bad "vless: $(proxy vless "$tmp/c")"

with '{"vless":{"client-fingerprint":"firefox","smux":{"enabled":true,"protocol":"h2mux"}},
       "trojan":{"client-fingerprint":"random"},"ss":{"smux":{"enabled":true,"protocol":"yamux"}},"vision":{"client-fingerprint":"safari"}}'
gen "$tmp/p.json" || bad "overrides refused: $(cat "$tmp/err")"
v=$(proxy vless "$tmp/c")
grep -q '"client-fingerprint":"firefox"' <<<"$v" && ok "vless: fingerprint replaced" || bad "vless: $v"
grep -q '"smux":{"enabled":true,"protocol":"h2mux"}' <<<"$v" && ok "vless: multiplexing on, h2mux" || bad "vless smux: $v"
grep -q '"server":"198.51.100.2"' <<<"$v" && ok "vless: same server" || bad "vless server: $v"
grep -q '"client-fingerprint":"random"' <<<"$(proxy trojan "$tmp/c")" && ok "trojan: fingerprint set" || bad "trojan: $(proxy trojan "$tmp/c")"
grep -q '"smux":{"enabled":true,"protocol":"yamux"}' <<<"$(proxy ss "$tmp/c")" && ok "ss: multiplexing" || bad "ss: $(proxy ss "$tmp/c")"
grep -q '"client-fingerprint":"safari"' <<<"$(proxy vision "$tmp/c")" && ok "vision: fingerprint" || bad "vision: $(proxy vision "$tmp/c")"
cmp -s "$tmp/c.direct" "$tmp/plain.direct" && cmp -s "$tmp/s" "$tmp/plain.servers" &&
  ok "same servers, same DIRECT signature: a passwordless refresh applies them" || bad "servers or signature changed"
grep -q 'x-ks-overrides' "$tmp/c" && bad "overrides key left in the config" || ok "overrides key not in the config"
mt "overrides" "$tmp/c"

with '{"vless":{"smux":{"enabled":false}}}'
gen "$tmp/p.json" || bad "mux off refused: $(cat "$tmp/err")"
grep -q '"smux":{"enabled":false}' <<<"$(proxy vless "$tmp/c")" && ok "multiplexing can be turned off" || bad "mux off: $(proxy vless "$tmp/c")"

refused "unknown server" '{"nope":{"client-fingerprint":"chrome"}}'
refused "a group, not a server" '{"P":{"client-fingerprint":"chrome"}}'
refused "unknown fingerprint" '{"vless":{"client-fingerprint":"bogus"}}'
refused "fingerprint on shadowsocks" '{"ss":{"client-fingerprint":"chrome"}}'
refused "fingerprint on hysteria2" '{"hy2":{"client-fingerprint":"chrome"}}'
refused "multiplexing on hysteria2 (UDP)" '{"hy2":{"smux":{"enabled":true,"protocol":"smux"}}}'
refused "multiplexing with vision flow" '{"vision":{"smux":{"enabled":true,"protocol":"smux"}}}'
refused "unknown mux protocol" '{"ss":{"smux":{"enabled":true,"protocol":"quic"}}}'
refused "other smux options" '{"ss":{"smux":{"enabled":true,"protocol":"smux","brutal-opts":{"enabled":true}}}}'
refused "other keys" '{"vless":{"server":"203.0.113.9"}}'
refused "dialer-proxy" '{"vless":{"dialer-proxy":"trojan"}}'
refused "interface-name" '{"vless":{"interface-name":"en0"}}'
refused "not an object" '["vless"]'
refused "string enabled" '{"ss":{"smux":{"enabled":"true","protocol":"smux"}}}'

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
