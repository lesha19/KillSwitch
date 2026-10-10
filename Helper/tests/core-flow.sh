#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# "ks core import/refresh", server address rotation and the settings that rebuild the config,
# against a temp directory: pfctl, launchctl and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-flow.sh   (MIHOMO=/path/to/mihomo, else a stub that accepts everything)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; CORE_DIR="$tmp/core"; mkdir -p "$CORE_DIR/ctl"
SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; EVENTS="$DIR/events.log"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; SERVERS_CORE="$DIR/servers-core"
CORE_CTL="$CORE_DIR/ctl/mihomo.sock"
CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; APPROVED_DIRECT="$CORE_DIR/approved-direct"
if [ -x "$MIHOMO" ]; then ln -s "$MIHOMO" "$CORE_DIR/mihomo"
else printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/mihomo"; chmod 755 "$CORE_DIR/mihomo"; echo "skip  mihomo -t (stub)"; fi
install() { :; }                 # core_import creates ctl/ as root
pfctl() { cat >/dev/null; }
dscl() { return 0; }
vpn_ifaces() { :; }; ts_ifaces() { :; }
loaded() { return 1; }           # kill switch off: nothing to reload
launchctl() { echo "launchctl $*" >> "$tmp/launchd"; return 0; }
core_reload() { echo reload >> "$tmp/reloads"; }
: > "$SERVERS_MANUAL"
# DNS: name -> answers, editable per test; resolve_host (import) takes the first
DNSF="$tmp/dns"   # core_import has a local $tmp
dns() { { grep -v "^$1 " "$DNSF" 2>/dev/null; echo "$1 $2"; } > "$DNSF.new"; mv "$DNSF.new" "$DNSF"; }
dns de.example.com 203.0.113.20; dns fi.example.com 203.0.113.30; dns nl.example.com 203.0.113.60
resolve_all() { awk -v h="$1" '$1 == h { for (i = 2; i <= NF; i++) print $i }' "$DNSF"; }
resolve_host() { resolve_all "$1" | head -1; }
# DoH straight from the primary interface as _ksvpn: separate answers, every call recorded
DIRECTF="$tmp/dns-direct"; : > "$DIRECTF"
resolve_direct() { echo "$1" >> "$tmp/direct-asked"; awk -v h="$1" '$1 == h { for (i = 2; i <= NF; i++) print $i }' "$DIRECTF"; }

fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
val() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
run() { rc=0; core_import "$@" 2>"$tmp/err" || rc=$?; }
edit() {  # edit <perl> < profile > out: change a profile
  /usr/bin/perl -MJSON::PP -e 'local $/; my $j = JSON::PP->new->decode(<STDIN>); eval $ARGV[0]; die $@ if $@; print JSON::PP->new->encode($j)' "$1"
}
cfg="$CORE_DIR/config.yaml"

# --- import records what was approved
run "$fx/ok-full.json" import
[ "$rc" = 0 ] && ok "import" || bad "import: $rc $(cat "$tmp/err")"
[ "$(paste -sd' ' "$APPROVED_HOSTS")" = "de.example.com fi.example.com" ] && ok "import: approved host names recorded" ||
  bad "approved hosts: $(cat "$APPROVED_HOSTS" 2>/dev/null)"
[ -s "$APPROVED_DIRECT" ] && grep -q '^rule	DOMAIN-SUFFIX,ru,DIRECT$' "$APPROVED_DIRECT" && ok "import: DIRECT rules recorded" || bad "approved direct"
[ -s "$CORE_PROFILE" ] && [ -s "$PINS" ] && ok "import: profile and pins kept" || bad "profile/pins"
[ "$(stat -f %Lp "$CORE_PROFILE" "$PINS" "$APPROVED_HOSTS" "$APPROVED_DIRECT" | sort -u)" = 600 ] && ok "import: state files root-only (600)" ||
  bad "modes: $(stat -f '%N %Lp' "$CORE_PROFILE" "$PINS" "$APPROVED_HOSTS" "$APPROVED_DIRECT")"
