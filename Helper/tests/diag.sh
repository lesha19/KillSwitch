#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The local diagnostics journal of Helper/ks (ADR 0021): Xray's stats API and access log, the
# per-minute metrics, the events the watchdog notices, rotation and «Собрать отчёт» with its
# redaction. No root, no network: launchctl, curl, scutil and the core are stand-ins.
#   Helper/tests/diag.sh   (XRAY=/path/to/xray to check configs with "xray run -test")
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; SETTINGS="$tmp/settings"; EVENTS="$tmp/events.log"; STATEF="$tmp/daemon-state"
SERVERS="$tmp/servers"; SERVERS_MANUAL="$tmp/servers-manual"; SERVERS_CORE="$tmp/core/servers-core"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"; PINS="$CORE_DIR/pins"; APPROVED_HOSTS="$CORE_DIR/approved-hosts"
CORE_PROFILE="$CORE_DIR/profile.json"; REPORT="$CORE_DIR/routing.json"; FOREIGN_VPN="$CORE_DIR/foreign-vpn"; CORE_EGRESS="$CORE_DIR/egress"
DIAG="$tmp/diag"
resolve_host() { case "$1" in lt.example.com) echo 203.0.113.40 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$tmp/c}"; }
gen() { core_generate_xray "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
xtest() {  # xtest <name> <config>
  if [ -x "$XRAY" ]; then
    if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
    else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
  else echo "skip  $1: xray run -test (no $XRAY)"; fi
}

# --- Xray: counters through the stats API, on loopback only
gen "$fx/xray-panel.json" || bad "panel config refused: $(cat "$tmp/err")"
[ "$(j '$c->{api}{listen}')" = "127.0.0.1:$CORE_API_PORT" ] && [ "$(j 'join ",", @{ $c->{api}{services} }')" = StatsService ] &&
  ok "api: StatsService only, on 127.0.0.1:$CORE_API_PORT" || bad "api: $(j '$c->{api}')"
[ "$(j 'ref $c->{stats}')" = HASH ] && ok "stats: on" || bad "stats: $(j '$c->{stats}')"
[ "$(j 'join ",", map { "$_=" . ($c->{policy}{system}{$_} ? 1 : 0) } sort keys %{ $c->{policy}{system} }')" = \
  "statsInboundDownlink=1,statsInboundUplink=1,statsOutboundDownlink=1,statsOutboundUplink=1" ] &&
  ok "policy: system counters for inbounds and outbounds" || bad "policy system: $(j '$c->{policy}{system}')"
[ "$(j '$c->{policy}{levels}{0}{connIdle}')" = 600 ] && ok "policy: the subscription's levels kept" || bad "policy levels: $(j '$c->{policy}')"
[ "$(j '$c->{log}{access}')" = none ] && ok "diagnostics off (default): no access log" || bad "access: $(j '$c->{log}')"
xtest "stats api" "$tmp/c"
cp "$fx/xray-panel.json" "$tmp/p.json"
/usr/bin/perl -MJSON::PP -i -0pe '$a = JSON::PP->new->decode($_); delete $_->{policy} for @$a; $_ = JSON::PP->new->encode($a)' "$tmp/p.json"
gen "$tmp/p.json" && [ "$(j '$c->{policy}{system}{statsInboundUplink} ? 1 : 0')" = 1 ] && ok "policy: added when the subscription has none" ||
  bad "no policy: $(j '$c->{policy}')"

# --- «Подробная диагностика»: every connection in diag/access.log, only when on
echo diag=1 > "$SETTINGS"
gen "$fx/xray-panel.json" && [ "$(j '$c->{log}{access}')" = none ] && ok "diag=1 without the diag folder: no access log (Xray would not start)" ||
  bad "no folder: $(j '$c->{log}')"
mkdir "$DIAG"
gen "$fx/xray-panel.json" && [ "$(j '$c->{log}{access}')" = "$DIAG/access.log" ] && [ "$(j '$c->{log}{loglevel}')" = warning ] &&
  ok "diag=1: access log in the diag folder, error log unchanged" || bad "verbose: $(j '$c->{log}')"
xtest "access log" "$tmp/c"
echo diag=0 > "$SETTINGS"
gen "$fx/xray-panel.json" && [ "$(j '$c->{log}{access}')" = none ] && ok "diag=0: no access log" || bad "diag=0: $(j '$c->{log}')"
rm -f "$SETTINGS"
settings_lines_ok <(printf 'diag=1\ndiag=0\n') && ok "settings: diag=0|1 is ours" || bad "settings: diag refused"
settings_lines_ok <(printf 'diag=verbose\n') && bad "settings: diag=verbose taken" || ok "settings: other diag values are not"

# --- Xray's counters: "ks core traffic" sums the inbounds (the menu bar speed and the metrics)
cat > "$CORE_DIR/xray" <<'XEOF'
#!/bin/bash
[ "$*" = "api statsquery --server=127.0.0.1:47891 -t 2" ] || exit 1
cat "$(dirname "$0")/stats.json"
XEOF
chmod +x "$CORE_DIR/xray"
echo core=xray > "$SETTINGS"
cat > "$CORE_DIR/stats.json" <<'XEOF'
{"stat":[{"name":"outbound>>>LT_1>>>traffic>>>downlink","value":900},{"name":"inbound>>>ks-tun>>>traffic>>>uplink","value":130},
 {"name":"inbound>>>ks-tun>>>traffic>>>downlink","value":1000},{"name":"inbound>>>ks-dns>>>traffic>>>uplink"},
 {"name":"inbound>>>ks-fetch>>>traffic>>>uplink","value":20},{"name":"inbound>>>ks-fetch>>>traffic>>>downlink","value":5}]}
XEOF
[ "$(core_traffic 2>&1)" = "up=150 down=1005" ] && ok "xray: core traffic from the stats API (inbounds summed)" || bad "xray traffic: $(core_traffic 2>&1)"
echo '{}' > "$CORE_DIR/stats.json"
[ "$(core_traffic 2>&1)" = "up=0 down=0" ] && ok "xray: no counters yet is zero" || bad "xray empty: $(core_traffic 2>&1)"
rm -f "$SETTINGS"

# --- the per-minute metrics line
now=1791720000   # 2026-10-11, a whole minute
core_job() { CORE_RUN=$RUN; CORE_PID=${PIDV:-}; }
RUN=1; PIDV=4242
diag_probe() { echo "187 1"; }
core_traffic() { echo "up=$UP down=$DOWN"; }
net_sig() { echo "en0 192.168.1.1"; }
dns_servers() { echo "127.0.0.1"; }
utun_addrs() { echo "utun7 $CORE_TUN_ADDR"; }
printf 'pid=1\nprotection=on\ncore=on\ntunnels=vpn:utun7 ts:\nstandby=0\n' > "$STATEF"
printf 'core=xray\nxrayserver=🇱🇹Литва\n' > "$SETTINGS"
rm -rf "$DIAG"; diag_dir
UP=1000 DOWN=5000 diag_metric "$now" > "$tmp/m1" || bad "metric failed"
m() { j "$1" "$tmp/m1"; }
[ "$(m '$c->{t}')" = "$(date -r "$now" '+%Y-%m-%dT%H:%M:%S%z')" ] && [ "$(m '$c->{v}')" = "$KS_VERSION" ] && [ "$(m '$c->{core}')" = xray ] &&
  ok "metric: time, version, core" || bad "metric head: $(cat "$tmp/m1")"
[ "$(m '"$c->{running} $c->{pid} $c->{protection} $c->{standby} $c->{tun}"')" = "1 4242 on 0 1" ] &&
  ok "metric: core running with its pid, protection, standby, our tunnel up" || bad "metric state: $(cat "$tmp/m1")"
[ "$(m '$c->{server}')" = "🇱🇹Литва" ] && ok "metric: the chosen server by name" || bad "metric server: $(m '$c->{server}')"
[ "$(m '"$c->{probe_ms} $c->{probe_ok}"')" = "187 1" ] && ok "metric: probe through the core" || bad "metric probe: $(cat "$tmp/m1")"
[ "$(m '"$c->{up} $c->{down}"')" = "0 0" ] && ok "metric: first reading has no delta" || bad "metric bytes: $(cat "$tmp/m1")"
[ "$(m '$c->{iface}')" = en0 ] && [[ "$(m '$c->{net}')" =~ ^[0-9a-f]{8}$ ]] && ! grep -q 192.168.1.1 "$tmp/m1" &&
  ok "metric: interface, router only as a signature" || bad "metric net: $(cat "$tmp/m1")"
[ "$(m '$c->{dns}')" = 127.0.0.1 ] && [ "$(m '$c->{verbose}')" = 0 ] && ok "metric: DNS in effect, verbose off" || bad "metric dns: $(cat "$tmp/m1")"
grep -qE '203\.0\.113|example\.com' "$tmp/m1" && bad "metric holds a server address" || ok "metric: no server address"
UP=1600 DOWN=9000 diag_metric $((now + 60)) > "$tmp/m1"
[ "$(m '"$c->{up} $c->{down}"')" = "600 4000" ] && ok "metric: bytes since the last minute" || bad "delta: $(cat "$tmp/m1")"
UP=100 DOWN=200 diag_metric $((now + 120)) > "$tmp/m1"
[ "$(m '"$c->{up} $c->{down}"')" = "100 200" ] && ok "metric: core restarted, counters from zero" || bad "restart delta: $(cat "$tmp/m1")"
RUN=0; PIDV=""
diag_metric $((now + 180)) > "$tmp/m1"
[ "$(m '"$c->{running} " . (defined $c->{probe_ms} ? "probe" : "null")')" = "0 null" ] && ok "metric: core down, no probe" || bad "down: $(cat "$tmp/m1")"
RUN=1; PIDV=4242
# the background pass: one line a minute into the day's file, network and DNS changes as events
rm -rf "$DIAG"; diag_dir
UP=1 DOWN=1 diag_pass "$now"; UP=1 DOWN=1 diag_pass $((now + 10))
day=$(date -r "$now" +%Y-%m-%d)
[ "$(wc -l < "$DIAG/metrics-$day.jsonl" | tr -d ' ')" = 1 ] && ok "pass: one metric a minute" || bad "metrics: $(cat "$DIAG"/metrics-* 2>&1)"
UP=1 DOWN=1 diag_pass $((now + 61))
[ "$(wc -l < "$DIAG/metrics-$day.jsonl" | tr -d ' ')" = 2 ] && ok "pass: the next minute" || bad "metrics 2: $(wc -l < "$DIAG/metrics-$day.jsonl")"
/usr/bin/perl -MJSON::PP -ne 'JSON::PP->new->decode($_)' "$DIAG/metrics-$day.jsonl" && ok "metrics: JSON lines" || bad "metrics not JSON"
ev() { cat "$DIAG"/events-*.jsonl 2>/dev/null; }
[ -z "$(ev)" ] && ok "pass: the first look at the network is no event" || bad "first pass events: $(ev)"
net_sig() { echo "en1 10.0.0.1"; }; dns_servers() { echo "10.0.0.1"; }
diag_pass $((now + 70))
ev | grep -q '"ev":"network","iface":"en1"' && ok "event: network changed (interface, router signature)" || bad "net event: $(ev)"
ev | grep -q '"ev":"dns","servers":"10.0.0.1"' && ok "event: DNS changed" || bad "dns event: $(ev)"
ev | grep '"ev":"network"' | grep -q 10.0.0.1 && bad "router address in the network event: $(ev)" || ok "event: router address not written"
printf 'ver=0.0.1\n' >> "$DIAG/state"
diag_pass $((now + 80))
ev | grep -q "\"ev\":\"version\",\"from\":\"0.0.1\",\"to\":\"$KS_VERSION\"" && ok "event: helper version changed" || bad "version event: $(ev)"

# --- what the watchdog notices every second: wake, tunnels, the core, protection
rm -rf "$DIAG"; diag_dir
PROT=on; STANDBY=0; TSIG="vpn:utun7 ts:"; CORE_STATE=on; CORE_PID=100; CORE_EXIT=""
SECONDS=1000; diag_tick 1
SECONDS=1001; diag_tick 2
[ -z "$(ev)" ] && ok "tick: nothing changed, nothing written" || bad "quiet tick: $(ev)"
SECONDS=1200; diag_tick 3
ev | grep -q '"ev":"wake","after":199' && ok "tick: a gap in the loop is a wake (sleep), with its length" || bad "wake: $(ev)"
TSIG="vpn: ts:"; CORE_STATE=off; CORE_PID=""; CORE_EXIT="1"; SECONDS=1201; diag_tick 4
ev | grep -q '"ev":"tunnels","value":"vpn: ts:"' && ok "tick: tunnel down" || bad "tunnels: $(ev)"
ev | grep -q '"ev":"core-stop","pid":100,"exit":1' && ok "tick: core stopped, with its exit" || bad "core stop: $(ev)"
CORE_STATE=on; CORE_PID=200; SECONDS=1202; diag_tick 5
ev | grep -q '"ev":"core-start","pid":200' && ok "tick: core started" || bad "core start: $(ev)"
CORE_PID=300; SECONDS=1203; diag_tick 6
ev | grep -q '"ev":"core-restart","from":200,"to":300' && ok "tick: core restarted (pid changed)" || bad "restart: $(ev)"
PROT=off; STANDBY=1; SECONDS=1204; diag_tick 7
ev | grep -q '"ev":"protection","value":"off"' && ev | grep -q '"ev":"standby","value":1' && ok "tick: protection and standby" || bad "prot: $(ev)"
: > "$EVENTS"; log_event 'core: Сервер -> "x" \ y'
ev | tail -1 | /usr/bin/perl -MJSON::PP -ne '$e = JSON::PP->new->decode($_); exit !($e->{ev} eq "log" && $e->{msg} eq q{core: Сервер -> "x" \ y})' &&
  ok "events.log lines go to the journal too, escaped" || bad "log event: $(ev | tail -1)"
ev | /usr/bin/perl -MJSON::PP -ne 'JSON::PP->new->decode($_)' && ok "events: JSON lines" || bad "events not JSON"
DIAG="$tmp/none"; log_event "no journal"; DIAG="$tmp/diag"
[ ! -e "$tmp/none" ] && ok "no diag folder (tests, old install): log_event still works" || bad "diag folder made by log_event"

# --- rotation: 7 days, about 50 MB, the access log by day
rm -rf "$DIAG"; diag_dir
old=$(date -r $((now - 8 * 86400)) +%Y%m%d%H%M); mid=$(date -r $((now - 3 * 86400)) +%Y%m%d%H%M)
echo x > "$DIAG/metrics-old.jsonl"; touch -t "$old" "$DIAG/metrics-old.jsonl"
echo x > "$DIAG/events-mid.jsonl"; touch -t "$mid" "$DIAG/events-mid.jsonl"
echo "yesterday.example" > "$DIAG/access.log"; touch -t "$(date -r $((now - 86400)) +%Y%m%d%H%M)" "$DIAG/access.log"
diag_tidy "$now"
[ ! -e "$DIAG/metrics-old.jsonl" ] && [ -e "$DIAG/events-mid.jsonl" ] && ok "tidy: older than 7 days removed, newer kept" || bad "tidy age: $(ls "$DIAG")"
yday=$(date -r $((now - 86400)) +%Y-%m-%d)
ls "$DIAG"/access-"$yday"*.log >/dev/null 2>&1 && [ ! -s "$DIAG/access.log" ] && [ -e "$DIAG/access.log" ] &&
  ok "tidy: yesterday's access log kept under its day, the open one emptied in place" || bad "access rotation: $(ls "$DIAG")"
[ "$(stat -f %Lp "$DIAG")" = 700 ] && ok "diag folder: owner only" || bad "diag mode $(stat -f %Lp "$DIAG")"
rm -rf "$DIAG"; diag_dir
DIAG_MAX=3000
for d in 5 4 3 2 1; do head -c 1000 /dev/zero > "$DIAG/metrics-d$d.jsonl"; touch -t "$(date -r $((now - d * 3600)) +%Y%m%d%H%M)" "$DIAG/metrics-d$d.jsonl"; done
diag_tidy "$now"
[ "$(cd "$DIAG" && ls metrics-* | paste -sd, -)" = "metrics-d1.jsonl,metrics-d2.jsonl,metrics-d3.jsonl" ] && ok "tidy: over the cap the oldest go first" ||
  bad "cap: $(ls "$DIAG")"
head -c 5000 /dev/zero > "$DIAG/access.log"
diag_tidy "$(date +%s)"
[ "$(cat "$DIAG"/* | wc -c | tr -d ' ')" -le 3000 ] && [ -e "$DIAG/access.log" ] && ok "tidy: a huge access log is cut, the folder under the cap" || bad "access cap: $(ls -l "$DIAG")"
DIAG_MAX=50000000

# --- ks set diag 0|1
rm -rf "$DIAG"; diag_dir
echo "a.example" > "$DIAG/access.log"; echo "b.example" > "$DIAG/access-2026-10-10.log"
core_apply_settings() { echo applied >> "$tmp/applied"; }
echo core=xray > "$SETTINGS"
set_diag 0 && [ -z "$(ls "$DIAG"/access* 2>/dev/null)" ] && ok "set diag 0: the recorded connections are deleted" || bad "diag 0: $(ls "$DIAG")"
grep -qx diag=0 "$SETTINGS" && [ "$(cat "$tmp/applied")" = applied ] && ok "set diag 0: stored, the core's config follows" || bad "diag 0 setting"
rm -rf "$DIAG"; set_diag 1 && [ -d "$DIAG" ] && grep -qx diag=1 "$SETTINGS" && ok "set diag 1: folder made before the config names it" || bad "diag 1"
echo core=mihomo > "$SETTINGS"; : > "$tmp/applied"
set_diag 1 && [ ! -s "$tmp/applied" ] && ok "set diag with mihomo: nothing to rebuild" || bad "mihomo diag"
set_diag verbose 2>/dev/null && bad "set diag verbose taken" || ok "set diag: 0 or 1 only"
rm -f "$SETTINGS"

# --- «Собрать отчёт»: ks diag report <dir>, one redacted archive
rm -rf "$DIAG"; diag_dir
INVALIDF="$tmp/invalid"; FLAG="$tmp/disabled"
printf 'core=xray\nxrayserver=🇱🇹Литва\ndiag=1\n' > "$SETTINGS"
printf '203.0.113.10\n203.0.113.41\n' > "$SERVERS"; printf '203.0.113.10\n203.0.113.41\n' > "$SERVERS_CORE"; : > "$SERVERS_MANUAL"
printf 'lt.example.com\t203.0.113.41\n' > "$PINS"; echo lt.example.com > "$APPROVED_HOSTS"
cat > "$EVENTS" <<'XEOF'
2026-10-11 14:00:00 server addresses changed: lt.example.com 203.0.113.40 -> 203.0.113.41
2026-10-11 14:01:00 fetched https://sub.example.org/api/sub/Zx81kq0 for 00000000-0000-4000-8000-000000000001
2026-10-11 14:02:00 core on
XEOF
printf 'dial tcp 203.0.113.10:443 via sni.hidden.example: key Z84J2Iel0123abcdQWERTYxyz9\n' > "$CORE_DIR/core.log"
printf '[{"remarks":"LT","outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"lt.example.com"}]},
  "streamSettings":{"security":"reality","realitySettings":{"serverName":"sni.hidden.example"}}}]}]\n' > "$CORE_DIR/profile-xray.json"
