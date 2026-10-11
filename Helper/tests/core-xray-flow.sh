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
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); $a->[0]{outbounds}[1]{settings}{vnext}[0]{address} = "203.0.113.99";
  print JSON::PP->new->encode($a)' < "$tmp/direct.json" > "$tmp/both.json"
run "$tmp/both.json" refresh
[ "$rc" = 3 ] && grep -q '(DIRECT)' "$tmp/err" && grep -q 'новые серверы' "$tmp/err" &&
  ok "refresh with a new server and a new direct rule: exit 3 naming both, «(DIRECT)» for the app (KS-12)" || bad "refresh both: $rc $(cat "$tmp/err")"

# --- regen after an upgrade, rebuild for a setting
: > "$tmp/launchd"
out=$(core_regen 2>&1)
[ "$out" = "core config: kept" ] && ok "_regen: same generator, kept" || bad "_regen: $out"
rm -f "$CORE_DIR/direct"; core_regen >/dev/null 2>&1
cmp -s "$CORE_DIR/direct" "$APPROVED_DIRECT" && [ "$(stat -f %Lp "$CORE_DIR/direct")" = 600 ] &&
  ok "  an older helper's install: the running DIRECT recorded (root-only) for the server switch" || bad "  running direct: $(ls -l "$CORE_DIR")"
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
# KS-10: the import approves what every host sends DIRECT; a switch (passwordless) to a host whose
# config sends something else past the VPN, e.g. one a refresh added, needs the admin (ADR 0013)
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $b = JSON::PP->new->decode(JSON::PP->new->encode($a->[0]));
  $b->{remarks} = "🇱🇹Литва 2"; unshift @{ $b->{routing}{rules} }, { network => "tcp,udp", outboundTag => "direct" }; push @$a, $b;
  print JSON::PP->new->encode($a)' < "$tmp/two.json" > "$tmp/three.json"
LOADED=0; put_setting xrayserver ""
run "$tmp/two.json" import
run "$tmp/three.json" refresh
[ "$rc" = 0 ] && ok "refresh adding a host on an approved server, the running one unchanged: taken" || bad "three hosts refresh: $rc $(cat "$tmp/err")"
cp "$CORE_DIR/xray.json" "$tmp/before"; cp "$CORE_EGRESS" "$tmp/egress-before"; : > "$EVENTS"
rc=0; core_select "$XRAY_GROUP" "🇱🇹Литва 2" 2>"$tmp/err" || rc=$?
[ "$rc" = 3 ] && grep -q '(DIRECT)' "$tmp/err" && ok "KS-10: select of a host with unapproved DIRECT: refused (exit 3, «(DIRECT)»)" || bad "KS-10 select: $rc $(cat "$tmp/err")"
[ "$(setting xrayserver "")" = "" ] && cmp -s "$CORE_DIR/xray.json" "$tmp/before" && cmp -s "$CORE_EGRESS" "$tmp/egress-before" &&
  ok "  the running config, egress and the pick kept" || bad "  kept: $(setting xrayserver "") $(cat "$CORE_EGRESS")"
grep -q 'Литва 2 refused' "$EVENTS" && ok "  logged" || bad "  events: $(cat "$EVENTS")"
# a default install has no xrayserver line: the refused switch must not leave an empty one, which
# settings_lines_ok used to call damaged, so the watchdog blocked everything (lockdown)
grep -v '^xrayserver=' "$SETTINGS" > "$tmp/set" && cat "$tmp/set" > "$SETTINGS"
rc=0; core_select "$XRAY_GROUP" "🇱🇹Литва 2" 2>/dev/null || rc=$?
[ "$rc" = 3 ] && ! grep -q '^xrayserver=' "$SETTINGS" && [ -z "$(root_files_bad)" ] &&
  ok "  a default install (no pick): refused switch leaves no xrayserver line, the rules stay as usual" ||
  bad "  default install: rc $rc, settings $(paste -sd'|' "$SETTINGS"), bad: $(root_files_bad)"
