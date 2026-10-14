#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks and Helper/install.sh
# The in-place upgrade of an installed helper (ADR 0012): files are replaced by rename, the
# watchdog takes the new code without its shutdown guard (which turns the network off), pf is
# never flushed, the core restarts only when its binary changed, and an older helper is never put
# over a newer one. Everything runs against fakes in a temporary directory: nothing as root, no
# launchctl, pfctl or networksetup of the system.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

# ===== ks watch: SIGHUP re-execs the (new) helper in place; SIGTERM still runs the guard =====
watch_run() {  # watch_run <signal>: starts the watchdog loop on fakes, sends the signal, reports
  local d="$tmp/w-$1"
  mkdir -p "$d"
  (
    # shellcheck source=../ks
    . "$here/../ks"
    DIR="$d"; FLAG="$d/disabled"; SETTINGS="$d/settings"; EVENTS="$d/events.log"; STATEF="$d/daemon-state"; NB_PLIST="$d/none"
    WIFI_MARK="$d/wifi-off-by-ks"
    printf '#!/bin/bash\necho "$*" > %s/execd\n' "$d" > "$d/new-ks"; chmod +x "$d/new-ks"
    KS_SELF="$d/new-ks"
    watch_pass() { echo pass >> "$d/passes"; }
    launchctl() { return 1; }   # not disabled
    networksetup() {
      case "$1" in
        -listnetworkserviceorder) printf '(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n' ;;
        *) echo "networksetup $*" >> "$d/net" ;;
      esac
    }
    pfctl() { echo "pfctl $*" >> "$d/pf"; }
    watch_main
  ) &
  local pid=$!
  for _ in $(seq 1 50); do [ -s "$d/passes" ] && break; sleep 0.1; done
  kill "-$1" "$pid"
  wait "$pid" 2>/dev/null
}
watch_run HUP
d="$tmp/w-HUP"
check "HUP: the watchdog execs the helper on disk with 'watch'" "$(cat "$d/execd" 2>/dev/null)" "watch"
check "HUP: no network service turned off" "$(cat "$d/net" 2>/dev/null)" ""
check "HUP: no boot window mark" "$([ -e "$d/wifi-off-by-ks" ] && echo there || echo none)" none
check "HUP: pf untouched" "$(cat "$d/pf" 2>/dev/null)" ""
grep -q 'new helper' "$d/events.log" 2>/dev/null && check "HUP: logged" yes yes || check "HUP: logged" no yes
watch_run TERM
d="$tmp/w-TERM"
check "(control) TERM: the shutdown guard turns the network off" "$(cat "$d/net" 2>/dev/null)" "networksetup -setnetworkserviceenabled Wi-Fi off"
check "(control) TERM: no exec" "$([ -e "$d/execd" ] && echo execd || echo none)" none

