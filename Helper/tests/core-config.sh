#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Runs the core config generator of Helper/ks against the fixtures; no root, no network.
#   Helper/tests/core-config.sh            (MIHOMO=/path/to/mihomo to check with "mihomo -t";
#                                           default /Library/KillSwitch/core/mihomo if present)
# ok-*.json must be accepted, bad-* must be refused. Accepted configs are checked for the
# keys that must not survive and then with "mihomo -t".
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"

# host names in the fixtures; anything else does not resolve
resolve_host() {
  case "$1" in
    de.example.com) echo 203.0.113.20 ;;
    fi.example.com) echo 203.0.113.30 ;;
    *) return 1 ;;
  esac
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"
fails=0
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails + 1)); }
val()  { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
top_keys() { plutil -convert xml1 -o - "$1" | sed -n 's/^	<key>\(.*\)<\/key>$/\1/p' | sort | paste -sd' ' -; }

check_config() {  # check_config <name> <config> <servers>
  local name=$1 c=$2 s=$3 n i want got
  want="dns external-controller-unix geo-auto-update ipv6 log-level mode allow-lan proxies proxy-groups rule-providers rules tun"
  want=$(tr ' ' '\n' <<<"$want" | sort | paste -sd' ' -)
  got=$(top_keys "$c")
  [ "$got" = "$want" ] && ok "$name: top-level keys" || bad "$name: top-level keys: $got"
  [ "$(val dns.listen "$c")" = 127.0.0.1:53 ] && ok "$name: dns listen" || bad "$name: dns listen"
  [ "$(val external-controller-unix "$c")" = ctl/mihomo.sock ] && ok "$name: controller" || bad "$name: controller"
  [ "$(val allow-lan "$c")" = false ] && [ "$(val mode "$c")" = rule ] && [ "$(val tun.stack "$c")" = gvisor ] &&
    ok "$name: template values" || bad "$name: template values"
  # no IPv6 in the core: IPv6 stays out of the tunnel and pf lets only link-local of it out (rules.sh)
  [ "$(val ipv6 "$c")" = false ] && [ "$(val dns.ipv6 "$c")" = false ] && ! plutil -type tun.inet6-address "$c" >/dev/null 2>&1 &&
    ok "$name: IPv6 off in the core and its DNS" || bad "$name: IPv6 settings"
  # the home network and Tailscale never enter the TUN: with «Домашняя сеть» off pf blocks them
  for a in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    grep -q "\"$a\"" "$c" || bad "$name: $a not excluded from the TUN routes"
  done
  [ "$(val log-level "$c")" = warning ] && ok "$name: log-level warning (no visited domains in core.log)" || bad "$name: log-level $(val log-level "$c")"
  n=$(val proxies "$c"); i=0
  while [ "$i" -lt "$n" ]; do
    if plutil -type "proxies.$i.peers" "$c" >/dev/null 2>&1; then
      k=0
      while plutil -type "proxies.$i.peers.$k" "$c" >/dev/null 2>&1; do
        is_ipv4 "$(val "proxies.$i.peers.$k.server" "$c")" || bad "$name: proxies[$i].peers[$k].server is not an address"
        grep -qxF "$(val "proxies.$i.peers.$k.server" "$c")" "$s" || bad "$name: proxies[$i].peers[$k] server missing from servers"
        k=$((k + 1))
      done
      plutil -type "proxies.$i.server" "$c" >/dev/null 2>&1 && bad "$name: proxies[$i] kept a top-level server next to peers"
    else
      is_ipv4 "$(val "proxies.$i.server" "$c")" || bad "$name: proxies[$i].server is not an address"
      grep -qxF "$(val "proxies.$i.server" "$c")" "$s" || bad "$name: proxies[$i] server missing from servers"
    fi
    plutil -type "proxies.$i.interface-name" "$c" >/dev/null 2>&1 && bad "$name: proxies[$i] kept interface-name"
    i=$((i + 1))
  done
  ok "$name: $n proxies pinned to addresses"
  [ "$(val dns.nameserver.0 "$c")" = "https://1.1.1.1/dns-query#KS-DNS" ] &&
    [ "$(val dns.nameserver.1 "$c")" = "https://8.8.8.8/dns-query#KS-DNS" ] && ok "$name: DNS through KS-DNS" ||
    bad "$name: nameserver $(val dns.nameserver.0 "$c")"
  # KS-DNS: our last group, a fallback over every proxy of the profile and nothing else
  g=$(( $(val proxy-groups "$c") - 1 ))
  if [ "$(val "proxy-groups.$g.name" "$c")" = KS-DNS ] && [ "$(val "proxy-groups.$g.type" "$c")" = fallback ] &&
     [ "$(val "proxy-groups.$g.proxies" "$c")" = "$n" ]; then
    i=0; same=1
    while [ "$i" -lt "$n" ]; do
      [ "$(val "proxy-groups.$g.proxies.$i" "$c")" = "$(val "proxies.$i.name" "$c")" ] || same=0
      i=$((i + 1))
    done
    [ "$same" = 1 ] && ok "$name: KS-DNS = fallback over the $n proxies, no DIRECT" || bad "$name: KS-DNS members"
  else
    bad "$name: KS-DNS group missing or wrong"
  fi
  if [ -x "$MIHOMO" ]; then
    if out=$("$MIHOMO" -t -d "$tmp/home" -f "$c" 2>&1); then ok "$name: mihomo -t"
    else bad "$name: mihomo -t: $(tail -2 <<<"$out")"; fi
  else
    echo "skip  $name: mihomo -t (no $MIHOMO)"
  fi
}

mkdir -p "$tmp/home"
for f in "$here"/fixtures/*; do
  name=$(basename "$f")
  if err=$(core_generate "$f" "$tmp/$name.config" "$tmp/$name.servers" 2>&1); then
    case "$name" in
      ok-*) ok "$name: accepted"; check_config "$name" "$tmp/$name.config" "$tmp/$name.servers" ;;
      *)    bad "$name: accepted" ;;
    esac
  else
    case "$name" in
      ok-*) bad "$name: refused: $err" ;;
      *)    ok "$name: refused: $err"
            [ -e "$tmp/$name.config" ] && bad "$name: config written anyway" ;;
    esac
  fi
done

# fixture specifics
c="$tmp/ok-full.json.config"
if [ -f "$c" ]; then
  [ "$(val proxies.1.server "$c")" = 203.0.113.20 ] && [ "$(val proxies.1.sni "$c")" = de.example.com ] &&
    ok "ok-full: host name replaced by its address, sni kept" || bad "ok-full: host name / sni"
  [ "$(val proxies.0.servername "$c")" = www.microsoft.com ] && ok "ok-full: reality servername untouched" ||
    bad "ok-full: reality servername"
  [ "$(val proxies.2.ws-opts.headers.Host "$c")" = fi.example.com ] && ok "ok-full: ws Host header kept" ||
    bad "ok-full: ws Host"
  plutil -type rule-providers.ru-blocked.path "$c" >/dev/null 2>&1 && bad "ok-full: provider path kept" ||
    ok "ok-full: provider path dropped"
  [ "$(val rule-providers.ru-blocked.proxy "$c")" = KS-DNS ] && ok "ok-full: provider downloads through KS-DNS" ||
    bad "ok-full: provider proxy"
  plutil -type proxy-groups.1.interface-name "$c" >/dev/null 2>&1 && bad "ok-full: group kept interface-name" ||
    ok "ok-full: group interface-name dropped"
  for a in 203.0.113.10 203.0.113.20 203.0.113.30; do
    grep -q "\"$a/32\"" "$c" || bad "ok-full: $a not excluded from the TUN routes"
  done
  ok "ok-full: servers: $(paste -sd' ' - < "$tmp/ok-full.json.servers")"
  [ "$(val proxies.1.password "$c")" = 'p\/x' ] && ok "ok-full: backslash before / survives the \\/ fix" ||
    bad "ok-full: password: $(val proxies.1.password "$c")"
  [ "$(val proxies.1.name "$c")" = 'DE trojan "q"' ] && ok "ok-full: quotes in names" || bad "ok-full: name"
fi
c="$tmp/ok-minimal.json.config"
[ -f "$c" ] && { [ "$(val rules.0 "$c")" = "MATCH,only" ] && ok "ok-minimal: default rule goes to the proxy, not DIRECT" ||
  bad "ok-minimal: default rule"; }
c="$tmp/ok-wg-peers.json.config"
[ -f "$c" ] && { [ "$(val proxies.0.peers.0.server "$c")" = 203.0.113.20 ] && [ "$(val proxies.0.peers.1.server "$c")" = 203.0.113.40 ] &&
  [ "$(paste -sd' ' - < "$tmp/ok-wg-peers.json.servers")" = "203.0.113.20 203.0.113.40" ] &&
  ok "ok-wg-peers: every peer pinned and in servers" || bad "ok-wg-peers: peers"; }
c="$tmp/ok-awg.json.config"
[ -f "$c" ] && { [ "$(val proxies.0.amnezia-wg-option.jc "$c")" = 4 ] && [ "$(val proxies.0.amnezia-wg-option.h4 "$c")" = 1234567894 ] &&
  [ "$(val proxies.0.amnezia-wg-option.itime "$c")" = 120 ] && ok "ok-awg: amnezia-wg-option passed through" || bad "ok-awg: amnezia-wg-option"; }

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
