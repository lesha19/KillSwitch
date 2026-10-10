#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Protocols of the core profile (issue #9): every outbound type of the pinned mihomo that has one
# server, the keys each may carry, and what the helper refuses: file paths where mihomo would read a
# file, dial targets outside the pinned servers, overlay networks with their own control plane.
# The ok-<type>.json fixtures are also run through core-config.sh ("mihomo -t"). No root, no network.
#   Helper/tests/core-protocols.sh   (MIHOMO=/path/to/mihomo for "mihomo -t")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"
SETTINGS="$tmp/settings"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"; CORE_EGRESS="$CORE_DIR/egress"
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
mt()  {
  [ -x "$MIHOMO" ] || { echo "skip  $1: mihomo -t"; return; }
  local out
  if out=$("$MIHOMO" -t -d "$tmp/home" -f "$2" 2>&1); then ok "$1: mihomo -t"; else bad "$1: mihomo -t: $(tail -2 <<<"$out")"; fi
}
gen() { rm -f "$tmp/c" "$tmp/s"; core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
fixture() { gen "$here/fixtures/$1" || bad "$1 refused: $(cat "$tmp/err")"; }
servers() { paste -sd' ' - < "$tmp/s"; }
# one proxy as the whole profile
with() { printf '{"proxies":[%s],"proxy-groups":[{"name":"P","type":"select","proxies":["a"]}],"rules":["MATCH,P"]}' "$1" > "$tmp/p.json"; }
accepted() {  # accepted <what> <proxy json>
  with "$2"
  if gen "$tmp/p.json"; then ok "$1: accepted"; else bad "$1: refused: $(cat "$tmp/err")"; fi
}
refused() {  # refused <what> <proxy json>
  with "$2"
  if gen "$tmp/p.json"; then bad "$1: accepted"; else ok "$1: refused ($(head -1 "$tmp/err"))"; fi
  [ -e "$tmp/c" ] && bad "$1: config written anyway"
}
VLESS='"name":"a","type":"vless","server":"203.0.113.9","port":443,"uuid":"a3482e88-686a-4a58-8126-99c9df64b7bf","tls":true'
PEM='-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n'

# every type of the whitelist that the pinned core has (adapter/parser.go of mihomo v1.19.32)
for t in ss ssr vmess vless trojan hysteria hysteria2 tuic wireguard snell http socks5 ssh mieru anytls \
         masque trusttunnel sudoku shadowquic openvpn; do
  [[ "$t" =~ ^($PROXY_TYPES)$ ]] && ok "type $t allowed" || bad "type $t not allowed"
done
# no single server or a control plane of their own (pf would have to let the core reach anything),
# or not a proxy at all
for t in tailscale zerotier easytier gost-relay direct dns reject rematch jls restls; do
  refused "type $t" "{\"name\":\"a\",\"type\":\"$t\",\"server\":\"203.0.113.9\",\"port\":443}"
done

# UDP protocols: the server address lands in "servers", which pf opens for the core's tcp and udp only
fixture ok-hysteria2.json; [ "$(servers)" = 203.0.113.20 ] && ok "hysteria2: pinned server in servers" || bad "hysteria2: servers $(servers)"
[ "$(val proxies.0.ports "$tmp/c")" = "443,20000-30000" ] && ok "hysteria2: port hopping kept (pf passes any port of the server)" ||
  bad "hysteria2: ports"
fixture ok-tuic.json
[ "$(servers)" = "203.0.113.30 203.0.113.66" ] && ok "tuic: the ip it dials is a server too" || bad "tuic: servers $(servers)"
fixture ok-masque.json; [ "$(servers)" = 203.0.113.71 ] && ok "masque: server in servers" || bad "masque: servers $(servers)"
fixture ok-openvpn.json; [ "$(servers)" = 203.0.113.74 ] && ok "openvpn: server in servers" || bad "openvpn: servers $(servers)"
grep -q 'BEGIN CERTIFICATE' "$tmp/c" && ok "openvpn: inline ca kept" || bad "openvpn: ca"
fixture ok-wg-psk.json
[ "$(val proxies.0.pre-shared-key "$tmp/c")" = "31aIhAPwktDGpH4JDhA8GNvjFXEf/a6+UaQRyOAiyfM=" ] &&
  [ "$(val proxies.0.amnezia-wg-option.h1 "$tmp/c")" = 100-200 ] && [ "$(val proxies.0.amnezia-wg-option.s4 "$tmp/c")" = 10 ] &&
  ok "wireguard: PSK and AmneziaWG 2.0 options kept" || bad "wireguard: psk/awg"
fixture ok-mieru.json; [ "$(servers)" = 203.0.113.70 ] && ok "mieru: server in servers (port-range: any port of it)" || bad "mieru: servers"
s=$(echo 203.0.113.20 203.0.113.30 203.0.113.66 203.0.113.71 | tr ' ' '\n')
dscl() { return 0; }
printf '%s\n' "$s" > "$tmp/srv"; : > "$tmp/manual"; : > "$tmp/allow"
TSRELAYS="$tmp/none" rules "$tmp/allow" "$tmp/srv" "$tmp/manual" > "$tmp/pf"
grep -qxF "pass out quick proto { tcp udp } to { $(paste -sd, "$tmp/srv") } group $CORE_GROUP flags any keep state" "$tmp/pf" &&
  ok "pf: the core's tcp and udp reach these servers only" || bad "pf: core rule: $(grep "group $CORE_GROUP" "$tmp/pf" | head -1)"
[ "$(grep -c "proto udp.*group $CORE_GROUP\|proto { tcp udp }.*group $CORE_GROUP" "$tmp/pf")" = 1 ] &&
  ok "pf: no other udp rule for the core" || bad "pf: other udp rules for the core"
unset -f dscl

# xHTTP with a separate download server (Remnawave's "download-settings"): pinned like the server
fixture ok-vless-xhttp.json
[ "$(val proxies.0.xhttp-opts.download-settings.server "$tmp/c")" = 203.0.113.30 ] &&
  [ "$(servers)" = "203.0.113.20 203.0.113.30" ] && ok "xhttp: download server pinned and in servers" ||
  bad "xhttp: download server $(val proxies.0.xhttp-opts.download-settings.server "$tmp/c"), servers $(servers)"
[ "$(val proxies.0.xhttp-opts.download-settings.servername "$tmp/c")" = www.microsoft.com ] &&
  ok "xhttp: download servername untouched" || bad "xhttp: download servername"
with "{$VLESS,\"network\":\"xhttp\",\"xhttp-opts\":{\"download-settings\":{\"server\":\"fi.example.com\",\"port\":443}}}"
gen "$tmp/p.json" && [ "$(val proxies.0.xhttp-opts.download-settings.servername "$tmp/c")" = fi.example.com ] &&
  ok "xhttp: download host name kept as its servername" || bad "xhttp: download servername: $(cat "$tmp/err")"
refused "xhttp: unresolvable download server" "{$VLESS,\"network\":\"xhttp\",\"xhttp-opts\":{\"download-settings\":{\"server\":\"nx.example.com\"}}}"
refused "xhttp: bad download server" "{$VLESS,\"network\":\"xhttp\",\"xhttp-opts\":{\"download-settings\":{\"server\":\"a b\"}}}"
refused "xhttp: download server not a string" "{$VLESS,\"network\":\"xhttp\",\"xhttp-opts\":{\"download-settings\":{\"server\":[\"x\"]}}}"
refused "xhttp: loopback download server" "{$VLESS,\"network\":\"xhttp\",\"xhttp-opts\":{\"download-settings\":{\"server\":\"127.0.0.1\"}}}"

# keys: only what mihomo reads for the type; the rest never reaches the config
accepted "unknown keys" "{$VLESS,\"x-junk\":1,\"benchmark-url\":\"http://x\",\"interface-name\":\"en0\",\"routing-mark\":7,\"ws-path\":\"/a\"}"
for k in x-junk benchmark-url interface-name routing-mark ws-path; do
  plutil -type "proxies.0.$k" "$tmp/c" >/dev/null 2>&1 && bad "key $k kept" || ok "key $k dropped"
done
[ "$(val proxies.0.uuid "$tmp/c")" = a3482e88-686a-4a58-8126-99c9df64b7bf ] && ok "known keys kept" || bad "uuid lost"
accepted "sni on a type without it" '{"name":"a","type":"ss","server":"fi.example.com","port":8388,"cipher":"aes-128-gcm","password":"x"}'
plutil -type proxies.0.sni "$tmp/c" >/dev/null 2>&1 && bad "ss: sni added" || ok "ss: no sni or servername added"

# mihomo reads certificate/private-key (and ssh's private-key) as a file when it is not PEM text:
# a root process reading a path from the subscription. Only inline PEM is taken.
accepted "inline client certificate" "{$VLESS,\"certificate\":\"$PEM\",\"private-key\":\"-----BEGIN EC PRIVATE KEY-----\\nMHc\\n-----END EC PRIVATE KEY-----\\n\"}"
refused "certificate as a path" "{$VLESS,\"certificate\":\"/etc/ssl/cert.pem\"}"
refused "private-key as a path" "{$VLESS,\"certificate\":\"$PEM\",\"private-key\":\"../../core/config.json\"}"
refused "certificate not a string" "{$VLESS,\"certificate\":[\"/etc/hosts\"]}"
refused "download-settings certificate path" "{$VLESS,\"network\":\"xhttp\",\"xhttp-opts\":{\"download-settings\":{\"certificate\":\"cert.pem\"}}}"
refused "v2ray-plugin certificate path" '{"name":"a","type":"ss","server":"203.0.113.9","port":443,"cipher":"aes-128-gcm","password":"x","plugin":"v2ray-plugin","plugin-opts":{"mode":"websocket","tls":true,"certificate":"/var/root/c.pem"}}'
refused "hysteria2 certificate path" '{"name":"a","type":"hysteria2","server":"203.0.113.9","port":443,"password":"x","certificate":"c.crt","private-key":"c.key"}'
accepted "ssh inline key" '{"name":"a","type":"ssh","server":"203.0.113.9","port":22,"username":"u","private-key":"-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbg==\n-----END OPENSSH PRIVATE KEY-----\n"}'
refused "ssh key as a path" '{"name":"a","type":"ssh","server":"203.0.113.9","port":22,"username":"u","private-key":"/var/root/.ssh/id_ed25519"}'
accepted "wireguard private-key is a key, not a file" '{"name":"a","type":"wireguard","server":"203.0.113.9","port":51820,"ip":"10.0.0.2","private-key":"eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU=","public-key":"Cr8hWlKvtDt7nrvf+f0brNQQzabAqrjfBvas9pmowjo="}'

# dial targets outside the pinned servers
refused "hysteria2 realm (rendezvous and STUN servers)" '{"name":"a","type":"hysteria2","server":"203.0.113.9","port":443,"password":"x","realm-opts":{"enable":true,"server-url":"https://realm.example.com","stun-servers":["stun.l.google.com:19302"]}}'
refused "tuic ip not an address" '{"name":"a","type":"tuic","server":"203.0.113.9","port":443,"uuid":"u","password":"p","ip":"evil.example.com"}'
refused "tuic ip loopback" '{"name":"a","type":"tuic","server":"203.0.113.9","port":443,"uuid":"u","password":"p","ip":"127.0.0.1"}'
refused "vmess tlsmirror enrolment (named outbounds)" '{"name":"a","type":"vmess","server":"203.0.113.9","port":443,"uuid":"a3482e88-686a-4a58-8126-99c9df64b7bf","alterId":0,"cipher":"auto","tlsmirror-opts":{"connection-enrolment":{"primary-egress-outbound":"DIRECT"}}}'

# shadowsocks plugins: the ones mihomo has, none other
for p in obfs v2ray-plugin gost-plugin shadow-tls restls jls kcptun; do
  accepted "ss plugin $p" "{\"name\":\"a\",\"type\":\"ss\",\"server\":\"203.0.113.9\",\"port\":443,\"cipher\":\"aes-128-gcm\",\"password\":\"x\",\"plugin\":\"$p\",\"plugin-opts\":{\"host\":\"h\"}}"
done
refused "ss plugin not of mihomo" '{"name":"a","type":"ss","server":"203.0.113.9","port":443,"cipher":"aes-128-gcm","password":"x","plugin":"/usr/local/bin/evil"}'
refused "ss plugin-opts not an object" '{"name":"a","type":"ss","server":"203.0.113.9","port":443,"cipher":"aes-128-gcm","password":"x","plugin":"obfs","plugin-opts":"mode=tls"}'

# dialer-proxy: only another proxy or group of the profile, never DIRECT or a name mihomo makes up
printf '%s' '{"proxies":[{"name":"a","type":"ss","server":"203.0.113.9","port":443,"cipher":"aes-128-gcm","password":"x","dialer-proxy":"b"},
  {"name":"b","type":"ss","server":"203.0.113.8","port":443,"cipher":"aes-128-gcm","password":"x"}],"rules":["MATCH,a"]}' > "$tmp/p.json"