# ===== ks _regen: a new generator's config goes in by hot reload, pf is reloaded, never flushed =====
regen() {  # regen <same|different>: prints what was called
  local d="$tmp/r-$1"
  mkdir -p "$d/core"
  (
    # shellcheck source=../ks
    . "$here/../ks"
    DIR="$d"; CORE_DIR="$d/core"; EVENTS="$d/events.log"; SETTINGS="$d/settings"; CORE_PROFILE="$d/core/profile.json"; PINS="$d/core/pins"
    SERVERS_CORE="$d/servers-core"; SERVERS_MANUAL="$d/servers-manual"; CORE_EGRESS="$d/core/egress"; REPORT="$d/core/routing.json"
    echo '{}' > "$CORE_PROFILE"; : > "$PINS"; echo old > "$CORE_DIR/config.yaml"; echo rules > "$CORE_EGRESS"
    mode=$1
    core_generate() {
      case "$mode" in same|egress) echo old > "$2" ;; *) echo new > "$2" ;; esac
      : > "$2.pins"; : > "$3"; echo report > "$2.report"
      if [ "$mode" = egress ]; then : > "$2.egress"; else echo rules > "$2.egress"; fi
    }
    core_commit() { echo commit; mv "$1" "$CORE_DIR/config.yaml"; }
    loaded() { return 0; }
    load() { echo load; }
    core_reload() { echo core_reload; }
    pfctl() { echo "pfctl $*"; }
    launchctl() { echo "launchctl $*"; }
    core_regen
    echo "config=$(cat "$CORE_DIR/config.yaml")"
  )
}
out=$(regen same)
check "_regen, same output: nothing reloaded" "$(grep -cE '^(commit|load|core_reload|launchctl)' <<<"$out")" 0
check "_regen, same output: says so" "$(grep -c 'core config: kept' <<<"$out")" 1
check "_regen, same output: the report written" "$(cat "$tmp/r-same/core/routing.json")" report
out=$(regen egress)
check "_regen, same config but the core's egress changed: pf reloaded, the core not" "$(grep -E '^(commit|load|core_reload)$' <<<"$out" | paste -sd, -)" "load"
check "_regen, egress changed: written" "$(wc -c < "$tmp/r-egress/core/egress" | tr -d ' ')" 0
out=$(regen different)
check "_regen, new output: committed, pf and core reloaded in place" "$(grep -E '^(commit|load|core_reload)$' <<<"$out" | paste -sd, -)" "commit,load,core_reload"
check "_regen: pf never flushed, the core never restarted" "$(grep -cE 'pfctl .*-F|kickstart|bootout' <<<"$out")" 0
check "_regen: config in place" "$(grep '^config=' <<<"$out")" "config=new"

