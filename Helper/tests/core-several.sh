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
# a use is another subscription: «Двойной VPN» goes off, though B has a server of the entry's name (#74)
printf 'multihop=FI ws\n' >> "$SETTINGS"
run "$B" use
[ "$rc" = 0 ] && [ "$(setting multihop off)" = off ] && ok "use: double VPN of the subscription before turned off" || bad "use with multihop: $rc $(cat "$SETTINGS") $(cat "$tmp/err")"
run "$A" use
# a password import that switches subscription (the app marks the profile "x-ks-switch", #74):
# double VPN goes off in that run, the mark is not kept; an import without it keeps double VPN
put_setting multihop "FI ws"
run "$A" import "$B"
[ "$rc" = 0 ] && [ "$(setting multihop off)" = "FI ws" ] && ok "import: double VPN kept" || bad "import with multihop: $rc $(cat "$tmp/err")"
BS="$tmp/bs.json"; edit '$j->{"x-ks-switch"} = JSON::PP::true' < "$B" > "$BS"
: > "$EVENTS"
run "$BS" import "$A"
[ "$rc" = 0 ] && running 203.0.113.60 && [ "$(setting multihop off)" = off ] && ! grep -rq x-ks-switch "$CORE_DIR" && grep -qx '.*double VPN: off' "$EVENTS" &&
  ok "import switching subscription: double VPN off, the mark not kept" || bad "switching import: $rc $(setting multihop off) $(cat "$tmp/err")"
run "$A" import "$B"

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
QS="$tmp/qs.json"; edit '$j->[0]{"x-ks-switch"} = JSON::PP::true' < "$Q" > "$QS"
put_setting multihop "Нет такого"
run "$QS" import "$P"
[ "$rc" = 0 ] && grep -q 203.0.113.30 "$CORE_DIR/xray.json" && [ "$(setting multihop off)" = off ] && ! grep -rq x-ks-switch "$CORE_DIR" &&
  ok "xray: import switching subscription: double VPN off, the mark not kept" || bad "xray switching import: $rc $(cat "$tmp/err")"
run "$P" import "$Q"; cp "$CORE_DIR/xray.json" "$tmp/xray.p"
run "$B" use
[ "$rc" != 0 ] && cmp -s "$CORE_DIR/xray.json" "$tmp/xray.p" && ok "xray: a mihomo profile refused, config untouched" || bad "xray use of a mihomo profile: $rc"
rm -f "$SETTINGS"

# --- the core follows the subscription (#65): each profile approved and run in its own core's
# format, the kind read from the profile; a use of the other kind switches the core. Q4: Q on an
# address no mihomo entry has
Q4="$tmp/q4.json"; sed 's/203\.0\.113\.30/203.0.113.40/' "$Q" > "$Q4"
run "$A" import "$Q4"
[ "$rc" = 0 ] && [ "$(cat "$APPROVED_SET/1/kind")" = mihomo ] && [ "$(cat "$APPROVED_SET/2/kind")" = xray ] && [ "$(core_kind)" = mihomo ] &&
  ok "mixed import: each entry of its own profile's kind" || bad "mixed import: $rc $(cat "$APPROVED_SET"/*/kind 2>/dev/null | paste -sd' ' -) $(cat "$tmp/err")"
cp "$cfg" "$tmp/cfg.a"
run "$Q4" use
[ "$rc" = 0 ] && [ "$(core_kind)" = xray ] && grep -q 203.0.113.40 "$CORE_DIR/xray.json" && grep -q 203.0.113.40 "$SERVERS" && ! grep -q 203.0.113.20 "$SERVERS" &&
  ok "use of the other kind: the core is switched, the servers are its own" || bad "use Q4 from mihomo: $rc $(core_kind) $(cat "$tmp/err")"
cmp -s "$cfg" "$tmp/cfg.a" && cmp -s "$APPROVED_DIRECT" "$APPROVED_SET/2/direct" && ok "  the other core's config kept, approval now the entry's" || bad "  config.yaml or approved-direct"
run "$A" use
[ "$rc" = 0 ] && [ "$(core_kind)" = mihomo ] && running 203.0.113.20 && ok "  and back to mihomo" || bad "use A from xray: $rc $(core_kind) $(cat "$tmp/err")"
edit 'push @{$j->{proxies}}, {name=>"Q", type=>"trojan", server=>"203.0.113.40", port=>443, password=>"p"}' < "$A" > "$tmp/aq.json"
sed 's/203\.0\.113\.40/203.0.113.20/' "$Q4" > "$tmp/qa.json"
run "$tmp/aq.json" use
[ "$rc" = 3 ] && [ "$(core_kind)" = mihomo ] && ok "use: a mihomo profile with a server approved only for Xray refused (3)" || bad "use AQ: $rc $(core_kind)"
run "$tmp/qa.json" use
[ "$rc" = 3 ] && [ "$(core_kind)" = mihomo ] && running 203.0.113.20 && ok "use: an Xray profile with a server approved only for mihomo refused (3)" || bad "use Q4A: $rc $(core_kind)"
run "$Q4" refresh
[ "$rc" = 3 ] && [ "$(core_kind)" = mihomo ] && ok "refresh: a profile of the other kind needs the password (3)" || bad "refresh Q4 from mihomo: $rc $(core_kind)"
printf 'multihop=DE trojan\n' > "$SETTINGS"
run "$Q4" import "$A"
[ "$rc" = 0 ] && [ "$(core_kind)" = xray ] && [ "$(setting multihop off)" = off ] && [ "$(cat "$APPROVED_SET/1/kind")" = xray ] && [ "$(cat "$APPROVED_SET/2/kind")" = mihomo ] &&
  ok "import whose running profile is of the other kind: the core follows it, double VPN off" || bad "import Q4 A from mihomo: $rc $(core_kind) $(cat "$SETTINGS") $(cat "$tmp/err")"
