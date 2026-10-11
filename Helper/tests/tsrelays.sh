#!/bin/bash
# Helper/update-tsrelays.sh (KS-19) with curl and dig faked: a failed download, a network instead
# of an address or a list too short never replaces Helper/tsrelays. Nothing leaves the Mac.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/h" "$tmp/bin"
cp "$here/../update-tsrelays.sh" "$tmp/h/"
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
[ "$MODE" = curl-fails ] && exit 22
python3 -I -c '
import json, os
nodes = [{"IPv4": "192.0.2.%d" % i, "IPv6": "2001:db8::%x" % i} for i in range(1, 41)]
if os.environ["MODE"] == "network": nodes.append({"IPv4": "0.0.0.0/0"})
if os.environ["MODE"] == "short": nodes = nodes[:3]
if os.environ["MODE"] == "garbage": nodes.append({"IPv4": "relay.example"})
print(json.dumps({"Regions": {"1": {"Nodes": nodes}}}))'
EOF
cat > "$tmp/bin/dig" <<'EOF'
#!/bin/bash
case "$*" in *AAAA*) echo 2001:db8:1::1 ;; *) echo 198.51.100.1 ;; esac
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/dig"
fails=0
check() {  # check <desc> <condition...>
  local d=$1; shift
  if "$@"; then echo "ok    $d"; else echo "FAIL  $d"; fails=$((fails + 1)); fi
}
old="# old list
203.0.113.1"
run() { printf '%s\n' "$old" > "$tmp/h/tsrelays"; MODE=$1 PATH="$tmp/bin:$PATH" bash "$tmp/h/update-tsrelays.sh" >/dev/null 2>&1; }
kept() { [ "$(cat "$tmp/h/tsrelays")" = "$old" ] && [ ! -e "$tmp/h/tsrelays.tmp" ]; }

run ok; rc=$?
check "good map: written" [ "$rc" = 0 ] && grep -qx 192.0.2.1 "$tmp/h/tsrelays" && grep -qx 198.51.100.1 "$tmp/h/tsrelays"
check "good map: host addresses only" [ "$(grep -v '^#' "$tmp/h/tsrelays" | grep -c /)" = 0 ]
run curl-fails; rc=$?
check "download failed: fails and keeps the old list" [ "$rc" != 0 ] && kept
run network; rc=$?
check "a network (0.0.0.0/0) in the map: fails and keeps the old list" [ "$rc" != 0 ] && kept
run garbage; rc=$?
check "a name instead of an address: fails and keeps the old list" [ "$rc" != 0 ] && kept
run short; rc=$?
check "far fewer relays than usual: fails and keeps the old list" [ "$rc" != 0 ] && kept

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