# ===== install.sh --upgrade on fakes =====
# A fake system: /Library/KillSwitch is $root/lib, the bundle's Helper/ is $root/bundle.
pin_bundle() {  # pin_bundle <geosite text> <geoip text> [geoip.dat text]: the bundle's fetch-geodata.sh pins these contents
  local s i d
  s=$(printf '%s\n' "$1" | shasum -a 256 | cut -d' ' -f1); i=$(printf '%s\n' "$2" | shasum -a 256 | cut -d' ' -f1)
  d=$(printf '%s\n' "${3:-ipdat}" | shasum -a 256 | cut -d' ' -f1)
  sed -e "s/^SHA256_GEOSITE=\"[0-9a-f]*\"/SHA256_GEOSITE=\"$s\"/" -e "s/^SHA256_GEOIP=\"[0-9a-f]*\"/SHA256_GEOIP=\"$i\"/" \
    -e "s/^SHA256_GEOIP_DAT=\"[0-9a-f]*\"/SHA256_GEOIP_DAT=\"$d\"/" "$here/../fetch-geodata.sh" > "$root/bundle/fetch-geodata.sh"
}
setup() {  # setup <name>: a fresh installed system and bundle
  root="$tmp/i-$1"
  mkdir -p "$root/lib/core" "$root/bundle" "$root/ld"
  printf '#!/bin/bash -p\nKS_VERSION="0.13"\necho old\n' > "$root/lib/ks"
  printf '#!/bin/bash -p\nKS_VERSION="0.14"\necho new\n' > "$root/bundle/ks"
  echo relays > "$root/bundle/tsrelays"; echo relays > "$root/lib/tsrelays"
  echo core-1 > "$root/bundle/mihomo"; echo core-1 > "$root/lib/core/mihomo"
  echo site > "$root/bundle/geosite.dat"; echo site > "$root/lib/core/geosite.dat"
  echo ip > "$root/bundle/geoip.metadb"; echo ip > "$root/lib/core/geoip.metadb"
  pin_bundle site ip
  echo cfg > "$root/lib/core/config.yaml"
  echo server=x > "$root/lib/core/failover"; echo x > "$root/lib/core/failover-refused"   # 0.19's failover state
  cp "$here/../local.killswitch.plist" "$here/../local.killswitch.core.plist" "$root/bundle/"
  cp "$here/../local.killswitch.plist" "$root/ld/local.killswitch.plist"
  cp "$here/../local.killswitch.core.plist" "$root/ld/local.killswitch.core.plist"
  printf 'lan=0\ncoredirect=1\nfailover=1\nadblock=1\n' > "$root/lib/settings"
  # the running watchdog is a 0.19 one (no vpn= line), protection off: our anchor is empty
  printf 'pid=1\nprotection=off\ncore=on\ntunnels=vpn:utun9 ts:\nstandby=0\n' > "$root/lib/daemon-state"
  : > "$root/anchor"
  : > "$root/calls"; : > "$root/restarts"
}
upgrade() {  # upgrade [args]: runs main of install.sh in the bundle directory on the fakes
  (
    cd "$root/bundle" || exit 1
    # shellcheck source=../install.sh
    . "$here/../install.sh"
    [ "${KEEP_E:-0}" = 1 ] || set +e   # KEEP_E=1: main under install.sh's own set -e, as for real
    DIR="$root/lib"; SUDOERS="$root/sudoers"
    WATCH_PLIST="$root/ld/local.killswitch.plist"; CORE_PLIST="$root/ld/local.killswitch.core.plist"
    eval "$(sed -n '/^sudoers_text() {/,/^}/p' "$here/../install.sh")"
    [ -e "$SUDOERS" ] || sudoers_text someone /Library/KillSwitch/ks > "$SUDOERS"
    # install(1) without the owner flags (no root here)
    install() {
      local a=() d=0
      while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; -m) a+=("$1" "$2"); shift 2 ;; -d) d=1; shift ;; *) a+=("$1"); shift ;; esac; done
      if [ "$d" = 1 ]; then mkdir -p "${a[@]: -1}"; else /usr/bin/install "${a[@]}"; fi
    }
    sync() { echo "sync" >> "$root/calls"; }
    # The watchdog: the HUP'd (or new) one is the new helper's once TAKEOVER (default 0) sleeps have
    # passed; until then it is the 0.19 one, which flushes our rules while protection is off.
    # "never": it never takes over. The new one loads the rules and says so in daemon-state.
    watchdog_new() {
      echo rules > "$root/anchor"; rm -f "$root/takeover"
      printf 'pid=1\nprotection=off\ncore=on\ntunnels=vpn:utun9 ts:\nstandby=0\nvpn=%s\nblocking=1\n' \
        "$([ -e "$root/lib/vpn-on" ] && echo 1 || echo 0)" > "$root/lib/daemon-state"
      echo "watchdog: new" >> "$root/calls"
    }
    watchdog_start() { if [ "${TAKEOVER:-0}" = 0 ]; then watchdog_new; else echo "$TAKEOVER" > "$root/takeover"; fi; }
    sleep() {
      local n
      [ -f "$root/takeover" ] || return 0
      n=$(cat "$root/takeover"); : > "$root/anchor"
      [ "$n" = never ] && return 0
      if [ "$n" -le 1 ]; then watchdog_new; else echo $((n - 1)) > "$root/takeover"; fi
    }
    pf_now() { if [ -s "$root/anchor" ]; then echo rules; else echo empty; fi; }
    launchctl() {
      echo "launchctl $*" >> "$root/calls"
      case "$*" in
        "kill HUP system/local.killswitch") watchdog_start ;;
        "bootstrap system $WATCH_PLIST") watchdog_start ;;
        "bootout system/local.killswitch") rm -f "$root/lib/daemon-state" ;;
        kickstart*core|"bootout system/local.killswitch.core"|"bootstrap system $CORE_PLIST") echo "launchctl $1 anchor=$(pf_now)" >> "$root/restarts" ;;
      esac
      # the core's job: loaded, unloaded, or unloading:<prints left> after a slow bootout (SLOW_BOOTOUT=1:
      # launchd returns from bootout before the job is gone, and refuses a bootstrap meanwhile)
      local st n
      if [ -f "$root/core-job" ]; then st=$(cat "$root/core-job"); elif [ "${CORE_LOADED:-1}" = 1 ]; then st=loaded; else st=unloaded; fi
      case "$1" in
        print) [[ "$2" == *core ]] || return 0
               case "$st" in
                 loaded) echo 'state = running' ;;
                 waiting) echo 'state = waiting' ;;
                 unloading:*) n=${st#unloading:}
                              if [ "$n" -gt 0 ]; then echo "unloading:$((n - 1))" > "$root/core-job"; echo 'state = running'
                              else echo unloaded > "$root/core-job"; return 1; fi ;;
                 *) return 1 ;;
               esac ;;
        bootout) [[ "$2" == *core ]] || return 0
                 if [ "${SLOW_BOOTOUT:-0}" = 1 ]; then echo unloading:2 > "$root/core-job"; else echo unloaded > "$root/core-job"; fi ;;
        bootstrap) [[ "$3" == *core* ]] || return 0
                   case "$st" in unloading:0|unloaded) echo loaded > "$root/core-job" ;;
                     *) echo "Bootstrap failed: 37: Operation already in progress" >&2; return 37 ;; esac ;;
        print-disabled) [ "${CORE_DISABLED:-0}" = 1 ] && printf '\t"local.killswitch.core" => disabled\n'; return 0 ;;
      esac
    }
    ks_run() {
      echo "ks $*" >> "$root/calls"; [ "$1" = state ] && echo on
      [ "$1" = _regen ] && echo "ks _regen anchor=$(pf_now)" >> "$root/restarts" && echo "core config: kept"; return 0
    }
    lockf() { echo "lockf $*" >> "$root/calls"; }
    dscl() { return 0; }
    sudo() { echo "sudo $*" >> "$root/calls"; [ "${SUDO_FAILS:-0}" = 0 ]; }
    visudo() { [ "${VISUDO_FAILS:-0}" = 0 ] || return 1; /usr/sbin/visudo "$@"; }
    chmod() { /bin/chmod "$@"; }
    id() { if [ "$1" = -u ] && [ -n "${2:-}" ]; then echo 501; else /usr/bin/id "$@"; fi; }
    pfctl() { echo "pfctl $*" >> "$root/calls"; }
    networksetup() { echo "networksetup $*" >> "$root/calls"; }
    main "$@"
  )
}
calls() { cat "$root/calls"; }