printf 'core=xray\nxrayserver=\n' > "$tmp/set"
settings_lines_ok "$tmp/set" && ok "  an empty xrayserver= (left by an older ks) means no pick, not damage" || bad "  empty xrayserver= refused"
# the pick is written only after the gate: a ks killed while the candidate is built leaves no
# unapproved pick behind for the next ungated rebuild (rotation, a setting, _regen) to commit
eval "$(declare -f core_rebuild | sed '1s/core_rebuild/real_core_rebuild/')"
core_rebuild() { grep '^xrayserver=' "$DIR/settings" > "$tmp/seen"; real_core_rebuild "$@"; }
core_select "$XRAY_GROUP" "🇱🇹Литва 2" 2>/dev/null
! grep -q 'Литва 2' "$tmp/seen" && ok "  while the candidate is built and gated, the settings still name the running pick" ||
  bad "  pick written before the gate: $(cat "$tmp/seen")"
eval "$(declare -f real_core_rebuild | sed '1s/real_core_rebuild/core_rebuild/')"
# KS-10 / fail closed: a host name the settings would call damaged is never written (failover
# takes names from the subscription without the passwordless filter)
cp "$SETTINGS" "$tmp/set-before"; cp "$REPORT" "$tmp/report-before"
/usr/bin/perl -MJSON::PP -i -0pe '$r = JSON::PP->new->decode($_); push @{ $r->{servers} }, { name => "DE\tX" }; $_ = JSON::PP->new->encode($r)' "$REPORT"
rc=0; xray_select $'DE\tX' 2>/dev/null || rc=$?
cp "$tmp/report-before" "$REPORT"
[ "$rc" != 0 ] && cmp -s "$SETTINGS" "$tmp/set-before" && ok "  a host name with a control character: refused, settings untouched" || bad "  bad name: rc $rc $(cat "$SETTINGS")"
core_select "$XRAY_GROUP" DE 2>"$tmp/err" && [ "$(setting xrayserver "")" = DE ] && ok "  a host approved at import still switches" || bad "  DE: $(cat "$tmp/err")"
run "$tmp/three.json" import
core_select "$XRAY_GROUP" "🇱🇹Литва 2" 2>"$tmp/err" && [ "$(setting xrayserver "")" = "🇱🇹Литва 2" ] && [ "$(paste -sd, - < "$CORE_EGRESS")" = rules,dns ] &&
  ok "  after an import with the password (approving every host) it switches" || bad "  approved: $(cat "$tmp/err")"
[ "$(stat -f %Lp "$CORE_DIR/approved-switch")" = 600 ] && ok "  the approval root-only" || bad "  approved-switch mode"
run "$tmp/three.json" refresh
[ "$rc" = 0 ] && ok "  a refresh while on a host whose approved DIRECT differs from the first one's: taken" || bad "  refresh after switch: $rc $(cat "$tmp/err")"
core_select "$XRAY_GROUP" "🇱🇹Литва" 2>/dev/null
put_setting splitapps Telegram; core_apply_settings 2>/dev/null
core_select "$XRAY_GROUP" DE 2>"$tmp/err" && ok "  after the admin changed apps outside the VPN, a switch to a host like the running one works" || bad "  splitapps: $(cat "$tmp/err")"
put_setting splitapps ""; core_apply_settings 2>/dev/null
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
[ "$(setting core "")" = mihomo ] && grep -q 'подписку' "$tmp/err" && ok "set core mihomo: stored, the subscription asked for" ||
  bad "set core: $(cat "$tmp/err")"
# Switching while connected, protection on: the app fetches the subscription for the new core and
# "ks core import" resolves its server names after "ks set core". With the running core stopped
# nothing could leave (pf) and the Mac stayed without a VPN; the running one stays until "core on".
echo '<plist>mihomo</plist>' > "$CORE_PLIST"; echo cfg > "$CORE_DIR/config.yaml"; echo stale > "$CORE_DIR/xray.json"
LOADED=1; : > "$tmp/launchd"
set_core xray 2>"$tmp/err"
! grep -qE 'bootout|bootstrap|kickstart|disable' "$tmp/launchd" && [ "$(cat "$CORE_PLIST")" = '<plist>mihomo</plist>' ] &&
  [ -s "$CORE_DIR/config.yaml" ] && [ ! -e "$CORE_DIR/xray.json" ] && [ "$(setting core "")" = xray ] && grep -q 'подписку' "$tmp/err" &&
  ok "set core while running: stored, the running core keeps the VPN up until core on, a stale config of the new one gone" ||
  bad "set core running: $(cat "$tmp/launchd") / $(cat "$CORE_PLIST") / $(ls "$CORE_DIR") / $(cat "$tmp/err")"