gen "$tmp/p.json" && [ "$(val proxies.0.dialer-proxy "$tmp/c")" = b ] && ok "dialer-proxy to another proxy" || bad "dialer-proxy: $(cat "$tmp/err")"
mt "dialer-proxy" "$tmp/c"
printf '%s' '{"proxies":[{"name":"a","type":"ss","server":"203.0.113.9","port":443,"cipher":"aes-128-gcm","password":"x","dialer-proxy":"G"},
  {"name":"b","type":"ss","server":"203.0.113.8","port":443,"cipher":"aes-128-gcm","password":"x"}],
  "proxy-groups":[{"name":"G","type":"select","proxies":["b"]}],"rules":["MATCH,a"]}' > "$tmp/p.json"
gen "$tmp/p.json" && ok "dialer-proxy to a group" || bad "dialer-proxy group: $(cat "$tmp/err")"
for d in DIRECT GLOBAL REJECT COMPATIBLE nope a; do
  refused "dialer-proxy $d" "{\"name\":\"a\",\"type\":\"ss\",\"server\":\"203.0.113.9\",\"port\":443,\"cipher\":\"aes-128-gcm\",\"password\":\"x\",\"dialer-proxy\":\"$d\"}"
done

# every ok fixture of this issue through "mihomo -t" once more, after the key filter
for f in ok-ss-plugins ok-hysteria ok-hysteria2 ok-tuic ok-snell ok-socks-http ok-ssh ok-mieru ok-anytls ok-masque \
         ok-trusttunnel ok-sudoku ok-shadowquic ok-openvpn ok-vless-xhttp ok-vless-mlkem ok-wg-psk; do
  fixture "$f.json" && mt "$f" "$tmp/c"
done

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