setup plain
exec 3< "$root/lib/ks"   # the running watchdog's bash keeps reading the file it started with
ino=$(stat -f %i "$root/lib/ks")
out=$(upgrade --upgrade 2>&1); rc=$?
check "upgrade: succeeds" "$rc" 0
check "upgrade: the new ks is in place" "$(tail -1 "$root/lib/ks")" "echo new"
[ "$(stat -f %i "$root/lib/ks")" != "$ino" ] && check "upgrade: ks replaced by rename (new inode)" yes yes || check "upgrade: ks replaced by rename (new inode)" no yes
check "upgrade: the old file's readers still see the old one" "$(tail -1 <&3)" "echo old"
exec 3<&-
check "upgrade: written to disk before the rename (ks, and the mihomo job kept in core/ the first time)" "$(grep -c '^sync$' "$root/calls")" 2
check "upgrade: no temporary file left" "$(find "$root/lib" "$root/ld" -name '.*.new' | wc -l | tr -d ' ')" 0
check "upgrade: watchdog gets SIGHUP" "$(grep -c '^launchctl kill HUP system/local.killswitch$' "$root/calls")" 1
check "upgrade: watchdog never booted out" "$(grep -c 'bootout system/local.killswitch$' "$root/calls")" 0
check "upgrade: core not restarted (same binary)" "$(grep -cE 'kickstart|bootout system/local.killswitch.core' "$root/calls")" 0
check "upgrade: protection state left alone (no ks on/off)" "$(grep -cE '^ks (on|off|pause)' "$root/calls")" 0
check "upgrade: the core config regenerated under the lock" "$(grep -c '^ks _regen$' "$root/calls")" 1
check "upgrade: pf and the network never touched" "$(grep -cE '^(pfctl|networksetup)' "$root/calls")" 0
check "upgrade: says the core kept running" "$(grep -c '^core: kept$' <<<"$out")" 1
check "upgrade: sudoers kept for the same user" "$(grep -c '^someone ALL=(root) NOPASSWD:' "$root/sudoers")" 1
check "upgrade: settings kept, coredirect (ADR 0013) and failover (ADR 0036) dropped" "$(paste -sd, - < "$root/lib/settings")" "lan=0,adblock=1"
check "upgrade: the old failover state gone (ADR 0036)" "$(ls "$root/lib/core" | grep -c '^failover')" 0