for f in xray.json config.yaml profile.json; do echo secret > "$CORE_DIR/$f"; done
echo '{"version":1,"added":[{"kind":"pinning","items":[{"host":"lt.example.com","address":"203.0.113.41"}]}]}' > "$REPORT"
echo '{"t":"x","ev":"wake","after":120}' > "$DIAG/events-2026-10-11.jsonl"
echo '{"t":"x","v":"0","server":"🇱🇹Литва"}' > "$DIAG/metrics-2026-10-11.jsonl"
echo '2026/10/11 14:38:44 from 127.0.0.1:59995 accepted tcp:www.youtube.com:443 [ks-tun >> LT_1]' > "$DIAG/access.log"
mkdir -p "$tmp/crash"
echo '{"procName":"xray"}' > "$tmp/crash/xray-2026-10-10-120000.ips"
echo '{"procName":"KillSwitch"}' > "$tmp/crash/KillSwitch-2026-10-10-120000.ips"
echo '{"procName":"Safari"}' > "$tmp/crash/Safari-2026-10-10-120000.ips"
echo '{"procName":"mihomo"}' > "$tmp/crash/mihomo-2026-09-01-120000.ips"; touch -t "$(date -r $(($(date +%s) - 10 * 86400)) +%Y%m%d%H%M)" "$tmp/crash/mihomo-2026-09-01-120000.ips"
# planted by the user to make root copy a root-only file into the archive (core/ is 711)
echo 'root only secret' > "$tmp/secret"; chmod 600 "$tmp/secret"
ln "$tmp/secret" "$tmp/crash/xray-2026-10-10-130000.ips"
ln -s "$tmp/secret" "$tmp/crash/KillSwitch-2026-10-10-130000.ips"
mkfifo "$tmp/crash/mihomo-2026-10-10-130000.ips"
# the real list: the system's folder (root's files), then the caller's own (read as the caller)
crash_list=$(diag_crash_dirs "$EUID")
[ "$(head -1 <<<"$crash_list")" = "0 /Library/Logs/DiagnosticReports" ] && ok "crash folders: the system's, read as root's files" ||
  bad "crash dirs: $crash_list"