[ -n "$(find "$CORE_DIR" -name '*.tmp' -o -name '*.new')" ] && bad "import left temp files: $(ls "$CORE_DIR")" || ok "import: no temp files left"

# --- refresh: same names with new addresses are fine
dns de.example.com "198.51.100.20"
run "$fx/ok-full.json" refresh
[ "$rc" = 0 ] && grep -qx 198.51.100.20 "$SERVERS_CORE" && [ "$(val proxies.1.server "$cfg")" = 198.51.100.20 ] &&
  ok "refresh: approved name on a new address accepted" || bad "refresh new address: $rc $(cat "$tmp/err")"
grep -qx 203.0.113.20 "$SERVERS" && bad "refresh: old address still allowed" || ok "refresh: old address dropped from pf"
cp "$cfg" "$tmp/cfg.before"
# a new host name
edit 'push @{$j->{proxies}}, {name=>"NL", type=>"trojan", server=>"nl.example.com", port=>443, password=>"p"}' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && grep -q 'нужно подтверждение' "$tmp/err" && grep -q nl.example.com "$tmp/err" && ok "refresh: new host name refused (3)" ||
  bad "refresh new name: $rc $(cat "$tmp/err")"
cmp -s "$cfg" "$tmp/cfg.before" && ok "refresh refused: config untouched" || bad "config changed by a refused refresh"
# a new host name that resolves to an address already allowed is still a new name
dns nl.example.com "203.0.113.10"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: new name on a known address refused" || bad "new name on known address: $rc"
# a new literal address
edit 'push @{$j->{proxies}}, {name=>"X", type=>"trojan", server=>"192.0.2.99", port=>443, password=>"p"}' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && grep -q 192.0.2.99 "$tmp/err" && ok "refresh: new literal address refused" || bad "new literal: $rc $(cat "$tmp/err")"
# DIRECT changes
edit 'unshift @{$j->{rules}}, "DOMAIN-SUFFIX,com,DIRECT"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && grep -q 'нужно подтверждение' "$tmp/err" && ok "refresh: new DIRECT rule refused" || bad "DIRECT rule: $rc $(cat "$tmp/err")"
edit '$j->{rules}[-1] = "MATCH,DIRECT"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: MATCH,DIRECT refused" || bad "MATCH,DIRECT: $rc"
edit 'push @{$j->{"proxy-groups"}[2]{proxies}}, "DIRECT"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: DIRECT added to a group refused" || bad "group DIRECT: $rc"
edit '$j->{"rule-providers"}{"local-inline"}{payload} = ["+.example.net", "+.com"]' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: wider payload of a DIRECT rule's provider refused" || bad "provider payload: $rc"
edit '$j->{"rule-providers"}{"ru-blocked"}{proxy} = "DIRECT"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: provider downloaded with proxy DIRECT refused" || bad "provider proxy: $rc"
edit '$j->{rules}[-1] = "MATCH,GLOBAL"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: MATCH,GLOBAL refused" || bad "GLOBAL: $rc"
edit 'pop @{$j->{rules}}; push @{$j->{rules}}, "DOMAIN,a.org,auto", "MATCH,🚀 Выбор сервера"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" refresh
[ "$rc" = 0 ] && ok "refresh: a new proxy-only rule is fine" || bad "proxy-only rule: $rc $(cat "$tmp/err")"
# the admin import may change DIRECT; refresh then compares with that
edit 'unshift @{$j->{rules}}, "DOMAIN-SUFFIX,com,DIRECT"' < "$fx/ok-full.json" > "$tmp/p.json"
run "$tmp/p.json" import
[ "$rc" = 0 ] && grep -q 'DOMAIN-SUFFIX,com,DIRECT' "$APPROVED_DIRECT" && ok "import: new DIRECT rule approved" || bad "import DIRECT: $rc"
run "$tmp/p.json" refresh
[ "$rc" = 0 ] && ok "refresh: identical DIRECT rules accepted" || bad "refresh after import: $rc $(cat "$tmp/err")"
# installs from before 0.7 have no record: anything DIRECT needs one import
mv "$APPROVED_DIRECT" "$tmp/ad"
run "$tmp/p.json" refresh
[ "$rc" = 3 ] && ok "refresh: DIRECT without a record refused" || bad "no record: $rc"
run "$fx/ok-minimal.json" refresh
[ "$rc" = 3 ] && grep -q 198.51.100.7 "$tmp/err" && ok "refresh: legacy install, new address still refused" || bad "legacy addr: $rc"
mv "$tmp/ad" "$APPROVED_DIRECT"

