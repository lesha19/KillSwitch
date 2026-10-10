#!/bin/bash
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
EVENTS="$tmp/events.log"
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
valid_name "$(printf 'a\nb')" && bad "newline in a name accepted" || ok "newline in a name refused"
valid_name "" && bad "empty name accepted" || ok "empty name refused"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
