#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The VPN through an upgrade with Xray ("ks _regen", install.sh): a new config is put in place only
# after "xray run -test", a restarted Xray that does not come up gets the previous config back, and
# a stats port taken by another program means a config without the api (no counters) instead of an
# Xray that does not start. pfctl, launchctl, lsof and DNS are replaced here, nothing is loaded.
#   Helper/tests/core-xray-upgrade.sh   (XRAY=/path/to/xray to check the no-api config for real)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-}
fx="$here/fixtures"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DIR="$T"; CORE_DIR="$T/core"; mkdir -p "$CORE_DIR/ctl" "$T/ld"
SETTINGS="$DIR/settings"; ALLOW="$DIR/allow"; TSRELAYS="$DIR/none"; EVENTS="$DIR/events.log"
SERVERS="$DIR/servers"; SERVERS_MANUAL="$DIR/servers-manual"; SERVERS_CORE="$DIR/servers-core"
CORE_CTL="$CORE_DIR/ctl/mihomo.sock"
CORE_PROFILE="$CORE_DIR/profile.json"; PINS="$CORE_DIR/pins"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; APPROVED_DIRECT="$CORE_DIR/approved-direct"
CORE_EGRESS="$CORE_DIR/egress"; REPORT="$CORE_DIR/routing.json"; CORE_PLIST="$T/ld/local.killswitch.core.plist"
DIAG="$T/diag"
# the stub Xray: "run -test" fails while $T/xray-fails exists
printf '#!/bin/sh\necho "$@" >> "%s/xray-args"; [ ! -e "%s/xray-fails" ]\n' "$T" "$T" > "$CORE_DIR/xray"; chmod 755 "$CORE_DIR/xray"
install() { :; }
pfctl() { cat >/dev/null; }
dscl() { return 0; }
vpn_ifaces() { :; }; ts_ifaces() { :; }
loaded() { return 1; }
resolve_host() { return 1; }
# launchd: the core job runs while RUN=1; a restart gives it a new pid
RUN=0; PID=100
launchctl() {
  echo "launchctl $*" >> "$T/launchd"
  case "$1" in
    print) [ "$RUN" = 1 ] && printf 'state = running\npid = %s\n' "$PID" ;;
    kickstart) PID=$((PID + 1)) ;;
  esac
  [ "$1" != print ] || [ "$RUN" = 1 ]
}
# lsof: who listens on the stats port ($API_HOLDER) and whether the core's inbounds listen (UP)
API_HOLDER=""; UP=1
lsof() {
  case "$*" in
    *"-iTCP:$CORE_API_PORT "*) [ -n "$API_HOLDER" ] && echo "$API_HOLDER" ;;
    *"-iTCP:$FETCH_PORT "*) [ "$UP" = 1 ] && echo "$PID" ;;
  esac
  return 0
}
sleep() { :; }
: > "$SERVERS_MANUAL"
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "$2"; }
restarts() { grep -c 'kickstart -k' "$T/launchd" 2>/dev/null || true; }
old_config() {  # the running config as an older helper wrote it: valid JSON, different from what we make now
  /usr/bin/perl -MJSON::PP -i -0pe '$c = JSON::PP->new->decode($_); $c->{old} = 1; $_ = JSON::PP->new->canonical->encode($c)' "$CORE_DIR/xray.json"
  cp "$CORE_DIR/xray.json" "$T/old.json"
}

put_setting core xray
KS_PINS=/dev/null
printf 'lt.example.com\t203.0.113.10\n' > "$T/pins"
KS_PINS="$T/pins" core_import "$fx/xray-panel.json" import 2>"$T/err" >/dev/null || bad "import: $(cat "$T/err")"
unset KS_PINS
[ -s "$CORE_DIR/xray.json" ] && ok "setup: imported with Xray" || bad "setup: no xray.json"