check "upgrade: the completion marker names the new ks" "$(sed -n 's/^sha256 //p' "$root/lib/installed" 2>/dev/null)" "$(shasum -a 256 "$root/lib/ks" | cut -d' ' -f1)"
check "upgrade: the marker says the version" "$(sed -n 's/^version //p' "$root/lib/installed" 2>/dev/null)" "0.14"
check "upgrade: the marker is 644" "$(stat -f %Lp "$root/lib/installed" 2>/dev/null)" 644

# install.sh stopping half-way (here: sudoers refused) leaves no marker, not even an earlier one
setup halfway
echo "version 0.14" > "$root/lib/installed"
out=$(KEEP_E=1 VISUDO_FAILS=1 upgrade --upgrade 2>&1); rc=$?
check "stopped half-way: fails" "$([ "$rc" != 0 ] && echo failed || echo ok)" failed
check "stopped half-way: ks already replaced" "$(tail -1 "$root/lib/ks")" "echo new"
check "stopped half-way: no completion marker" "$([ -e "$root/lib/installed" ] && echo there || echo none)" none
check "stopped half-way: says where on stderr, not silently" "$(grep -cE '^install\.sh:[0-9]+: exit 1$' <<<"$out")" 1

# the user's passwordless ks, the last check: a failure says so and fails the install
setup noaccess
out=$(KEEP_E=1 SUDO_FAILS=1 upgrade --upgrade 2>&1); rc=$?
check "no app access: fails" "$rc" 1
check "no app access: says so" "$(grep -c '^app access: failed' <<<"$out")" 1
check "no app access: no completion marker" "$([ -e "$root/lib/installed" ] && echo there || echo none)" none

setup onlycoredirect
printf 'coredirect=1\n' > "$root/lib/settings"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "settings with only coredirect: upgrade succeeds under set -e" "$rc" 0
check "settings with only coredirect: emptied" "$(wc -c < "$root/lib/settings" | tr -d ' ')" 0
check "settings with only coredirect: the rest of the install ran" "$(grep -c '^launchctl kill HUP system/local.killswitch$' "$root/calls")" 1

setup strict
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "upgrade under set -e: succeeds" "$rc" 0
check "upgrade under set -e: no error line on the way" "$(grep -c '^install\.sh:' <<<"$out")" 0

setup again
upgrade --upgrade >/dev/null 2>&1
: > "$root/calls"
upgrade --upgrade >/dev/null 2>&1
check "second upgrade, nothing new: watchdog left alone" "$(grep -cE 'launchctl (kill|bootout|bootstrap|kickstart)' "$root/calls")" 0

setup core
echo core-2 > "$root/bundle/mihomo"
out=$(upgrade --upgrade 2>&1)
check "new core binary: in place" "$(cat "$root/lib/core/mihomo")" core-2
check "new core binary: core restarted once, in place" "$(grep -c '^launchctl kickstart -k system/local.killswitch.core$' "$root/calls")" 1
check "new core binary: says so" "$(grep -c '^core: restarted$' <<<"$out")" 1
check "new core binary: pf and the network never touched" "$(grep -cE '^(pfctl|networksetup)' "$root/calls")" 0

