#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The core choice (ADR 0020): "ks set core", import/refresh/regen with Xray, the server switch and
# what "ks core proxies" says for Xray, the launchd plist following the choice. pfctl, launchctl
# and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-xray-flow.sh   (XRAY=/path/to/xray, else a stub that logs its arguments)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-}
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; CORE_DIR="$tmp/core"; mkdir -p "$CORE_DIR/ctl" "$tmp/ld"
SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; EVENTS="$DIR/events.log"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; SERVERS_CORE="$DIR/servers-core"
CORE_CTL="$CORE_DIR/ctl/mihomo.sock"
CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; APPROVED_DIRECT="$CORE_DIR/approved-direct"
CORE_EGRESS="$CORE_DIR/egress"; REPORT="$CORE_DIR/routing.json"; CORE_PLIST="$tmp/ld/local.killswitch.core.plist"
printf '#!/bin/sh\necho "$@" >> "%s/xray-args"; [ ! -e "%s/xray-fails" ]\n' "$tmp" "$tmp" > "$CORE_DIR/xray"; chmod 755 "$CORE_DIR/xray"
printf '#!/bin/sh\nexit 0\n' > "$CORE_DIR/mihomo"; chmod 755 "$CORE_DIR/mihomo"
echo '<plist>mihomo</plist>' > "$CORE_DIR/plist.mihomo"; echo '<plist>xray</plist>' > "$CORE_DIR/plist.xray"
install() { :; }
pfctl() { cat >/dev/null; }
dscl() { return 0; }
vpn_ifaces() { :; }; ts_ifaces() { :; }
loaded() { return 1; }
LOADED=0
launchctl() { echo "launchctl $*" >> "$tmp/launchd"; case "$1" in print) [ "$LOADED" = 1 ] && echo 'state = running' ;; esac; [ "$1" != print ] || [ "$LOADED" = 1 ]; }
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; *) return 1 ;; esac; }
xray_observe() { return 1; }   # never the real core's API on this Mac
: > "$SERVERS_MANUAL"
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "$2"; }
run() { rc=0; core_import "$@" 2>"$tmp/err" || rc=$?; }

# --- the setting
printf 'core=xray\nxrayserver=🇱🇹Литва\n' > "$SETTINGS"
settings_lines_ok "$SETTINGS" && ok "settings: core and xrayserver are ours" || bad "settings refused core/xrayserver"
printf 'core=sing-box\n' > "$SETTINGS"
settings_lines_ok "$SETTINGS" && bad "core=sing-box accepted" || ok "settings: unknown core refused (fail closed, ADR 0015)"
rm -f "$SETTINGS"
[ "$(core_kind)" = mihomo ] && ok "no setting: mihomo (installs from before 0.17 keep their core)" || bad "default kind $(core_kind)"
[ "$(core_conf)" = "$CORE_DIR/config.yaml" ] && [ "$(core_profile)" = "$CORE_PROFILE" ] && ok "mihomo: config.yaml, profile.json" || bad "mihomo paths"
put_setting core xray
[ "$(core_kind)" = xray ] && [ "$(core_conf)" = "$CORE_DIR/xray.json" ] && [ "$(core_profile)" = "$CORE_DIR/profile-xray.json" ] &&
  ok "core=xray: xray.json, profile-xray.json" || bad "xray paths: $(core_conf) $(core_profile)"

# --- import with Xray
run "$fx/xray-panel.json" import
[ "$rc" = 0 ] && ok "import of the panel's Xray JSON" || bad "import: $rc $(cat "$tmp/err")"
[ -s "$CORE_DIR/xray.json" ] && [ ! -e "$CORE_DIR/config.yaml" ] && [ "$(stat -f %Lp "$CORE_DIR/xray.json")" = 600 ] &&
  ok "  config in xray.json, root-only; config.yaml untouched" || bad "  files: $(ls "$CORE_DIR")"