if [ "$EUID" -ge 500 ]; then
  [[ "$(sed -n 2p <<<"$crash_list")" == "$EUID /"*/Library/Logs/DiagnosticReports ]] && ok "crash folders: the caller's own, under its uid" ||
    bad "crash dirs (caller): $crash_list"
fi
[ "$(diag_crash_dirs 0 | wc -l | tr -d ' ')" = 1 ] && ok "crash folders: no user's folder for root" || bad "root crash dirs: $(diag_crash_dirs 0)"
diag_crash_read "$EUID" "$tmp/crash/xray-2026-10-10-120000.ips" | grep -q procName && ok "crash read: a regular file of its owner" ||
  bad "crash read refused a plain file"
diag_crash_read "$EUID" "$tmp/crash/xray-2026-10-10-130000.ips" >/dev/null 2>&1 && bad "crash read: hard link read" ||
  ok "crash read: refuses a hard link (another name of someone's file)"
diag_crash_read "$EUID" "$tmp/crash/KillSwitch-2026-10-10-130000.ips" >/dev/null 2>&1 && bad "crash read: symlink followed" ||
  ok "crash read: refuses a symlink (swapped in after the listing)"
diag_crash_read 0 "$tmp/crash/xray-2026-10-10-120000.ips" >/dev/null 2>&1 && bad "crash read: file of another owner" ||
  ok "crash read: refuses a file of another owner"