# --- geodata (#27): the bundle's files only if they are the pinned ones; the old file stays otherwise
geo() { awk -F= -v k="$1" '$1 == k { print $2 }' "$root/lib/core/geodata"; }
setup geonew
echo site-2 > "$root/bundle/geosite.dat"; pin_bundle site-2 ip
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "new pinned geosite: installed" "$rc $(cat "$root/lib/core/geosite.dat")" "0 site-2"
check "new pinned geosite: core restarted" "$(grep -c '^core: restarted$' <<<"$out")" 1
check "geodata state: both files fine" "$(geo geosite.dat) $(geo geoip.metadb)" "ok ok"
check "geodata state: readable by the app" "$(stat -f %Lp "$root/lib/core/geodata")" 644
setup geobad
echo tampered > "$root/bundle/geosite.dat"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "geosite not the pinned one: the install still succeeds" "$rc" 0
check "  the old geosite stays" "$(cat "$root/lib/core/geosite.dat")" site
check "  said on stderr, per file" "$(grep -c '^geosite.dat: ' <<<"$out")" 1
check "  geodata state names the file" "$(geo geosite.dat) $(geo geoip.metadb)" "mismatch ok"
check "  core not restarted for it" "$(grep -c '^core: restarted$' <<<"$out")" 0
setup geonopin
rm "$root/bundle/fetch-geodata.sh"; echo ip-2 > "$root/bundle/geoip.metadb"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "no pin in the bundle: nothing replaced, install succeeds" "$rc $(cat "$root/lib/core/geoip.metadb")" "0 ip"
check "  geodata state" "$(geo geosite.dat) $(geo geoip.metadb)" "unpinned unpinned"

# --- Xray (ADR 0020): shipped next to mihomo; an install that runs mihomo keeps it, a new one gets Xray
xray_bundle() {
  echo xray-1 > "$root/bundle/xray"; echo ipdat > "$root/bundle/geoip.dat"
  cp "$here/../local.killswitch.core.xray.plist" "$root/bundle/"
}
setup xrayup
xray_bundle
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "xray in the bundle: upgrade succeeds" "$rc" 0
check "  binary and geoip.dat in place" "$(cat "$root/lib/core/xray" 2>&1) $(cat "$root/lib/core/geoip.dat" 2>&1)" "xray-1 ipdat"
check "  geodata state has geoip.dat" "$(geo geoip.dat)" ok
check "  both jobs kept in core/ for ks set core" \
  "$(cmp -s "$root/lib/core/plist.mihomo" "$here/../local.killswitch.core.plist" && cmp -s "$root/lib/core/plist.xray" "$here/../local.killswitch.core.xray.plist" && echo yes)" yes
check "  an install with a mihomo config keeps mihomo" "$(grep -c '^core=' "$root/lib/settings") $(cmp -s "$root/ld/local.killswitch.core.plist" "$here/../local.killswitch.core.plist" && echo mihomo-job)" "0 mihomo-job"
setup xraynew
xray_bundle
rm -f "$root/lib/core/config.yaml" "$root/lib/core/mihomo"
KEEP_E=1 upgrade --upgrade >/dev/null 2>&1
check "no core config yet: Xray chosen, its job installed" \
  "$(grep '^core=' "$root/lib/settings") $(cmp -s "$root/ld/local.killswitch.core.plist" "$here/../local.killswitch.core.xray.plist" && echo xray-job)" "core=xray xray-job"
KEEP_E=1 upgrade --upgrade >/dev/null 2>&1
check "  a second run keeps it (one line)" "$(grep -c '^core=' "$root/lib/settings")" 1
setup xraychosen
xray_bundle
printf 'core=xray\n' >> "$root/lib/settings"; echo '{}' > "$root/lib/core/xray.json"
KEEP_E=1 upgrade --upgrade >/dev/null 2>&1
check "core=xray: its job, its config rebuilt" \
  "$(cmp -s "$root/ld/local.killswitch.core.plist" "$here/../local.killswitch.core.xray.plist" && echo xray-job) $(grep -c '^ks _regen' "$root/calls")" "xray-job 1"