mv "$CORE_DIR/xray" "$tmp/xray.bin"; rm -f "$SETTINGS"; run "$A" use
run "$Q4" use
[ "$rc" = 1 ] && [ "$(core_kind)" = mihomo ] && grep -q 'Ядро xray не установлено' "$tmp/err" && ok "use: the other core not installed: refused, nothing changed" || bad "use Q4 without xray: $rc $(cat "$tmp/err")"
mv "$tmp/xray.bin" "$CORE_DIR/xray"
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

# --- a switch of the core under blocking (ADR 0035, #65): the other core's launchd job replaces the
# running one with the anchor loaded throughout; when the new core does not run, the old one is
# back with its servers, approval and settings
rm -f "$SETTINGS"; run "$A" import "$Q4"
CORE_PLIST="$tmp/core.plist"; echo mihomo > "$CORE_DIR/plist.mihomo"; echo xray > "$CORE_DIR/plist.xray"; cp "$CORE_DIR/plist.mihomo" "$CORE_PLIST"
VPN_PASS=1
watchdog_handover() { :; }; core_log_tidy() { :; }; diag_dir() { :; }; dns_locked() { :; }; xray_api_check() { return 1; }
job_gone() { :; }; sleep() { :; }
core_running() { [ ! -e "$tmp/new-fails" ] || cmp -s "$CORE_PLIST" "$CORE_DIR/plist.mihomo"; }
launchctl() { echo "launchctl $* anchor=$([ -s "$tmp/anchor" ] && echo rules || echo empty) plist=$(cat "$CORE_PLIST")" >> "$tmp/anchor.calls"; return 0; }
: > "$tmp/anchor.calls"
rc=0; core_take "$Q4" use 2>"$tmp/err" || rc=$?
[ "$rc" = 0 ] && [ "$(core_kind)" = xray ] && cmp -s "$CORE_PLIST" "$CORE_DIR/plist.xray" && grep -q 'launchctl bootstrap .* plist=xray' "$tmp/anchor.calls" &&
  ok "use of the other kind with the VPN on: Xray's job runs" || bad "switch to xray: $rc $(core_kind) $(paste -sd'|' "$tmp/anchor.calls") $(cat "$tmp/err")"
! grep -q 'anchor=empty' "$tmp/anchor.calls" && ! grep -q -- '-F' "$tmp/anchor.calls" && ok "  pf anchor loaded throughout the switch" || bad "  pf: $(paste -sd'|' "$tmp/anchor.calls")"
rc=0; core_take "$A" use 2>"$tmp/err" || rc=$?
[ "$rc" = 0 ] && [ "$(core_kind)" = mihomo ] && cmp -s "$CORE_PLIST" "$CORE_DIR/plist.mihomo" && ok "  and back to mihomo's job" || bad "switch back: $rc $(core_kind) $(cat "$tmp/err")"
cp "$SERVERS" "$tmp/servers.a"; cp "$APPROVED_DIRECT" "$tmp/direct.a"
touch "$tmp/new-fails"; : > "$tmp/anchor.calls"
rc=0; core_take "$Q4" use 2>"$tmp/err" || rc=$?
[ "$rc" != 0 ] && [ "$(core_kind)" = mihomo ] && cmp -s "$CORE_PLIST" "$CORE_DIR/plist.mihomo" && core_running &&
  ok "the other core does not start: mihomo runs again" || bad "failed switch: $rc $(core_kind) $(cat "$CORE_PLIST") $(cat "$tmp/err")"
cmp -s "$SERVERS" "$tmp/servers.a" && cmp -s "$APPROVED_DIRECT" "$tmp/direct.a" && running 203.0.113.20 &&
  ok "  with its servers, approval and config" || bad "  servers or approval not restored: $(paste -sd' ' "$SERVERS")"
! grep -q 'anchor=empty' "$tmp/anchor.calls" && ! grep -q -- '-F' "$tmp/anchor.calls" && ok "  pf anchor loaded throughout" || bad "  pf: $(paste -sd'|' "$tmp/anchor.calls")"
[ -z "$(find "$DIR" -name '*.prev' -o -name '*.take' -o -name 'take*')" ] && ok "  no backups left" || bad "  left: $(find "$DIR" -name '*.prev' -o -name '*.take' -o -name 'take*')"
rm -f "$tmp/new-fails"