# --- rotation
run "$fx/ok-full.json" import
: > "$tmp/reloads"; : > "$EVENTS"
dns de.example.com "198.51.100.21"
core_rotate
[ "$(val proxies.1.server "$cfg")" = 198.51.100.21 ] && [ "$(val proxies.1.sni "$cfg")" = de.example.com ] &&
  grep -qx 198.51.100.21 "$SERVERS_CORE" && grep -qx 198.51.100.21 "$SERVERS" && ! grep -qx 198.51.100.20 "$SERVERS" &&
  grep -q '"198.51.100.21/32"' "$cfg" && ok "rotate: config, servers-core, servers and TUN excludes follow the name" ||
  bad "rotate: $(val proxies.1.server "$cfg") / $(paste -sd' ' "$SERVERS_CORE")"
grep -q 'de.example.com 198.51.100.20 -> 198.51.100.21' "$EVENTS" && ok "rotate: logged" || bad "rotate log: $(cat "$EVENTS")"
[ -s "$tmp/reloads" ] && ok "rotate: core reloaded" || bad "rotate: no reload"
: > "$tmp/reloads"; cp "$cfg" "$tmp/cfg.before"
dns de.example.com "198.51.100.99 198.51.100.21"
core_rotate
cmp -s "$cfg" "$tmp/cfg.before" && [ ! -s "$tmp/reloads" ] && ok "rotate: pinned address still among the answers, nothing changes" ||
  bad "rotate: round-robin caused a change"
dns de.example.com ""
core_rotate
cmp -s "$cfg" "$tmp/cfg.before" && grep -q 'not resolved.*de.example.com' "$EVENTS" && ok "rotate: unresolved name keeps its address, logged" ||
  bad "rotate unresolved: $(tail -1 "$EVENTS")"
[ ! -e "$tmp/direct-asked" ] && ok "rotate: no direct DoH while the tunnel still resolves a name" || bad "direct DoH asked: $(cat "$tmp/direct-asked")"
# every server moved: the tunnel resolves nothing, direct DoH (pf: _ksvpn to 1.1.1.1/8.8.8.8:443) recovers
dns de.example.com ""; dns fi.example.com ""
printf 'de.example.com 198.51.100.40\nfi.example.com 198.51.100.41\n' > "$DIRECTF"
: > "$tmp/reloads"; : > "$EVENTS"
core_rotate
[ "$(val proxies.1.server "$cfg")" = 198.51.100.40 ] && grep -qx 198.51.100.41 "$SERVERS_CORE" && [ -s "$tmp/reloads" ] &&
  ok "rotate: nothing resolves through the tunnel, direct DoH re-pins" || bad "rotate direct: $(paste -sd' ' "$SERVERS_CORE")"
grep -q 'direct DoH' "$EVENTS" && ok "rotate: direct DoH use logged" || bad "direct DoH not logged: $(cat "$EVENTS")"
rm -f "$tmp/direct-asked"; : > "$DIRECTF"; cp "$cfg" "$tmp/cfg.before"
core_rotate
cmp -s "$cfg" "$tmp/cfg.before" && ok "rotate: direct DoH fails too, addresses kept" || bad "rotate: changed without answers"
dns de.example.com "198.51.100.40"; dns fi.example.com "198.51.100.41"; rm -f "$tmp/direct-asked"
mv "$APPROVED_HOSTS" "$tmp/ah"
dns de.example.com "198.51.100.50"
core_rotate
cmp -s "$cfg" "$tmp/cfg.before" && ok "rotate: no approved names, nothing done" || bad "rotate without approval changed the config"
mv "$tmp/ah" "$APPROVED_HOSTS"