diag_crash_dirs() { echo "$EUID $tmp/crash"; echo "$EUID $tmp/no-such-dir"; }
launchctl() { return 1; }
# addresses no list knows any more: an old server in the rules, routes and logs
pfctl() { [ "$*" = "-a $ANCHOR -s rules" ] && echo 'pass out quick inet from any to 192.0.2.55 flags S/SA keep state'; return 0; }
netstat() { printf 'default 192.168.1.1 UGScg en0\n192.0.2.55 link#4 UHWIi utun9\n198.18.0.1 198.18.0.1 UH utun7\n'; }
printf '2026-10-11 13:00:00 server addresses changed: old.example 198.51.100.7 -> 198.51.100.8\n' >> "$EVENTS"
printf 'connect 198.51.100.7:443 [2001:db8:1::5]:443 dns 1.1.1.1 lan 10.0.0.1 tun 198.18.0.1 lo ::1 ll fe80::1%%en0 ts 100.100.100.100 at 14:38:44 in Foo::bar\n' > "$CORE_DIR/core.log.1"
echo '2026/10/11 14:38:45 from 127.0.0.1:59996 accepted tcp:93.184.216.34:443 [ks-tun >> LT_1]' >> "$DIAG/access.log"
core_job() { CORE_RUN=0; CORE_PID=""; }
mkdir -m 755 "$tmp/out"
out=$(diag_report "$tmp/out" 2>"$tmp/err") || bad "report failed: $(cat "$tmp/err")"
[[ "$out" =~ ^$tmp/out/KillSwitch-report-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.tar\.gz$ ]] && [ -f "$out" ] &&
  ok "report: KillSwitch-report-YYYY-MM-DD-HHMM.tar.gz in the folder, path printed" || bad "report path: $out $(cat "$tmp/err")"
