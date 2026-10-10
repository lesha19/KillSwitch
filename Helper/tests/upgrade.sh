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
    DIR="$d"; FLAG="$d/disabled"; SETTINGS="$d/settings"; EVENTS="$d/events.log"; STATEF="$d/daemon-state"
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
    DIR="$d"; CORE_DIR="$d/core"; EVENTS="$d/events.log"; CORE_PROFILE="$d/core/profile.json"; PINS="$d/core/pins"
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
setup() {  # setup <name>: a fresh installed system and bundle
  root="$tmp/i-$1"
  mkdir -p "$root/lib/core" "$root/bundle" "$root/ld"
  printf '#!/bin/bash -p\nKS_VERSION="0.13"\necho old\n' > "$root/lib/ks"
  printf '#!/bin/bash -p\nKS_VERSION="0.14"\necho new\n' > "$root/bundle/ks"
  echo relays > "$root/bundle/tsrelays"; echo relays > "$root/lib/tsrelays"
  echo core-1 > "$root/bundle/mihomo"; echo core-1 > "$root/lib/core/mihomo"
  echo site > "$root/bundle/geosite.dat"; echo site > "$root/lib/core/geosite.dat"
  echo ip > "$root/bundle/geoip.metadb"; echo ip > "$root/lib/core/geoip.metadb"
  echo cfg > "$root/lib/core/config.yaml"
  cp "$here/../local.killswitch.plist" "$here/../local.killswitch.core.plist" "$root/bundle/"
  cp "$here/../local.killswitch.plist" "$root/ld/local.killswitch.plist"
  cp "$here/../local.killswitch.core.plist" "$root/ld/local.killswitch.core.plist"
  printf 'lan=0\ncoredirect=1\nadblock=1\n' > "$root/lib/settings"
  : > "$root/calls"
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
    launchctl() {
      echo "launchctl $*" >> "$root/calls"
      case "$1" in
        print) [[ "$2" == *core ]] && { [ "${CORE_LOADED:-1}" = 1 ] || return 1; echo 'state = running'; }; return 0 ;;
        print-disabled) return 0 ;;
      esac
    }
    ks_run() { echo "ks $*" >> "$root/calls"; [ "$1" = state ] && echo on; [ "$1" = _regen ] && echo "core config: kept"; return 0; }
    lockf() { echo "lockf $*" >> "$root/calls"; }
    dscl() { return 0; }
    sudo() { echo "sudo $*" >> "$root/calls"; }
    visudo() { [ "${VISUDO_FAILS:-0}" = 0 ] || return 1; /usr/sbin/visudo "$@"; }
    chmod() { /bin/chmod "$@"; }
    id() { if [ "$1" = -u ] && [ -n "${2:-}" ]; then echo 501; else /usr/bin/id "$@"; fi; }
    pfctl() { echo "pfctl $*" >> "$root/calls"; }
    networksetup() { echo "networksetup $*" >> "$root/calls"; }
    sleep() { :; }
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
check "upgrade: written to disk before the rename" "$(grep -c '^sync$' "$root/calls")" 1
check "upgrade: no temporary file left" "$(find "$root/lib" "$root/ld" -name '.*.new' | wc -l | tr -d ' ')" 0
check "upgrade: watchdog gets SIGHUP" "$(grep -c '^launchctl kill HUP system/local.killswitch$' "$root/calls")" 1
check "upgrade: watchdog never booted out" "$(grep -c 'bootout system/local.killswitch$' "$root/calls")" 0
check "upgrade: core not restarted (same binary)" "$(grep -cE 'kickstart|bootout system/local.killswitch.core' "$root/calls")" 0
check "upgrade: protection state left alone (no ks on/off)" "$(grep -cE '^ks (on|off|pause)' "$root/calls")" 0
check "upgrade: the core config regenerated under the lock" "$(grep -c '^ks _regen$' "$root/calls")" 1
check "upgrade: pf and the network never touched" "$(grep -cE '^(pfctl|networksetup)' "$root/calls")" 0
check "upgrade: says the core kept running" "$(grep -c '^core: kept$' <<<"$out")" 1
check "upgrade: sudoers kept for the same user" "$(grep -c '^someone ALL=(root) NOPASSWD:' "$root/sudoers")" 1
check "upgrade: settings kept, coredirect dropped (ADR 0013)" "$(paste -sd, - < "$root/lib/settings")" "lan=0,adblock=1"

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

setup onlycoredirect
printf 'coredirect=1\n' > "$root/lib/settings"
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "settings with only coredirect: upgrade succeeds under set -e" "$rc" 0
check "settings with only coredirect: emptied" "$(wc -c < "$root/lib/settings" | tr -d ' ')" 0
check "settings with only coredirect: the rest of the install ran" "$(grep -c '^launchctl kill HUP system/local.killswitch$' "$root/calls")" 1

setup strict
out=$(KEEP_E=1 upgrade --upgrade 2>&1); rc=$?
check "upgrade under set -e: succeeds" "$rc" 0

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

setup coreoff
echo core-2 > "$root/bundle/mihomo"
CORE_LOADED=0 upgrade --upgrade >/dev/null 2>&1
check "core not loaded: not started by the upgrade" "$(grep -cE 'kickstart|bootstrap system .*core' "$root/calls")" 0

setup plist
echo '<!-- changed -->' >> "$root/bundle/local.killswitch.plist"
upgrade --upgrade >/dev/null 2>&1
seq_=$(grep -E 'launchctl (disable|bootout|enable|bootstrap) .*local.killswitch(\.plist)?$' "$root/calls" | awk '{print $2}' | paste -sd, -)
check "new watchdog plist: marked disabled around the bootout (no network-off guard)" "$seq_" "disable,bootout,enable,bootstrap"

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

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
