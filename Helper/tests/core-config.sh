#!/bin/bash
# Runs the core config generator of Helper/ks against the fixtures; no root, no network.
#   Helper/tests/core-config.sh            (MIHOMO=/path/to/mihomo to check with "mihomo -t";
#                                           default /Library/KillSwitch/core/mihomo if present)
# ok-*.json must be accepted, bad-* must be refused. Accepted configs are checked for the
# keys that must not survive and then with "mihomo -t".
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}

# host names in the fixtures; anything else does not resolve
resolve_host() {
  case "$1" in
    de.example.com) echo 203.0.113.20 ;;
    fi.example.com) echo 203.0.113.30 ;;
    *) return 1 ;;
  esac
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails + 1)); }
val()  { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
top_keys() { plutil -convert xml1 -o - "$1" | sed -n 's/^	<key>\(.*\)<\/key>$/\1/p' | sort | paste -sd' ' -; }

check_config() {  # check_config <name> <config> <servers>
  local name=$1 c=$2 s=$3 n i want got
  want="dns external-controller-unix ipv6 log-level mode allow-lan proxies proxy-groups rule-providers rules tun"
  want=$(tr ' ' '\n' <<<"$want" | sort | paste -sd' ' -)
  got=$(top_keys "$c")
  [ "$got" = "$want" ] && ok "$name: top-level keys" || bad "$name: top-level keys: $got"
  [ "$(val dns.listen "$c")" = 127.0.0.1:53 ] && ok "$name: dns listen" || bad "$name: dns listen"
  [ "$(val external-controller-unix "$c")" = ctl/mihomo.sock ] && ok "$name: controller" || bad "$name: controller"
  [ "$(val allow-lan "$c")" = false ] && [ "$(val mode "$c")" = rule ] && [ "$(val tun.stack "$c")" = gvisor ] &&
    ok "$name: template values" || bad "$name: template values"
  n=$(val proxies "$c"); i=0
  while [ "$i" -lt "$n" ]; do
    is_ipv4 "$(val "proxies.$i.server" "$c")" || bad "$name: proxies[$i].server is not an address"
    plutil -type "proxies.$i.interface-name" "$c" >/dev/null 2>&1 && bad "$name: proxies[$i] kept interface-name"
    grep -qxF "$(val "proxies.$i.server" "$c")" "$s" || bad "$name: proxies[$i] server missing from servers"
    i=$((i + 1))
  done
  ok "$name: $n proxies pinned to addresses"
  [[ "$(val dns.nameserver.0 "$c")" == https://1.1.1.1/dns-query#* ]] && ok "$name: DNS through the tunnel ($(val dns.nameserver.0 "$c"))" ||
    bad "$name: nameserver"
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
  [ "$(val dns.nameserver.0 "$c")" = "https://1.1.1.1/dns-query#🚀 Выбор сервера" ] &&
    ok "ok-full: DNS group skips a name with #" || bad "ok-full: DNS group: $(val dns.nameserver.0 "$c")"
  plutil -type rule-providers.ru-blocked.path "$c" >/dev/null 2>&1 && bad "ok-full: provider path kept" ||
    ok "ok-full: provider path dropped"
  [ "$(val rule-providers.ru-blocked.proxy "$c")" = "🚀 Выбор сервера" ] && ok "ok-full: provider downloads through the tunnel" ||
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

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