mkdir "$tmp/x"; tar -xzf "$out" -C "$tmp/x" 2>/dev/null
r=$(echo "$tmp"/x/KillSwitch-report-*)
names=$(cd "$r" && find . -type f | sed 's|^\./||' | sort | paste -sd' ' -)
for f in events.log settings core.log core.log.1 routing.json status.txt versions.txt network.txt diag/access.log diag/events-2026-10-11.jsonl \
         diag/metrics-2026-10-11.jsonl crash/xray-2026-10-10-120000.ips crash/KillSwitch-2026-10-10-120000.ips; do
  [ -f "$r/$f" ] || bad "report lacks $f ($names)"
done
ok "report: journal, logs, settings, state, versions, network, crash reports"
[[ " $names " == *Safari* || " $names " == *mihomo-2026-09-01* ]] && bad "report: other programs' or old crash reports: $names" ||
  ok "report: only our programs' crash reports of the last 7 days"
[[ " $names " =~ (profile|xray\.json|config\.yaml|pins) ]] && bad "report holds the profile, config or pins: $names" ||
  ok "report: no profile, config or pins"
grep -rqE '203\.0\.113|lt\.example\.com|sni\.hidden\.example' "$r" && bad "report holds a server address: $(grep -rE '203\.0\.113|example\.com|hidden' "$r" | head -3)" ||
  ok "report: server addresses and names masked"
