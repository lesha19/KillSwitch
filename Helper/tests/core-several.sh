#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Several subscriptions (ADR 0036, #64): "ks core import <active> <other>…" approves the profiles of
# all of them with one password; "ks core use <file>" activates an approved one without it. Against
# a temp directory: pfctl, launchctl and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-several.sh   (MIHOMO=/path/to/mihomo, else a stub that accepts everything)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp -R "$here/fixtures" "$tmp/fixtures"; fx="$tmp/fixtures"
DIR="$tmp"; CORE_DIR="$tmp/core"; mkdir -p "$CORE_DIR/ctl"
SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; EVENTS="$DIR/events.log"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; SERVERS_CORE="$DIR/servers-core"
CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; APPROVED_DIRECT="$CORE_DIR/approved-direct"
APPROVED_SWITCH="$CORE_DIR/approved-switch"; APPROVED_SET="$CORE_DIR/approved"
CORE_EGRESS="$CORE_DIR/egress"; REPORT="$CORE_DIR/routing.json"
if [ -x "$MIHOMO" ]; then ln -s "$MIHOMO" "$CORE_DIR/mihomo"
else printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/mihomo"; chmod 755 "$CORE_DIR/mihomo"; echo "skip  mihomo -t (stub)"; fi
install() { :; }
pfctl() { cat >/dev/null; }
dscl() { return 0; }
vpn_ifaces() { :; }; ts_ifaces() { :; }
loaded() { return 1; }
launchctl() { return 0; }
core_reload() { :; }
: > "$SERVERS_MANUAL"
DNSF="$tmp/dns"
dns() { { grep -v "^$1 " "$DNSF" 2>/dev/null; echo "$1 $2"; } > "$DNSF.new"; mv "$DNSF.new" "$DNSF"; }
dns de.example.com 203.0.113.20; dns fi.example.com 203.0.113.30; dns nl.example.com 203.0.113.60; dns x.example.com 203.0.113.70
resolve_all() { awk -v h="$1" '$1 == h { for (i = 2; i <= NF; i++) print $i }' "$DNSF"; }
resolve_host() { resolve_all "$1" | head -1; }
resolve_direct() { :; }

fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
run() { rc=0; core_import "$@" 2>"$tmp/err" || rc=$?; }
edit() {
  /usr/bin/perl -MJSON::PP -e 'local $/; my $j = JSON::PP->new->decode(<STDIN>); eval $ARGV[0]; die $@ if $@; print JSON::PP->new->encode($j)' "$1"
}
cfg="$CORE_DIR/config.yaml"
A="$fx/ok-full.json"   # de, fi and a literal address; sends .ru DIRECT
B="$tmp/b.json"        # another subscription: nl only, .ru not DIRECT
edit '$_->{server} = "nl.example.com" for @{$j->{proxies}}; splice @{$j->{rules}}, 2, 1' < "$A" > "$B"
C="$tmp/c.json"; edit 'push @{$j->{proxies}}, {name=>"X", type=>"trojan", server=>"x.example.com", port=>443, password=>"p"}' < "$B" > "$C"
D="$tmp/d.json"; edit 'unshift @{$j->{rules}}, "DOMAIN-SUFFIX,com,DIRECT"' < "$B" > "$D"
BA="$tmp/ba.json"; edit '$_->{server} = "nl.example.com" for @{$j->{proxies}}' < "$A" > "$BA"   # B's servers, A's DIRECT
AB="$tmp/ab.json"; edit 'splice @{$j->{rules}}, 2, 1' < "$A" > "$AB"                              # A's servers, B's DIRECT
AN="$tmp/an.json"; edit 'push @{$j->{proxies}}, {name=>"NL2", type=>"trojan", server=>"nl.example.com", port=>443, password=>"p"}' < "$A" > "$AN"
running() { grep -q "$1" "$cfg"; }