[ -s "$CORE_DIR/profile-xray.json" ] && [ ! -e "$CORE_PROFILE" ] && ok "  the subscription kept for rebuilds" || bad "  profile: $(ls "$CORE_DIR")"
[ "$(cat "$SERVERS_CORE")" = 203.0.113.10 ] && grep -qx 203.0.113.10 "$SERVERS" && ok "  servers for pf" || bad "  servers: $(cat "$SERVERS_CORE")"
[ "$(paste -sd, - < "$CORE_EGRESS")" = rules,dns ] && [ "$(j '$c->{core}' "$REPORT")" = xray ] && ok "  egress and report published" ||
  bad "  egress $(cat "$CORE_EGRESS"), report $(head -c 100 "$REPORT")"
grep -q -- "run -test -format json -c $CORE_DIR/xray.json.tmp" "$tmp/xray-args" && ok "  checked with xray run -test before it is put in place" ||
  bad "  xray args: $(cat "$tmp/xray-args" 2>&1)"
[ -s "$APPROVED_DIRECT" ] && grep -q '^rule	' "$APPROVED_DIRECT" && ok "  the direct rules approved" || bad "  approved direct"
cp "$CORE_DIR/xray.json" "$tmp/before"
touch "$tmp/xray-fails"
run "$fx/xray-panel.json" import
[ "$rc" != 0 ] && cmp -s "$CORE_DIR/xray.json" "$tmp/before" && ok "xray -test fails: import refused, config kept" || bad "xray -test failure: $rc"
rm -f "$tmp/xray-fails"
echo '{"proxies":[{"name":"a","type":"ss","server":"203.0.113.9","port":1,"cipher":"aes-128-gcm","password":"x"}]}' > "$tmp/m.json"
run "$tmp/m.json" import
[ "$rc" != 0 ] && grep -q Xray "$tmp/err" && ok "a mihomo profile while core=xray: refused with the reason" || bad "mihomo profile: $rc $(cat "$tmp/err")"

# --- refresh (passwordless) measures against the approval, as with mihomo
run "$fx/xray-panel.json" refresh
[ "$rc" = 0 ] && ok "refresh, nothing new: taken" || bad "refresh same: $rc $(cat "$tmp/err")"
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); $a->[0]{outbounds}[1]{settings}{vnext}[0]{address} = "203.0.113.99";
  print JSON::PP->new->encode($a)' < "$fx/xray-panel.json" > "$tmp/new.json"
run "$tmp/new.json" refresh
[ "$rc" = 3 ] && ok "refresh with a new server address: needs the admin (exit 3)" || bad "refresh new server: $rc"
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); unshift @{ $a->[0]{routing}{rules} }, { domain => ["domain:example.org"], outboundTag => "direct" };
  print JSON::PP->new->encode($a)' < "$fx/xray-panel.json" > "$tmp/direct.json"
run "$tmp/direct.json" refresh
[ "$rc" = 3 ] && ok "refresh with a new direct rule: needs the admin (exit 3)" || bad "refresh new direct: $rc"

# --- regen after an upgrade, rebuild for a setting
: > "$tmp/launchd"
out=$(core_regen 2>&1)
[ "$out" = "core config: kept" ] && ok "_regen: same generator, kept" || bad "_regen: $out"
LOADED=1
core_reload
grep -q 'kickstart -k' "$tmp/launchd" && ok "reload with Xray: a restart (no API to reread the config)" || bad "reload: $(cat "$tmp/launchd")"

# --- the server list and the switch
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $b = JSON::PP->new->decode(JSON::PP->new->encode($a->[0]));
  $b->{remarks} = "DE"; $_->{settings}{vnext}[0]{address} = "de.example.com" for @{ $b->{outbounds} }[0, 1]; push @$a, $b;
  print JSON::PP->new->encode($a)' < "$fx/xray-panel.json" > "$tmp/two.json"