grep -rq 'server-1' "$r/events.log" && grep -q 'server-1' "$r/routing.json" && [ "$(grep -o 'server-[0-9]*' "$r/events.log" | sort -u | wc -l | tr -d ' ')" -ge 1 ] &&
  ok "report: masked as stable placeholders (server-N)" || bad "placeholders: $(cat "$r/events.log")"
grep -rqE 'sub\.example\.org|00000000-0000-4000|Z84J2Iel' "$r" && bad "report holds a link, uuid or key: $(grep -rE 'sub\.example|00000000|Z84J' "$r" | head -3)" ||
  ok "report: links, uuids and keys masked"
grep -rq 'root only secret' "$r" && bad "report holds a file planted by link: $names" || ok "report: no hard-linked or symlinked crash file"
[ "$(cat "$r/crash/xray-2026-10-10-120000.ips")" = '{"procName":"xray"}' ] && ok "report: crash report copied whole" || bad "crash copy: $(cat "$r/crash/xray-2026-10-10-120000.ips")"
grep -rqE '198\.51\.100|192\.0\.2\.55|2001:db8:1::5|93\.184\.216' "$r" && bad "report holds a public address: $(grep -rE '198\.51\.100|192\.0\.2\.55|2001:db8|93\.184' "$r" | head -4)" ||
  ok "report: public addresses no list knows (old servers, rules, routes) masked"