# --- one import approves both, runs the first
run "$A" import "$B"
[ "$rc" = 0 ] && ok "import of two profiles" || bad "import of two: $rc $(cat "$tmp/err")"
[ "$(paste -sd' ' "$APPROVED_HOSTS")" = "de.example.com fi.example.com" ] && ok "  approved hosts: the running one's (refresh measures against it)" ||
  bad "  approved hosts: $(paste -sd' ' "$APPROVED_HOSTS" 2>/dev/null)"
running 203.0.113.20 && ! running 203.0.113.60 && ok "  the first one runs" || bad "  running config is not the first profile's"
grep -q 'DOMAIN-SUFFIX,ru,DIRECT' "$APPROVED_DIRECT" && ok "  approved DIRECT: the running one's" || bad "  approved direct: $(cat "$APPROVED_DIRECT")"
[ "$(find "$APPROVED_SET" -name kind 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && [ "$(cat "$APPROVED_SET"/*/kind | sort -u)" = mihomo ] &&
  ok "  one approved entry per profile, with its core kind" || bad "  approved set: $(find "$APPROVED_SET" 2>&1 | paste -sd' ' -)"
[ "$(find "$APPROVED_SET" -type f ! -perm 600 | wc -l | tr -d ' ')" = 0 ] && [ "$(stat -f %Lp "$APPROVED_SET")" = 700 ] &&
  ok "  root-only" || bad "  modes: $(find "$APPROVED_SET" -exec stat -f '%N %Lp' {} +)"
[ -n "$(find "$CORE_DIR" -name '*.tmp' -o -name '*.new' -o -name '*.egress' -o -name '*.report')" ] && bad "  temp files left: $(ls "$CORE_DIR")" || ok "  no temp files left"

# --- use: an approved one without the password
run "$B" use
[ "$rc" = 0 ] && running 203.0.113.60 && ! running 203.0.113.20 && ok "use: the other approved subscription runs" || bad "use B: $rc $(cat "$tmp/err")"
! grep -q 'DOMAIN-SUFFIX,ru,DIRECT' "$APPROVED_DIRECT" && ok "  approved DIRECT is now its own (refresh measures against it)" || bad "  approved direct still A's"
[ "$(paste -sd' ' "$APPROVED_HOSTS")" = "nl.example.com" ] && [ "$(find "$APPROVED_SET" -name kind | wc -l | tr -d ' ')" = 2 ] &&
  ok "  approved hosts now its own, the set kept" || bad "  approved hosts: $(paste -sd' ' "$APPROVED_HOSTS")"
run "$B" refresh
[ "$rc" = 0 ] && ok "refresh of the active profile after use" || bad "refresh B: $rc $(cat "$tmp/err")"
# one entry approves all of a profile: hosts of one with the DIRECT of another is neither (review B1)
cp "$cfg" "$tmp/cfg.b"
run "$BA" use
[ "$rc" = 3 ] && grep -qF '(DIRECT)' "$tmp/err" && cmp -s "$cfg" "$tmp/cfg.b" && ok "use: B's servers with A's DIRECT refused (3)" || bad "use BA: $rc $(cat "$tmp/err")"
run "$AB" use
[ "$rc" = 3 ] && cmp -s "$cfg" "$tmp/cfg.b" && ok "use: A's servers with B's DIRECT refused (3)" || bad "use AB: $rc $(cat "$tmp/err")"
run "$A" use
[ "$rc" = 0 ] && running 203.0.113.20 && ok "use: back to the first one" || bad "use A: $rc $(cat "$tmp/err")"
cp "$cfg" "$tmp/cfg.a"
run "$BA" use
[ "$rc" = 3 ] && cmp -s "$cfg" "$tmp/cfg.a" && ok "use: B's servers with the running A's DIRECT refused (3)" || bad "use BA from A: $rc $(cat "$tmp/err")"
run "$AB" use
[ "$rc" = 3 ] && cmp -s "$cfg" "$tmp/cfg.a" && ok "use: A's servers with B's DIRECT refused while A runs (3)" || bad "use AB from A: $rc $(cat "$tmp/err")"
run "$AN" refresh
[ "$rc" = 3 ] && grep -q nl.example.com "$tmp/err" && cmp -s "$cfg" "$tmp/cfg.a" && ok "refresh: a host of another subscription refused (3)" || bad "refresh AN: $rc $(cat "$tmp/err")"
run "$C" use
[ "$rc" = 3 ] && grep -q 'x.example.com' "$tmp/err" && grep -q 'нужно подтверждение паролем администратора' "$tmp/err" &&
  cmp -s "$cfg" "$tmp/cfg.a" && ok "use: a host outside the set refused (3), config untouched" || bad "use C: $rc $(cat "$tmp/err")"
run "$D" use
[ "$rc" = 3 ] && grep -qF '(DIRECT)' "$tmp/err" && cmp -s "$cfg" "$tmp/cfg.a" && ok "use: DIRECT outside the set refused (3)" || bad "use D: $rc $(cat "$tmp/err")"
run "$A" use "$B"
[ "$rc" = 1 ] && ok "use takes one profile" || bad "use with two: $rc"
for k in "$APPROVED_SET"/*/kind; do echo xray > "$k"; done
run "$B" use
[ "$rc" = 3 ] && cmp -s "$cfg" "$tmp/cfg.a" && ok "use: approved for the other core only: refused (#65)" || bad "use other kind: $rc $(cat "$tmp/err")"
for k in "$APPROVED_SET"/*/kind; do echo mihomo > "$k"; done

# --- a bad later profile stays unapproved, the others are not affected (ADR 0036, decision 7)
: > "$EVENTS"
run "$A" import "$fx/bad-no-proxies.json" "$B" "$tmp/no-such.json"
[ "$rc" = 0 ] && running 203.0.113.20 && [ "$(find "$APPROVED_SET" -name kind | wc -l | tr -d ' ')" = 2 ] && [ -d "$APPROVED_SET/3" ] &&
  ok "import: bad and unreadable later profiles skipped, the rest approved" || bad "bad later: $rc $(cat "$tmp/err") $(find "$APPROVED_SET" | paste -sd' ' -)"
[ "$(grep -c 'approval: profile [24] of the import skipped' "$EVENTS")" = 2 ] && ok "  the journal says which and why" || bad "  journal: $(cat "$EVENTS")"
! grep -q 'example\.com\|203\.0\.113\|no-such' "$EVENTS" && ok "  without host names, addresses or paths" || bad "  journal names: $(grep 'example\|203\.0\|no-such' "$EVENTS")"
grep -q 'approval: 2 profiles approved: 1 hosts=2 direct=[0-9a-f]\{12\} 3 hosts=1 direct=[0-9a-f]\{12\}$' "$EVENTS" &&
  ok "  the journal lists the approved set: per profile hosts and DIRECT hash" || bad "  journal set: $(grep 'profiles approved' "$EVENTS")"
[ -z "$(find "$CORE_DIR" -name 'approve-*' -o -name 'approve.*')" ] && ok "  no temp files left" || bad "  left: $(find "$CORE_DIR" -name 'approve-*' -o -name 'approve.*')"
run "$B" use
[ "$rc" = 0 ] && ok "  use of the good one" || bad "  use B: $rc $(cat "$tmp/err")"
run "$A" use

# --- single-file import: a set of one
run "$A" import
[ "$rc" = 0 ] && [ "$(find "$APPROVED_SET" -name kind | wc -l | tr -d ' ')" = 1 ] && [ "$(paste -sd' ' "$APPROVED_HOSTS")" = "de.example.com fi.example.com" ] &&
  ok "single import: a set of one" || bad "single import: $rc $(find "$APPROVED_SET" 2>&1 | paste -sd' ' -)"
run "$B" use
[ "$rc" = 3 ] && ok "  the other subscription is no longer approved" || bad "  use B after a single import: $rc"

# --- approval of an install from before 0.20: no set, the files of one import
rm -rf "$APPROVED_SET"
run "$A" use
[ "$rc" = 0 ] && ok "old approval files: valid as a set of one" || bad "old files, use A: $rc $(cat "$tmp/err")"
run "$B" use
[ "$rc" = 3 ] && ok "  and only for that profile" || bad "old files, use B: $rc"

# --- Xray: the same, each entry with every host's DIRECT (KS-10); a profile for the other core refused
printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/xray"; chmod 755 "$CORE_DIR/xray"; echo core=xray > "$SETTINGS"
xray_observe() { return 1; }
P="$fx/xray-panel.json"; Q="$fx/xray-3xui.json"
run "$P" import "$Q"
[ "$rc" = 0 ] && [ "$(cat "$APPROVED_SET"/*/kind | sort -u)" = xray ] && ok "xray: import of two, entries of kind xray" || bad "xray import: $rc $(cat "$tmp/err")"
run "$Q" use
[ "$rc" = 0 ] && grep -q 203.0.113.30 "$CORE_DIR/xray.json" && ok "xray: use of the other one" || bad "xray use Q: $rc $(cat "$tmp/err")"
run "$P" use
[ "$rc" = 0 ] && grep -q 203.0.113.10 "$CORE_DIR/xray.json" && ok "xray: and back" || bad "xray use P: $rc $(cat "$tmp/err")"
cp "$CORE_DIR/xray.json" "$tmp/xray.p"
# a refused use leaves the settings as they were: double VPN is turned off only by one that runs (review 3)
sed 's/203\.0\.113\.30/203.0.113.99/' "$Q" > "$tmp/q2.json"
printf 'core=xray\nmultihop=Нет такого\n' > "$SETTINGS"; cp "$SETTINGS" "$tmp/settings.before"
run "$tmp/q2.json" use
[ "$rc" = 3 ] && cmp -s "$SETTINGS" "$tmp/settings.before" && cmp -s "$CORE_DIR/xray.json" "$tmp/xray.p" &&
  ok "xray: a refused use leaves the settings byte for byte" || bad "xray refused use: $rc $(cat "$SETTINGS") $(cat "$tmp/err")"
run "$Q" use
[ "$rc" = 0 ] && [ "$(setting multihop off)" = off ] && ok "xray: a use that runs turns the gone double VPN off" || bad "xray use with multihop: $rc $(cat "$SETTINGS") $(cat "$tmp/err")"
run "$P" use
run "$B" use
[ "$rc" != 0 ] && cmp -s "$CORE_DIR/xray.json" "$tmp/xray.p" && ok "xray: a mihomo profile refused, config untouched" || bad "xray use of a mihomo profile: $rc"
rm -f "$SETTINGS"

# --- blocking holds through use (ADR 0035): the anchor is never flushed, the core restarts under it
run "$A" import "$B"
: > "$tmp/anchor.calls"; echo 'block drop out quick all' > "$tmp/anchor"
loaded() { return 0; }
pfctl() {
  echo "pfctl $*" >> "$tmp/anchor.calls"
  case "$*" in
    "-a $ANCHOR -f -") cat > "$tmp/anchor.new"; mv "$tmp/anchor.new" "$tmp/anchor" ;;   # pf swaps the ruleset whole
    "-a $ANCHOR -F rules") : > "$tmp/anchor" ;;
    *) cat >/dev/null ;;
  esac
}
launchctl() { echo "launchctl $* anchor=$([ -s "$tmp/anchor" ] && echo rules || echo empty)" >> "$tmp/anchor.calls"; return 0; }
load() { rules "$ALLOW" "$SERVERS" | pfctl -a "$ANCHOR" -f -; }
rc=0; core_take "$B" use 2>"$tmp/err" || rc=$?
[ "$rc" = 0 ] && running 203.0.113.60 && ok "use with the kill switch on" || bad "use with pf: $rc $(cat "$tmp/err")"
grep -q 'launchctl kickstart' "$tmp/anchor.calls" && ! grep -q 'anchor=empty' "$tmp/anchor.calls" && ! grep -q -- '-F' "$tmp/anchor.calls" &&
  paste -sd"|" "$tmp/anchor.calls" | grep -q -- "-f -|.*launchctl kickstart" && ok "  pf anchor loaded throughout, reloaded before the core restarts" || bad "  pf: $(paste -sd'|' "$tmp/anchor.calls")"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