# ...and back before the import for the new one worked: mihomo still runs on config.yaml, which
# must stay, or its next restart has no config and no VPN
set_core mihomo 2>/dev/null
[ -s "$CORE_DIR/config.yaml" ] && [ "$(setting core "")" = mihomo ] &&
  ok "set core back to the running one: its config kept" || bad "set core back: $(ls "$CORE_DIR")"
echo '{}' > "$CORE_DIR/xray.json"; put_setting core xray
set_core xray 2>/dev/null
[ -s "$CORE_DIR/xray.json" ] && ok "set core to the one already chosen: its config kept" || bad "set core same: $(ls "$CORE_DIR")"
rm -f "$CORE_DIR/xray.json"; put_setting core xray
set_core sing-box 2>/dev/null && bad "set core sing-box accepted" || ok "set core: only xray or mihomo"

# "ks core on" then swaps the job: launchd returns from bootout before the old job is gone and
# refuses a bootstrap until then
DIAG="$tmp/diag"; pgrep() { return 1; }; dns_locked() { echo "dns $1" >> "$tmp/launchd"; }; sleep() { :; }
launchctl() {
  local st; st=$(cat "$tmp/job")
  echo "launchctl $*" >> "$tmp/launchd"
  case "$1" in
    print) case "$st" in loaded) echo 'state = running' ;; unloading:0) echo unloaded > "$tmp/job"; return 1 ;;
                         unloading:*) echo "unloading:$((${st#unloading:} - 1))" > "$tmp/job"; echo 'state = running' ;; *) return 1 ;; esac ;;
    bootout) echo unloading:2 > "$tmp/job" ;;
    bootstrap) case "$st" in unloaded|unloading:0) echo loaded > "$tmp/job" ;; *) return 37 ;; esac ;;
    kickstart) [ "$st" = loaded ] ;;
  esac
}
echo '{}' > "$CORE_DIR/xray.json"   # the subscription imported for Xray meanwhile
echo loaded > "$tmp/job"; : > "$tmp/launchd"
core_on 2>"$tmp/err" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(cat "$tmp/job")" = loaded ] && [ "$(cat "$CORE_PLIST")" = '<plist>xray</plist>' ] &&
  [ "$(grep -oE 'launchctl (bootout|bootstrap)' "$tmp/launchd" | paste -sd, -)" = "launchctl bootout,launchctl bootstrap" ] && grep -q '^dns apply$' "$tmp/launchd" &&
  ok "core on after the switch: the old job out, the new one in once it is gone, DNS to it" ||
  bad "core on switch: rc $rc $(cat "$tmp/err") / $(cat "$tmp/job") / $(paste -sd'|' "$tmp/launchd")"
rm -f "$CORE_DIR/xray.json"; echo '<plist>mihomo</plist>' > "$CORE_PLIST"; echo loaded > "$tmp/job"; : > "$tmp/launchd"
core_on 2>/dev/null && bad "core on without the new core's config accepted" ||
  { grep -q bootout "$tmp/launchd" && bad "core on without a config stopped the running core" || ok "core on before the import: refused, the running core kept"; }
# mihomo running, Xray to start: its stats port is checked before mihomo goes (a taken port means a
# config without the api first, else Xray would not start and the VPN be gone)
xray_api_check() { echo "launchctl api-check" >> "$tmp/launchd"; return 1; }
echo '{}' > "$CORE_DIR/xray.json"; echo '<plist>mihomo</plist>' > "$CORE_PLIST"; echo loaded > "$tmp/job"; : > "$tmp/launchd"
core_on 2>/dev/null
[ "$(grep -oE 'api-check|bootout' "$tmp/launchd" | head -2 | paste -sd, -)" = "api-check,bootout" ] &&
  ok "core on, mihomo to Xray: the stats port checked before the running core is stopped" || bad "api check: $(paste -sd'|' "$tmp/launchd")"
unset -f pgrep dns_locked sleep
put_setting core xray
set_multihop LT_1_FB 2>"$tmp/err" && bad "double VPN accepted with Xray" || ok "double VPN: refused with Xray (not yet)"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