t=$(grep -o 'connect ip-[0-9]*' "$r/core.log.1" | cut -d' ' -f2)
[ -n "$t" ] && grep -q "$t" "$r/events.log" && ok "report: one address, one stable ip-N token in every file" || bad "ip tokens: $(cat "$r/core.log.1") / $(cat "$r/events.log")"
grep -q 'pass out quick inet from any to ip-[0-9]' "$r/status.txt" && grep -q '^ip-[0-9]* link#4' "$r/network.txt" &&
  ok "report: pf rules and routes keep their shape" || bad "status/network: $(cat "$r/status.txt" "$r/network.txt")"
for keep in '1.1.1.1' 'lan 10.0.0.1' 'tun 198.18.0.1' 'lo ::1' 'fe80::1%en0' 'ts 100.100.100.100' 'at 14:38:44' 'Foo::bar'; do
  grep -qF "$keep" "$r/core.log.1" || bad "report masked what may stay ($keep): $(cat "$r/core.log.1")"
done
grep -q 'default 192.168.1.1' "$r/network.txt" && grep -q 'from 127.0.0.1:59996' "$r/diag/access.log" &&
  ok "report: loopback, LAN, our TUN, Tailscale, link-local and our DNS stay readable" || bad "kept: $(cat "$r/network.txt")"