# --- an upgrade from 0.18 (no approved-switch, KS-10): built from the kept profile, but only while
# it is the one the admin imported; a refresh since then may have added hosts nobody approved
RUN=0; rm -f "$CORE_DIR/approved-switch"; : > "$EVENTS"
touch -t 202601010000 "$CORE_DIR/profile-xray.json"   # older than approved-direct: as the import left it
core_regen >/dev/null 2>&1
[ -s "$CORE_DIR/approved-switch" ] && [ "$(stat -f %Lp "$CORE_DIR/approved-switch")" = 600 ] &&
  grep -qxF "$(shasum -a 256 < "$CORE_DIR/direct" | cut -d' ' -f1)" "$CORE_DIR/approved-switch" &&
  ok "upgrade from 0.18: the switch approval built from the imported profile, root-only" || bad "approval: $(ls -l "$CORE_DIR") $(cat "$EVENTS")"
grep -q 'server switch approval taken from the last import' "$EVENTS" && ok "  logged" || bad "  events: $(cat "$EVENTS")"
rm -f "$CORE_DIR/approved-switch"; : > "$EVENTS"
touch -t 203001010000 "$CORE_DIR/profile-xray.json"   # replaced by a refresh after the import
core_regen >/dev/null 2>&1
[ ! -e "$CORE_DIR/approved-switch" ] && grep -q 'refreshed since the last import' "$EVENTS" &&
  ok "  a profile refreshed since the import: nothing approved without the password, logged" || bad "  refreshed: $(ls "$CORE_DIR") $(cat "$EVENTS")"
: > "$EVENTS"; touch -r "$APPROVED_DIRECT" "$CORE_DIR/profile-xray.json"   # the same instant: a refresh within the import's second
core_regen >/dev/null 2>&1
[ ! -e "$CORE_DIR/approved-switch" ] && grep -q 'refreshed since the last import' "$EVENTS" &&
  ok "  a profile as new as the approval: not taken for the imported one" || bad "  same time: $(ls "$CORE_DIR") $(cat "$EVENTS")"
eval "$(declare -f core_generate | sed '1s/core_generate/real_core_generate/')"
core_generate() { [ -z "${KS_APPROVE_ALL:-}" ] || { echo "no luck" >&2; return 1; }; real_core_generate "$@"; }
: > "$EVENTS"; touch -t 202601010000 "$CORE_DIR/profile-xray.json"; core_regen >/dev/null 2>&1
[ ! -e "$CORE_DIR/approved-switch" ] && grep -q 'server switch approval failed: no luck' "$EVENTS" &&
  ok "  a failed build of the approval: logged with the reason" || bad "  failed: $(cat "$EVENTS")"
eval "$(declare -f real_core_generate | sed '1s/real_core_generate/core_generate/')"
put_setting core mihomo; touch -t 202601010000 "$CORE_DIR/profile-xray.json"; core_regen >/dev/null 2>&1; put_setting core xray
[ ! -e "$CORE_DIR/approved-switch" ] && ok "  mihomo: none (switches are Xray's)" || bad "  mihomo approval"
touch -t 202601010000 "$CORE_DIR/profile-xray.json"; core_regen >/dev/null 2>&1

# --- (a) the new config is checked before it replaces the running one
old_config; RUN=1; : > "$T/launchd"; : > "$EVENTS"; touch "$T/xray-fails"
core_regen >/dev/null 2>&1 && bad "_regen took a config xray run -test refused" || ok "_regen: a config Xray refuses fails"
cmp -s "$CORE_DIR/xray.json" "$T/old.json" && ok "_regen refused: the running config stays" || bad "_regen refused: config replaced"
[ "$(restarts)" = 0 ] && ok "_regen refused: Xray not restarted" || bad "_regen refused: restarted ($(cat "$T/launchd"))"
grep -q 'core config: the new one refused by the core, the running one kept' "$EVENTS" && ok "_regen refused: the reason in events.log" ||
  bad "_regen refused: events $(cat "$EVENTS")"
rm -f "$T/xray-fails"