# --- settings that rebuild the config from the kept profile (no DNS)
: > "$tmp/dns"
echo coredirect=1 > "$SETTINGS"
set_splitapps "Telegram, Safari" 2>"$tmp/err" && [ "$(val rules.0 "$cfg")" = "PROCESS-NAME,Telegram,DIRECT" ] &&
  grep -qx "splitapps=Telegram,Safari" "$SETTINGS" && ok "splitapps: stored and applied" || bad "splitapps: $(cat "$tmp/err")"
set_splitapps "" && [ -z "$(setting splitapps "")" ] && [ "$(val rules.0 "$cfg")" != "PROCESS-NAME,Telegram,DIRECT" ] && ok "splitapps: cleared" || bad "splitapps clear"
echo coredirect=0 > "$SETTINGS"
set_splitapps "Telegram" 2>"$tmp/err" && bad "splitapps without coredirect accepted" ||
  { grep -q coredirect "$tmp/err" && ok "splitapps without coredirect refused: $(cat "$tmp/err")" || bad "message: $(cat "$tmp/err")"; }
set_splitapps "a,,b" 2>/dev/null && bad "bad list accepted" || ok "bad splitapps list refused"
set_multihop "NL reality" 2>"$tmp/err" && [ "$(setting multihop off)" = "NL reality" ] && [ "$(cat "$SERVERS_CORE")" = 203.0.113.10 ] &&
  [ "$(val proxies.2.dialer-proxy "$cfg")" = "NL reality" ] && ok "multihop: stored, applied, only the entry in servers-core" ||
  bad "multihop: $(cat "$tmp/err")"
cp "$cfg" "$tmp/cfg.before"
set_multihop "nope" 2>"$tmp/err" && bad "multihop to a missing proxy accepted" ||
  { [ "$(setting multihop off)" = "NL reality" ] && cmp -s "$cfg" "$tmp/cfg.before" && ok "multihop: missing entry refused, old one kept" || bad "multihop refusal"; }
set_multihop "$(printf 'a\nb')" 2>/dev/null && bad "multihop: control char accepted" || ok "multihop: control char refused"
set_multihop off && grep -qx multihop=off "$SETTINGS" && ! plutil -type proxies.2.dialer-proxy "$cfg" >/dev/null 2>&1 &&
  [ "$(wc -l < "$SERVERS_CORE" | tr -d ' ')" = 3 ] && ok "multihop off: every server back" || bad "multihop off"

# --- when to check for rotation
ROT_NEXT=""; ROT_LAST=0; NET_SIG=""
rotate_due 1000 "en0 192.168.1.1" && bad "due at start" || ok "not due right after start"
rotate_due 1059 "en0 192.168.1.1" && bad "due before a minute" || ok "first check a minute after start"
rotate_due 1061 "en0 192.168.1.1" && ok "due after a minute" || bad "not due after a minute"
rotate_due 1100 "en0 192.168.1.1" && bad "due again at once" || ok "then not again"
rotate_due 1110 "en1 10.0.0.1" && bad "due the moment the network changes" || ok "network change: waits to settle"
rotate_due 1126 "en1 10.0.0.1" && ok "network change: checked 15 s later" || bad "network change not checked"
rotate_due 1130 "en0 192.168.1.1" && bad "flapping" || ok "second change"
rotate_due 1186 "en0 192.168.1.1" && ok "second change: checked, at most once a minute" || bad "second change not checked"
rotate_due 2900 "en0 192.168.1.1" && bad "due before 30 min" || ok "quiet network: not before 30 min"
rotate_due 2987 "en0 192.168.1.1" && ok "quiet network: every 30 min" || bad "30 min"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