grep -q 'www.youtube.com' "$r/diag/access.log" && ok "report: visited domains kept (only recorded with diag=1)" || bad "access log: $(cat "$r/diag/access.log")"
grep -q '🇱🇹Литва' "$r/settings" && ok "report: server names (not addresses) kept" || bad "settings: $(cat "$r/settings")"
grep -q "$KS_VERSION" "$r/versions.txt" && ok "report: versions" || bad "versions: $(cat "$r/versions.txt")"
SUDO_UID=$EUID diag_report "$tmp/out" 0 >/dev/null 2>&1 && bad "report through sudo for another uid" ||
  ok "report: through sudo, crash reports only of the user who ran it"
chmod 777 "$tmp/out"
diag_report "$tmp/out" >/dev/null 2>&1 && bad "report into a folder others can write" || ok "report: refuses a folder others can write (root would write there)"
diag_report relative >/dev/null 2>&1 && bad "report into a relative path" || ok "report: absolute folders only"
rm -f "$SETTINGS"

# --- passwordless: the app's button, from the daemon or sudo
passwordless_args_ok diag report /Users/me/Desktop && ok "args: diag report <dir>" || bad "args: diag report refused"
passwordless_args_ok diag report relative && bad "args: relative dir" || ok "args: refuses a relative dir"
passwordless_args_ok diag report /a /b && bad "args: two dirs" || ok "args: refuses extra arguments"
passwordless_args_ok diag report /a 501 && ok "args: diag report <dir> <uid> (the daemon's caller)" || bad "args: uid refused"
passwordless_args_ok diag report /a 5x1 && bad "args: uid not a number" || ok "args: refuses a uid that is not a number"
passwordless_args_ok diag report $'/a\nb' && bad "args: newline" || ok "args: refuses control characters"
passwordless_args_ok diag && bad "args: diag alone" || ok "args: refuses diag without report"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