# --- the restarted Xray comes up: the new config stays, one restart
old_config; RUN=1; UP=1; : > "$T/launchd"; : > "$EVENTS"
out=$(core_regen 2>&1) && [ "$out" = "core config: reloaded" ] && ok "_regen: new config, Xray restarted with it" || bad "_regen: $out"
[ "$(restarts)" = 1 ] && [ "$(j '$c->{old} // 0' "$CORE_DIR/xray.json")" = 0 ] && ok "_regen: one restart, the new config in place" ||
  bad "_regen: restarts $(restarts)"
ls "$CORE_DIR"/*.prev "$DIR"/*.prev >/dev/null 2>&1 && bad "_regen: backups left behind" || ok "_regen: no backups left behind"

# --- (b) the restarted Xray does not come up within ~5 s: the previous config back
old_config; RUN=1; UP=0; : > "$T/launchd"; : > "$EVENTS"
core_regen >/dev/null 2>&1 && bad "_regen with an Xray that did not come up succeeded" || ok "_regen: Xray did not come up, fails"
cmp -s "$CORE_DIR/xray.json" "$T/old.json" && ok "_regen rolled back: the previous config in place" || bad "rollback: config not restored"
[ "$(restarts)" = 2 ] && ok "_regen rolled back: Xray restarted with it" || bad "rollback restarts: $(restarts)"
grep -q 'core config rolled back' "$EVENTS" && ok "_regen rolled back: in events.log" || bad "rollback events: $(cat "$EVENTS")"
UP=1

# --- the core not running: nothing to restart or wait for
old_config; RUN=0; : > "$T/launchd"
out=$(core_regen 2>&1) && [ "$(restarts)" = 0 ] && ! cmp -s "$CORE_DIR/xray.json" "$T/old.json" &&
  ok "_regen, core off: new config, no restart" || bad "_regen off: $out $(restarts)"

# --- (c) the stats port taken by another program
RUN=0; API_HOLDER=4242; : > "$EVENTS"
xray_api_check && [ -f "$CORE_DIR/api-off" ] && ok "port taken: noticed" || bad "port taken: not noticed"
grep -q "xray stats port 127.0.0.1:$CORE_API_PORT is taken by another program" "$EVENTS" && ok "port taken: in events.log" || bad "port events: $(cat "$EVENTS")"
xray_api_check && bad "port still taken: changed again" || ok "port still taken: nothing new"
[ "$(grep -c 'stats port' "$EVENTS")" = 1 ] && ok "port still taken: logged once" || bad "port logged: $(cat "$EVENTS")"
old_config; out=$(core_regen 2>&1)
[ "$(j 'exists $c->{api} || exists $c->{stats} ? 1 : 0' "$CORE_DIR/xray.json")" = 0 ] &&
  ok "upgrade with the port taken: config without the api, Xray can start" || bad "no api: $out $(j '$c->{api}' "$CORE_DIR/xray.json")"
[ "$(j 'scalar grep { $_->{tag} eq "ks-fetch" } @{ $c->{inbounds} }' "$CORE_DIR/xray.json")" = 1 ] && ok "  the rest of the config as usual" || bad "inbounds"
if [ -x "$XRAY" ]; then
  if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$CORE_DIR/xray.json" 2>&1); then ok "no-api config: xray run -test"
  else bad "no-api config: xray run -test: $(tail -2 <<<"$out")"; fi
else echo "skip  no-api config: xray run -test (no XRAY)"; fi
# our own Xray holding it is not someone else
API_HOLDER=101; RUN=1; PID=101
xray_api_check && [ ! -f "$CORE_DIR/api-off" ] && ok "port held by our own core: the api back" || bad "own core: $(ls "$CORE_DIR")"
grep -q 'xray stats port free again' "$EVENTS" && ok "port free: in events.log" || bad "free events: $(cat "$EVENTS")"
RUN=0; API_HOLDER=""; old_config; core_regen >/dev/null 2>&1
[ "$(j '$c->{api}{listen}' "$CORE_DIR/xray.json")" = "127.0.0.1:$CORE_API_PORT" ] && ok "port free: config with the api again" || bad "api back"
put_setting core mihomo; API_HOLDER=4242
xray_api_check && bad "mihomo: port checked" || ok "mihomo: the stats port is Xray's only"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