# --- review of #65: the rollback keeps a "ks set" made meanwhile, never uses set_mtu's copies,
# and puts back all an import replaced (its approved set, the other core's files)
[ -z "$(setting lan "")" ] || bad "lan set before the test"
cp "$CORE_DIR/xray.json" "$tmp/xray.before" 2>/dev/null; cp "$CORE_DIR/profile-xray.json" "$tmp/pxray.before" 2>/dev/null
launchctl() {
  echo "launchctl $* anchor=$([ -s "$tmp/anchor" ] && echo rules || echo empty) plist=$(cat "$CORE_PLIST")" >> "$tmp/anchor.calls"
  case "$1" in
    bootstrap) find "$DIR" -name '*.prev' >> "$tmp/prev.seen"; [ "$(cat "$CORE_PLIST")" = mihomo ] || put_setting lan 1 ;;
    print) [ ! -e "$tmp/job-gone" ] || return 1 ;;
  esac
  return 0
}
touch "$tmp/new-fails"; : > "$tmp/prev.seen"
rc=0; core_take "$Q4" import 2>"$tmp/err" || rc=$?
[ "$rc" != 0 ] && [ "$(core_kind)" = mihomo ] && [ "$(setting lan "")" = 1 ] &&
  ok "a failed switch keeps a «ks set» made while the new core started" || bad "settings after the rollback: $rc $(cat "$SETTINGS")"
[ ! -s "$tmp/prev.seen" ] && ok "  set_mtu's .prev copies neither made nor used" || bad "  .prev seen: $(cat "$tmp/prev.seen")"
[ "$(find "$APPROVED_SET" -name kind | wc -l | tr -d ' ')" = 2 ] && cmp -s "$CORE_DIR/xray.json" "$tmp/xray.before" && cmp -s "$CORE_DIR/profile-xray.json" "$tmp/pxray.before" &&
  ok "  a failed import that switched: its approved set and the other core's files as before" || bad "  set or xray files: $(find "$APPROVED_SET" -name kind | paste -sd' ' -)"
rm -f "$tmp/new-fails"; run "$A" use
[ "$rc" = 0 ] && ok "  the old subscription is used without the password again" || bad "  use A after the failed import: $rc $(cat "$tmp/err")"
drop_setting lan

# the VPN on but its job gone (crashed and booted out): the switch starts the new core; when it does
# not run, the old state is back and nothing is left running
touch "$tmp/new-fails" "$tmp/job-gone"; : > "$tmp/anchor.calls"
rc=0; core_take "$Q4" use 2>"$tmp/err" || rc=$?
[ "$rc" != 0 ] && [ "$(core_kind)" = mihomo ] && cmp -s "$SERVERS" "$tmp/servers.a" && cmp -s "$CORE_PLIST" "$CORE_DIR/plist.mihomo" &&
  grep -q 'launchctl bootout' "$tmp/anchor.calls" && ok "a failed switch with the job not loaded: back, the new job booted out" ||
  bad "failed switch, no job: $rc $(core_kind) $(paste -sd'|' "$tmp/anchor.calls") $(cat "$tmp/err")"
# the VPN off: nothing is started, the next «Подключить» starts the new core
rm -f "$tmp/new-fails"; VPN_PASS=0; : > "$tmp/anchor.calls"
rc=0; core_take "$Q4" use 2>"$tmp/err" || rc=$?
[ "$rc" = 0 ] && [ "$(core_kind)" = xray ] && ! grep -q 'launchctl bootstrap' "$tmp/anchor.calls" && ok "with the VPN off: switched, nothing started" ||
  bad "switch with the VPN off: $rc $(core_kind) $(paste -sd'|' "$tmp/anchor.calls")"
rc=0; core_take "$A" use 2>"$tmp/err" || rc=$?
VPN_PASS=1; rm -f "$tmp/job-gone"

# the other core's launchd job missing: an error, not «already right»
mv "$CORE_DIR/plist.xray" "$tmp/plist.xray"
rc=0; core_take "$Q4" use 2>"$tmp/err" || rc=$?
[ "$rc" != 0 ] && [ "$(core_kind)" = mihomo ] && cmp -s "$CORE_PLIST" "$CORE_DIR/plist.mihomo" && grep -q 'Нет задания launchd для ядра xray' "$tmp/err" &&
  ok "the other core's job missing: refused, mihomo runs" || bad "missing plist: $rc $(core_kind) $(cat "$tmp/err")"
mv "$tmp/plist.xray" "$CORE_DIR/plist.xray"

# an install from before 0.20 (no approved set): its one import never approves the other kind
rm -rf "$APPROVED_SET"
rc=0; core_take "$Q4" use 2>"$tmp/err" || rc=$?
[ "$rc" = 3 ] && [ "$(core_kind)" = mihomo ] && ok "no approved set: a profile of the other kind refused (3)" || bad "no set, use Q4: $rc $(core_kind) $(cat "$tmp/err")"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