# "ks set core xray" while mihomo runs: mihomo keeps the VPN until the Xray subscription is imported
# and "ks core on" swaps the job; an upgrade meanwhile must not start Xray without its config
setup xraypending
xray_bundle
printf 'core=xray\n' >> "$root/lib/settings"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "core=xray chosen, its config not yet imported, mihomo running: upgrade succeeds" "$rc" 0
check "  the running mihomo job stays" "$(cmp -s "$root/ld/local.killswitch.core.plist" "$here/../local.killswitch.core.plist" && echo mihomo-job)" mihomo-job
check "  the core not restarted" "$(grep -cE 'kickstart|(bootout|bootstrap) .*core' "$root/calls")" 0

setup coreoff
echo core-2 > "$root/bundle/mihomo"
CORE_LOADED=0 upgrade --upgrade >/dev/null 2>&1
check "core not loaded: not started by the upgrade" "$(grep -cE 'kickstart|bootstrap system .*core' "$root/calls")" 0

setup plist
echo '<!-- changed -->' >> "$root/bundle/local.killswitch.plist"
upgrade --upgrade >/dev/null 2>&1
seq_=$(grep -E 'launchctl (disable|bootout|enable|bootstrap) .*local.killswitch(\.plist)?$' "$root/calls" | awk '{print $2}' | paste -sd, -)
check "new watchdog plist: marked disabled around the bootout (no network-off guard)" "$seq_" "disable,bootout,enable,bootstrap"

# a new core job: launchd returns from bootout before the old job is gone and refuses a bootstrap
# until then; the core must not be left unloaded (the VPN down, and a rerun would say "kept")
setup coreplist
echo '<!-- changed -->' >> "$root/bundle/local.killswitch.core.plist"
out=$(KEEP_E=1 SLOW_BOOTOUT=1 upgrade --upgrade 2>&1); rc=$?
check "new core plist, slow bootout: upgrade succeeds" "$rc" 0
check "  the core's job loaded again" "$(cat "$root/core-job" 2>/dev/null)" loaded
check "  says the core restarted" "$(grep -c '^core: restarted$' <<<"$out")" 1
check "  completion marker written" "$([ -e "$root/lib/installed" ] && echo there || echo none)" there

# ===== ADR 0035: the VPN on (a running 0.19 core counts) keeps pf blocking through the upgrade =====
restarts_open() { grep -c 'anchor=empty' "$root/restarts"; }
setup vpnmigrate
echo core-2 > "$root/bundle/mihomo"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "VPN on (0.19, core loaded): upgrade succeeds" "$rc" 0
check "  the VPN target written (migration)" "$([ -e "$root/lib/vpn-on" ] && echo there || echo none)" there
check "  the new watchdog took over before the config rebuild and the core restart" \
  "$(grep -E '^(watchdog: new|ks _regen|launchctl kickstart -k system/local.killswitch.core)$' "$root/calls" | paste -sd, -)" \
  "watchdog: new,ks _regen,launchctl kickstart -k system/local.killswitch.core"
check "  no core restart while pf had nothing loaded" "$(restarts_open) $(wc -l < "$root/restarts" | tr -d ' ')" "0 2"
check "  protection left alone (no ks on/off)" "$(grep -cE '^ks (on|off|pause)' "$root/calls")" 0

setup vpndisabled
out=$(KEEP_E=1 CORE_DISABLED=1 upgrade --upgrade 2>&1); rc=$?
check "core job loaded but disabled (would not start after a reboot): no VPN target" \
  "$rc $([ -e "$root/lib/vpn-on" ] && echo there || echo none)" "0 none"

setup vpnrace
echo core-2 > "$root/bundle/mihomo"
out=$(KEEP_E=1 TAKEOVER=4 upgrade --upgrade 2>&1); rc=$?
check "the 0.19 watchdog flushes for 4 polls after the HUP: upgrade succeeds" "$rc" 0
check "  no core restart before the new watchdog has the rules loaded" "$(restarts_open) $(grep -c . "$root/restarts")" "0 2"