LOADED=0
run "$tmp/two.json" import
[ "$rc" = 0 ] && [ "$(paste -sd, - < "$SERVERS_CORE")" = 203.0.113.10,203.0.113.20 ] && ok "two hosts: both approved" || bad "two hosts: $rc $(cat "$tmp/err")"
p=$(core_proxies)
export G=$XRAY_GROUP
[ "$(j '$c->{proxies}{$ENV{G}}{type} . " " . $c->{proxies}{$ENV{G}}{now} . " " . join(",", @{ $c->{proxies}{$ENV{G}}{all} })' <(echo "$p"))" = \
  "Selector 🇱🇹Литва 🇱🇹Литва,DE" ] && ok "proxies with Xray: one selector of the subscription's hosts, the running one" || bad "proxies: $p"
LOADED=1; : > "$tmp/launchd"
core_select "$XRAY_GROUP" DE 2>"$tmp/err" && [ "$(setting xrayserver "")" = DE ] &&
  [ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}' "$CORE_DIR/xray.json")" = 203.0.113.20 ] && grep -q 'kickstart -k' "$tmp/launchd" &&
  ok "select DE: stored, config rebuilt for it, core restarted" || bad "select: $(cat "$tmp/err") $(setting xrayserver "")"
[ "$(j '$c->{proxies}{$ENV{G}}{now}' <(core_proxies))" = DE ] && ok "  proxies says DE now" || bad "  now: $(core_proxies)"
core_select "$XRAY_GROUP" Nowhere 2>/dev/null && bad "unknown host selected" || ok "select of a host not in the subscription: refused"
core_select Other DE 2>/dev/null && bad "another group accepted" || ok "select of another group: refused"
xray_observe() { printf 'ks-ping-0\t1\t80\nks-ping-1\t0\t0\n'; }   # the API is in core-xray-ping.sh
[ "$(core_delay DE)" = '{"delay":0}' ] && [ "$(core_delay "$XRAY_GROUP")" = '{"🇱🇹Литва":80}' ] && ok "delay with Xray: the observatory's last probes (ADR 0023)" || bad "delay: $(core_delay DE 2>&1)"
core_connections 2>/dev/null && bad "connections answered" || ok "connections: not with Xray (the app hides them)"

# --- the launchd job follows the choice
echo old > "$CORE_PLIST"; : > "$tmp/launchd"
core_plist_sync && [ "$(cat "$CORE_PLIST")" = '<plist>xray</plist>' ] && ok "plist: the Xray job put in place" || bad "plist: $(cat "$CORE_PLIST")"
core_plist_sync && bad "plist already right: reported as changed" || ok "plist already right: nothing to do"
LOADED=0; : > "$tmp/launchd"
set_core mihomo 2>"$tmp/err"
[ "$(setting core "")" = mihomo ] && [ "$(cat "$CORE_PLIST")" = '<plist>mihomo</plist>' ] && ok "set core mihomo: stored, plist swapped" ||
  bad "set core: $(cat "$tmp/err") $(cat "$CORE_PLIST")"
LOADED=1; : > "$tmp/launchd"
set_core xray 2>"$tmp/err"
grep -q 'bootout' "$tmp/launchd" && ! grep -q 'bootstrap' "$tmp/launchd" && grep -q 'подписку' "$tmp/err" &&
  [ "$(cat "$CORE_PLIST")" = '<plist>xray</plist>' ] &&
  ok "set core while running: stopped (pf keeps blocking) until the subscription is imported for it" || bad "set core running: $(cat "$tmp/launchd") / $(cat "$tmp/err")"
set_core sing-box 2>/dev/null && bad "set core sing-box accepted" || ok "set core: only xray or mihomo"
put_setting core xray
set_multihop LT_1_FB 2>"$tmp/err" && bad "double VPN accepted with Xray" || ok "double VPN: refused with Xray (not yet)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
