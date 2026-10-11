#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Runs mihomo as the current user (no TUN, no DNS, controller on a unix socket in a temp dir)
# and drives it through the controller functions of Helper/ks.
#   Helper/tests/core-api.sh     (MIHOMO=/path/to/mihomo, default /Library/KillSwitch/core/mihomo)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
[ -x "$MIHOMO" ] || { echo "skip: no $MIHOMO"; exit 0; }
tmp=$(mktemp -d)
CORE_CTL="$tmp/ctl/mihomo.sock"
EVENTS="$tmp/events.log"; SETTINGS="$tmp/settings"   # not the installed core choice
cat > "$tmp/config.yaml" <<'EOF'
{"mode":"rule","log-level":"warning","external-controller-unix":"ctl/mihomo.sock",
 "proxies":[{"name":"NL 1","type":"ss","server":"192.0.2.1","port":8388,"cipher":"aes-128-gcm","password":"x"},
            {"name":"DE/2 🚀","type":"ss","server":"192.0.2.2","port":8388,"cipher":"aes-128-gcm","password":"x"}],
 "proxy-groups":[{"name":"🚀 Выбор & #1","type":"select","proxies":["NL 1","DE/2 🚀"]}],
 "rules":["MATCH,🚀 Выбор & #1"]}
EOF
"$MIHOMO" -d "$tmp" >"$tmp/log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in $(seq 1 50); do [ -S "$CORE_CTL" ] && break; sleep 0.1; done
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
now() { core_api GET "/proxies/$(urlencode "🚀 Выбор & #1")" | plutil -extract now raw -o - - 2>/dev/null; }

core_api GET /proxies > "$tmp/p.json" && plutil -type proxies "$tmp/p.json" >/dev/null && ok "proxies: JSON" || bad "proxies"
[ "$(now)" = "NL 1" ] || bad "initial selection: $(now)"
core_select "🚀 Выбор & #1" "DE/2 🚀" && [ "$(now)" = "DE/2 🚀" ] && ok "select with / & # emoji in names" || bad "select: $(now)"
core_select "🚀 Выбор & #1" "nope" 2>/dev/null && bad "select of a missing proxy accepted" || ok "select of a missing proxy refused"
core_select "NL 1" "DE/2 🚀" 2>/dev/null && bad "select on a non-group accepted" || ok "select on a non-group refused"
core_select "../configs" "x" 2>/dev/null && bad "path in group name accepted" || ok "path in group name stays a name"
out=$(core_delay "NL 1" 2>&1); ok "delay proxy: $out"
out=$(core_delay "🚀 Выбор & #1" 2>&1); ok "delay group: $out"
# graceful reload (rotation, settings): the config file is reread, the selection survives
launchctl() { echo "launchctl $*" >> "$tmp/launchd"; return 0; }
sed -e 's/"DE\/2 🚀","type":"ss","server":"192.0.2.2"/"DE\/2 🚀","type":"ss","server":"192.0.2.3"/' \
    -e 's/"proxies":\["NL 1","DE\/2 🚀"\]/"proxies":["NL 1","DE\/2 🚀","NEW"]/' \
    -e 's/^ "proxies":\[/ "proxies":[{"name":"NEW","type":"ss","server":"192.0.2.9","port":8388,"cipher":"aes-128-gcm","password":"x"},/' \
    "$tmp/config.yaml" > "$tmp/config.new" && mv "$tmp/config.new" "$tmp/config.yaml"
core_reload
core_api GET "/proxies/NEW" >/dev/null 2>&1 && ok "reload: new config in use" || bad "reload: NEW missing"
grep -q kickstart "$tmp/launchd" 2>/dev/null && bad "reload fell back to a restart" || ok "reload without restart"
[ "$(now)" = "DE/2 🚀" ] && ok "reload keeps the selection" || bad "selection after reload: $(now)"
out=$(core_traffic) && [[ "$out" =~ ^up=[0-9]+\ down=[0-9]+$ ]] && ok "traffic: $out" || bad "traffic: $out"
core_connections > "$tmp/conn.json" && [ "$(plutil -type connections "$tmp/conn.json")" = array ] &&
  [ "$(plutil -type providers "$tmp/conn.json")" = dictionary ] && ok "connections: JSON from the running core" || bad "connections: $(cat "$tmp/conn.json")"
# only the totals leave ks: never the connections' hosts, addresses or processes
core_api() { printf '%s' '{"downloadTotal":123456,"uploadTotal":7890,"connections":[{"id":"a","metadata":{"host":"secret.example","destinationIP":"203.0.113.5","process":"Safari"},"upload":5,"download":9}],"memory":1}'; }
[ "$(core_traffic)" = "up=7890 down=123456" ] && ok "traffic: totals only" || bad "traffic: $(core_traffic)"
core_api() { printf '%s' '{"connections":[]}'; }
core_traffic >/dev/null 2>&1 && bad "traffic without totals accepted" || ok "traffic without totals fails"
# connections (the «Трафик» window): what the app shows, and nothing else of the core's reply
core_api() {
  case "$2" in
    /connections) printf '%s' '{"downloadTotal":10,"uploadTotal":20,"memory":1,"connections":[{"id":"c-1","metadata":{"network":"tcp","type":"Tun","sourceIP":"198.18.128.1","sourcePort":"50000","destinationIP":"203.0.113.5","destinationPort":"443","host":"ya\u0007.ru","process":"Safari","processPath":"/Applications/Safari.app/Contents/MacOS/Safari","uid":501,"inboundIP":"x","dnsMode":"fakeip"},"upload":5,"download":9,"start":"2026-10-10T10:00:00Z","chains":["DIRECT"],"rule":"DomainSuffix","rulePayload":"ru"}]}' ;;
    /providers/rules) printf '%s' '{"providers":{"ru-http":{"behavior":"Domain","format":"MrsRule","name":"ru-http","ruleCount":1234,"type":"Rule","updatedAt":"2026-10-10T09:00:00Z","vehicleType":"HTTP"}}}' ;;
  esac
}
x() { plutil -extract "$1" raw -o - "$tmp/c2.json" 2>/dev/null; }
core_connections > "$tmp/c2.json" || bad "connections: failed on a full reply"
[ "$(x connections.0.host)" = "ya?.ru" ] && [ "$(x connections.0.rule)" = DomainSuffix ] && [ "$(x connections.0.chains.0)" = DIRECT ] &&
  [ "$(x connections.0.download)" = 9 ] && [ "$(x connections.0.process)" = Safari ] &&
  ok "connections: host (control characters replaced), rule, route, bytes, program" || bad "connections: $(cat "$tmp/c2.json")"
grep -qE 'sourceIP|sourcePort|198\.18\.128\.1|inboundIP|"uid"|memory' "$tmp/c2.json" &&
  bad "connections: more than the window needs: $(cat "$tmp/c2.json")" || ok "connections: no source address, port or uid"
[ "$(x providers.ru-http.count)" = 1234 ] && [ "$(x downloadTotal)" = 10 ] && ok "connections: provider sizes and totals" ||
  bad "connections providers: $(cat "$tmp/c2.json")"
core_api() { return 1; }
core_connections >/dev/null 2>&1 && bad "connections without a core accepted" || ok "connections: fails when the core does not answer"
valid_name "$(printf 'a\nb')" && bad "newline in a name accepted" || ok "newline in a name refused"
valid_name "" && bad "empty name accepted" || ok "empty name refused"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