setup vpnstuck
echo core-2 > "$root/bundle/mihomo"
out=$(KEEP_E=1 TAKEOVER=never upgrade --upgrade 2>&1); rc=$?
check "the new watchdog never takes over: the install fails" "$([ "$rc" != 0 ] && echo failed || echo ok)" failed
check "  the core neither rebuilt nor restarted" "$(grep -c . "$root/restarts")" 0
check "  says why" "$(grep -c 'watchdog did not take over' <<<"$out")" 1
check "  no completion marker (the app runs it again)" "$([ -e "$root/lib/installed" ] && echo there || echo none)" none

setup vpnhalf
cp "$root/bundle/ks" "$root/lib/ks"   # an install that stopped after the rename: the 0.19 watchdog still runs
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "ks already in place, the watchdog still the old one, VPN on: HUP all the same" "$rc $(grep -c '^launchctl kill HUP system/local.killswitch$' "$root/calls")" "0 1"

setup vpnwaiting
echo waiting > "$root/core-job"; : > "$root/lib/vpn-on"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "VPN on, the core momentarily not running: its job not disabled" "$rc $(grep -c 'launchctl disable system/local.killswitch.core' "$root/calls")" "0 0"

setup vpnoff
echo core-2 > "$root/bundle/mihomo"
out=$(KEEP_E=1 CORE_LOADED=0 upgrade --upgrade 2>&1); rc=$?
check "VPN off (core not loaded), protection off: no target, nothing waited for" \
  "$rc $([ -e "$root/lib/vpn-on" ] && echo there || echo none) $(grep -c 'watchdog: new' "$root/calls")" "0 none 1"
check "  the core still disabled as before" "$(grep -c 'launchctl disable system/local.killswitch.core' "$root/calls")" 1

setup downgrade
printf '#!/bin/bash -p\nKS_VERSION="0.12.1"\necho older\n' > "$root/bundle/ks"
upgrade --upgrade >/dev/null 2>&1; rc=$?
check "downgrade refused (exit 4)" "$rc" 4
check "downgrade: installed ks untouched" "$(tail -1 "$root/lib/ks")" "echo old"
check "downgrade: nothing restarted" "$(grep -cE 'launchctl (kill|bootout|kickstart)' "$root/calls")" 0

setup fresh
rm -f "$root/lib/ks"
upgrade --upgrade >/dev/null 2>&1; rc=$?
check "not installed: --upgrade refuses (exit 2), the full install is the app's password flow" "$rc" 2

setup nosudoers
upgrade --upgrade >/dev/null 2>&1   # creates the entry through the fake above
rm -f "$root/sudoers"; echo '# nobody' > "$root/sudoers"
upgrade --upgrade >/dev/null 2>&1; rc=$?
check "no sudoers user to keep: refused (exit 2)" "$rc" 2

# --- the version order the downgrade check uses
(
  # shellcheck source=../install.sh
  . "$here/../install.sh"; set +e
  r=""
  for p in "0.13 0.14" "0.9.1 0.13" "0.14 0.14" "0.14 0.13" "1.0 0.99" "0.13 0.13.1"; do
    # shellcheck disable=SC2086
    version_lt $p && r="$r<" || r="$r="
  done
  echo "$r"
) > "$tmp/order"
check "version_lt: 0.13<0.14, 0.9.1<0.13, not 0.14<0.14, 0.14<0.13, 1.0<0.99; 0.13<0.13.1" "$(cat "$tmp/order")" "<<===<"

# a group id for _ksvpn / _ksnetbird from 450-499: the first free one, never a taken one
gids=$(
  # shellcheck source=../install.sh
  . "$here/../install.sh"; set +e
  GIDS=$(seq 450 451; echo 453)
  dscl() { printf '_x %s\n' $GIDS; }
  g=$(free_gid); echo "$g rc=$?"
  GIDS=$(seq 450 499)
  g=$(free_gid 2>"$tmp/gid-err"); echo "$g rc=$?"
)
check "free_gid: the first free one" "$(head -1 <<<"$gids")" "452 rc=0"
check "free_gid: none free fails (no taken id reused)" "$(sed -n 2p <<<"$gids")" " rc=1"
check "free_gid: says why" "$(grep -c '450-499' "$tmp/gid-err")" 1

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
