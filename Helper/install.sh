#!/bin/bash
# Installs the kill switch into root-owned locations and starts it.
#   install.sh <user> [server-ip ...]
#   install.sh --upgrade
# Server addresses are added to /Library/KillSwitch/servers (VPN servers that may be reached
# without the tunnel). Safe to run again: it upgrades the helper in place and keeps the
# existing settings, exceptions and servers.
# --upgrade (the privileged daemon, after an app update, ADR 0012): only an installed helper, for
# the user its sudoers entry already names; protection is left as it is, and an older helper is
# never put over a newer one (exit 4). Not installed, or no entry to keep: exit 2.
# Neither way interrupts the VPN: files are replaced by rename, the watchdog takes a new ks by
# SIGHUP (never a plain bootout: on SIGTERM it turns the network off, see "ks watch"), pf rules are
# only ever reloaded, never flushed, and the core restarts only if its binary, geodata or plist
# changed (prints "core: restarted" or "core: kept").
# With the VPN on (ADR 0035) nothing of the core is touched before the new watchdog runs and has the
# rules loaded (watchdog_takeover): a 0.19 one flushes them while protection is off.
# The installing user may run only "ks state" and "ks on" without a password, so the
# app can show the state and turn protection back on in one click. Turning it off,
# pausing and changing what is let through always need the admin password, so a
# program running as the user cannot silently open a hole. Starting and stopping our own
# VPN core, listing and switching its servers and refreshing its profile with known server
# addresses are passwordless too: they never widen the rules; importing a new profile is not.
set -Eeu
# set -e alone stops without a word (the app showed only «exited with a non-zero status»): the
# failing line goes to stderr, which the app shows. -E: also inside the functions (all of main).
trap 'echo "install.sh:$LINENO: exit $?" >&2' ERR
# as root: system tools only, nothing of the caller's environment (see ks_clean_env in ks)
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
export HOME=/var/root LC_ALL=C
unset CURL_HOME BASH_ENV ENV CDPATH
DIR="/Library/KillSwitch"
SUDOERS=/etc/sudoers.d/killswitch
WATCH_JOB=system/local.killswitch
CORE_JOB=system/local.killswitch.core
WATCH_PLIST=/Library/LaunchDaemons/local.killswitch.plist
CORE_PLIST=/Library/LaunchDaemons/local.killswitch.core.plist

# The user goes into sudoers: an existing ordinary account with a plain name, never a sudoers
# keyword (ALL), a group (%…), a uid (#…), several words or root.
valid_user() {
  local uid
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && [ "$1" != ALL ] || return 1
  uid=$(id -u "$1" 2>/dev/null) && [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 500 ]
}

# "core refresh" (subscription auto-update) is refused by ks if it brings new server addresses;
# "core import" may add servers the core can reach, so it keeps asking for the password.
# "netrestore" only turns back on the network services ks itself turned off, and refuses while the
# watchdog runs without its rules.
# "core traffic" (the menu bar speed) prints two byte totals of the core and changes nothing;
# "core connections" (the «Трафик» window) lists the user's own connections through the core and
# changes nothing either.
# "set" (ad blocking included) changes what the core and pf do, so it keeps the password.
# The environment: secure_path and env_reset for ks whatever the system's sudoers says, and none
# of the variables macOS keeps by default (HOME would hand curl the user's ~/.curlrc).
sudoers_text() {  # sudoers_text <user> <ks>
  local ks=$2
  echo "Defaults!$ks secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\", env_reset"
  echo "Defaults!$ks env_keep-=\"HOME MAIL CHARSET LANG LANGUAGE LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME SSH_AUTH_SOCK TZ EDITOR VISUAL\""
  echo "Defaults!$ks env_delete+=\"HOME CURL_HOME BASH_ENV ENV LC_ALL\""
  echo "$1 ALL=(root) NOPASSWD: $ks state, $ks probe, $ks on, $ks netrestore, $ks core state, $ks core on, $ks core off, $ks core restart," \
    "$ks core proxies, $ks core traffic, $ks core connections, $ks core select *, $ks core delay *, $ks core refresh *, $ks diag report *"
}

# --upgrade: the user the installed entry names (install.sh wrote it), so nobody gains anything.
sudoers_user() { sed -nE 's/^([A-Za-z_][A-Za-z0-9_.-]{0,31}) ALL=\(root\) NOPASSWD: .*/\1/p' "$SUDOERS" 2>/dev/null | head -1; }

# A group id for our groups: the first one 450-499 nobody has; none left is an error, never a
# taken id (its members would get what the group is let through).
free_gid() {
  local gid taken
  taken=$(dscl . -list /Groups PrimaryGroupID | awk '{print $2}')
  for gid in $(seq 450 499); do
    grep -qx "$gid" <<<"$taken" || { echo "$gid"; return 0; }
  done
  echo "no free group id in 450-499 for KillSwitch's groups" >&2
  return 1
}

script_version() { sed -nE 's/^KS_VERSION="([^"]+)".*/\1/p' "$1" 2>/dev/null | head -1; }

# version_lt <a> <b>: dotted numbers, a before b (0.9.1 < 0.13 < 0.13.1 < 0.14). No version
# (a helper before 0.9.1) is older than any.
version_lt() {
  local -a a b
  local i x y
  IFS=. read -ra a <<<"$1"; IFS=. read -ra b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    [[ "$x" =~ ^[0-9]+$ ]] || x=0; [[ "$y" =~ ^[0-9]+$ ]] || y=0
    [ "$((10#$x))" -lt "$((10#$y))" ] && return 0
    [ "$((10#$x))" -gt "$((10#$y))" ] && return 1
  done
  return 1
}

# put_file <src> <dest> <mode>: 0 if <dest> was replaced, 1 if it was the same already. A new
# copy next to it (same file system), on disk, then renamed over it: a reader, such as the bash of
# the running watchdog, keeps the file it opened and never sees a half-written one.
put_file() {
  local new
  cmp -s "$1" "$2" && return 1
  new="$(dirname "$2")/.$(basename "$2").new"
  rm -f "$new"
  install -o root -g wheel -m "$3" "$1" "$new" || { echo "cannot write $new" >&2; exit 1; }
  sync
  mv -f "$new" "$2" || { echo "cannot replace $2" >&2; exit 1; }
}

# The last step: the app takes an install as done only when $DIR/installed names the ks in place
# (HelperVersion.installCompleted). One that stopped half-way has none, and the app runs it again.
write_marker() {
  local sum new="$DIR/.installed.new"
  sum=$(shasum -a 256 "$DIR/ks") || { echo "cannot hash $DIR/ks" >&2; exit 1; }
  rm -f "$new"
  printf 'version %s\nsha256 %s\n' "$(script_version "$DIR/ks")" "${sum%% *}" > "$new"
  chmod 644 "$new"
  mv -f "$new" "$DIR/installed"
}

ks_run() { "$DIR/ks" "$@"; }
job_loaded() { launchctl print "$1" >/dev/null 2>&1; }
job_running() { launchctl print "$1" 2>/dev/null | grep -q 'state = running'; }
job_disabled() { launchctl print-disabled system 2>/dev/null | grep -qE "\"${1#system/}\" => (disabled|true)"; }
# launchctl bootout returns before the job is gone, and bootstrap refuses it until then
job_gone() { for _ in $(seq 1 50); do job_loaded "$1" || return 0; sleep 0.2; done; return 1; }

# The VPN target (ADR 0035): a core job a helper before 0.20 loaded and left enabled means the VPN is
# on (a disabled one would not start after a reboot, and the Mac would stay blocked).
vpn_migrate() {
  [ ! -e "$DIR/vpn-on" ] && job_loaded "$CORE_JOB" && ! job_disabled "$CORE_JOB" || return 0
  date +%s > "$DIR/.vpn-on.new"; chmod 644 "$DIR/.vpn-on.new"; mv -f "$DIR/.vpn-on.new" "$DIR/vpn-on"
}
# A watchdog of 0.20 or later says vpn= in its state file; the one running is older than the ks in place.
watchdog_old() { ! grep -q '^vpn=' "$DIR/daemon-state" 2>/dev/null; }
# With the VPN on: wait until the watchdog running is the new one and has the rules loaded, about 30 s
# at most; the core is not touched otherwise (the install fails, and the app runs it again).
watchdog_takeover() {
  [ -e "$DIR/vpn-on" ] || return 0
  for _ in $(seq 1 150); do
    grep -qx 'vpn=1' "$DIR/daemon-state" 2>/dev/null && grep -qx 'blocking=1' "$DIR/daemon-state" && return 0
    sleep 0.2
  done
  echo "the new watchdog did not take over with the rules loaded: the core not touched" >&2
  return 1
}

# watchdog_update <ks changed 0|1> <plist changed 0|1>
watchdog_update() {
  if ! job_loaded "$WATCH_JOB"; then
    launchctl bootstrap system "$WATCH_PLIST"
    echo "watchdog: started"
  elif [ "$2" = 1 ]; then
    # A new plist needs bootout and bootstrap. Marked disabled meanwhile, the watchdog's shutdown
    # guard leaves the network on (watch_disabled in ks, already in 0.13); the rules stay loaded.
    local was_disabled=0
    job_disabled "$WATCH_JOB" && was_disabled=1
    launchctl disable "$WATCH_JOB"
    launchctl bootout "$WATCH_JOB" 2>/dev/null || true
    # bootout returns before the old watchdog has finished its shutdown handler
    for _ in $(seq 1 50); do job_loaded "$WATCH_JOB" || break; sleep 0.2; done
    [ "$was_disabled" = 1 ] || launchctl enable "$WATCH_JOB"
    launchctl bootstrap system "$WATCH_PLIST"
    echo "watchdog: reloaded"
  elif [ "$1" = 1 ] || { [ -e "$DIR/vpn-on" ] && watchdog_old; }; then
    launchctl kill HUP "$WATCH_JOB"
    echo "watchdog: new helper"
  fi
}

# geodata_put <file>: the bundle's geosite.dat or geoip.metadb over the installed one, only if its
# sha256 is the one pinned in the bundle's fetch-geodata.sh (#27, as release.sh checks it); the old
# file stays otherwise, and stderr says which. GEO_STATE collects "<file>=ok|mismatch|unpinned"
# for core/geodata, which the app shows. 0 only if the file was replaced.
GEO_STATE=""
geodata_put() {
  local var pin sum
  case "$1" in geosite.dat) var=SHA256_GEOSITE ;; geoip.dat) var=SHA256_GEOIP_DAT ;; *) var=SHA256_GEOIP ;; esac
  pin=$(sed -nE "s/^$var=\"([0-9a-f]{64})\".*/\1/p" fetch-geodata.sh 2>/dev/null || true)
  sum=$(shasum -a 256 "$1" | cut -d' ' -f1)
  if [ -z "$pin" ]; then
    GEO_STATE+="$1=unpinned"$'\n'; echo "$1: в программе нет его sha256, оставлен прежний" >&2; return 1
  fi
  if [ "$sum" != "$pin" ]; then
    GEO_STATE+="$1=mismatch"$'\n'; echo "$1: не совпадает с закреплённым sha256, оставлен прежний" >&2; return 1
  fi
  GEO_STATE+="$1=ok"$'\n'
  put_file "$1" "$DIR/core/$1" 644
}

# Own VPN core (optional: only if Helper/mihomo or Helper/xray is present, see fetch-mihomo.sh,
# fetch-xray.sh). Prints "core: restarted" or "core: kept".
# Which core runs (ADR 0020): the settings' core= line. An install without one that already has a
# mihomo config or subscription keeps mihomo (ks reads a missing line as mihomo); a new one gets
# Xray when the bundle has it.
core_update() {
  local restart=0 plist=0 kind run
  if [ -f xray ] && ! grep -q '^core=' "$DIR/settings" 2>/dev/null &&
     [ ! -e "$DIR/core/config.yaml" ] && [ ! -e "$DIR/core/profile.json" ]; then
    echo core=xray >> "$DIR/settings"; chmod 644 "$DIR/settings"
  fi
  kind=$(sed -n 's/^core=//p' "$DIR/settings" 2>/dev/null | tail -1)
  [ "$kind" = xray ] || kind=mihomo
  # the core the job runs: the chosen one, unless "ks set core" chose the other one and its
  # subscription is not imported yet; then the running job keeps the VPN until "ks core on" swaps it
  # (the chosen core would not start without its config)
  run=$kind
  if job_loaded "$CORE_JOB" && [ ! -s "$DIR/core/$([ "$kind" = xray ] && echo xray.json || echo config.yaml)" ]; then
    if [ "$kind" = xray ] && [ -s "$DIR/core/config.yaml" ]; then run=mihomo; fi
    if [ "$kind" = mihomo ] && [ -s "$DIR/core/xray.json" ]; then run=xray; fi
  fi
  if [ -f mihomo ] && put_file mihomo "$DIR/core/mihomo" 755 && [ "$run" = mihomo ]; then restart=1; fi
  if [ -f xray ] && put_file xray "$DIR/core/xray" 755 && [ "$run" = xray ]; then restart=1; fi
  # the subscription's GEOSITE/GEOIP rules and the ad block (ADR 0013): the pinned files of the app bundle
  # (fetch-geodata.sh), never a copy from a place the user can write. A geoip.metadb that older
  # versions took from dropweb's folder is replaced, or removed if the bundle has none. The core
  # reads them when it starts.
  if [ -f geosite.dat ] && geodata_put geosite.dat; then restart=1; fi
  if [ -f geoip.metadb ]; then
    if geodata_put geoip.metadb; then restart=1; fi
  elif [ -e "$DIR/core/geoip.metadb" ]; then
    rm -f "$DIR/core/geoip.metadb"; restart=1
  fi
  if [ -f geoip.dat ] && geodata_put geoip.dat && [ "$run" = xray ]; then restart=1; fi
  printf '%s' "$GEO_STATE" > "$DIR/core/.geodata.new"; chmod 644 "$DIR/core/.geodata.new"; mv -f "$DIR/core/.geodata.new" "$DIR/core/geodata"
  # the core starts at boot only after "ks core on"; an upgrade keeps a running core running, and
  # never disables it while the VPN is on, running or not (ADR 0035)
  [ -e "$DIR/vpn-on" ] || job_running "$CORE_JOB" || launchctl disable "$CORE_JOB"
  # both jobs stay in core/ for "ks set core"; the chosen one is the system's
  put_file local.killswitch.core.plist "$DIR/core/plist.mihomo" 644 || true
  if [ -f local.killswitch.core.xray.plist ]; then put_file local.killswitch.core.xray.plist "$DIR/core/plist.xray" 644 || true; fi
  if [ "$run" = xray ]; then
    if put_file local.killswitch.core.xray.plist "$CORE_PLIST" 644; then plist=1; fi
  elif put_file local.killswitch.core.plist "$CORE_PLIST" 644; then plist=1; fi
  # a config the new generator writes differently: reloaded in place (mihomo) or restarted (Xray)
  if [ -s "$DIR/core/config.yaml" ] || [ -s "$DIR/core/xray.json" ]; then ks_run _regen || echo "core config: not rebuilt"; fi
  if ! job_loaded "$CORE_JOB" || [ "$((restart + plist))" = 0 ]; then
    echo "core: kept"
    return 0
  fi
  # Down for about a second: pf keeps everything outside the tunnel blocked, and the system DNS
  # stays on the core (the watchdog restores it only after 5 s), so nothing leaks meanwhile.
  if [ "$plist" = 1 ]; then
    launchctl bootout "$CORE_JOB" 2>/dev/null || true
    job_gone "$CORE_JOB" || true
    launchctl bootstrap system "$CORE_PLIST"
  else
    launchctl kickstart -k "$CORE_JOB"
  fi
  echo "core: restarted"
}

main() {
  local upgrade=0 ks_new=0 plist_new=0 old new USER_NAME ip
  if [ "${1:-}" = --upgrade ]; then
    [ $# -eq 1 ] || { echo "usage: install.sh --upgrade" >&2; exit 1; }
    upgrade=1; shift
    [ -f "$DIR/ks" ] || { echo "not installed: run install.sh <user>" >&2; exit 2; }
    USER_NAME=$(sudoers_user)
    valid_user "$USER_NAME" || { echo "no sudoers entry to keep: run install.sh <user>" >&2; exit 2; }
    old=$(script_version "$DIR/ks"); new=$(script_version ks)
    if [ -z "$new" ] || version_lt "$new" "${old:-0}"; then
      echo "the installed helper ($old) is newer than this one (${new:-none}): not replaced" >&2
      exit 4
    fi
  # Under sudo the user is known; the admin prompt of the app passes it as the first argument.
  elif [ -n "${SUDO_USER:-}" ]; then
    USER_NAME="$SUDO_USER"
    [ "${1:-}" = "$USER_NAME" ] && shift
  else
    USER_NAME="${1:?usage: install.sh <user> [server-ip ...]}"
    shift
  fi
  valid_user "$USER_NAME" || { echo "bad user: $USER_NAME" >&2; exit 1; }

  for ip in "$@"; do
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || { echo "bad server address: $ip" >&2; exit 1; }
  done

  install -d -o root -g wheel -m 755 "$DIR"
  rm -f "$DIR/installed"   # written again as the last step
  if put_file ks "$DIR/ks" 755; then ks_new=1; fi
  # «Российские сайты напрямую» (coredirect, 0.7–0.14) is gone (ADR 0013): what goes outside the
  # VPN comes from the subscription's rules only; so is the automatic server switch (failover,
  # 0.10–0.19, ADR 0036) with its state. Their lines are dropped; every other setting stays.
  # (grep -v exits 1 when no line is left, a settings file with only these: not an error)
  if grep -qE '^(coredirect|failover)=' "$DIR/settings" 2>/dev/null; then
    { grep -vE '^(coredirect|failover)=' "$DIR/settings" || true; } > "$DIR/settings.tmp"; chmod 644 "$DIR/settings.tmp"; mv "$DIR/settings.tmp" "$DIR/settings"
  fi
  rm -f "$DIR/core/failover" "$DIR/core/failover-refused" "$DIR/core/failover.next" "$DIR/core/failover.tmp"
  if put_file local.killswitch.plist "$WATCH_PLIST" 644; then plist_new=1; fi
  put_file tsrelays "$DIR/tsrelays" 644 || true
  if ! dscl . -read /Groups/_ksvpn >/dev/null 2>&1; then
    gid=$(free_gid) || exit 1
    dscl . -create /Groups/_ksvpn PrimaryGroupID "$gid"
    dscl . -create /Groups/_ksvpn RealName "KillSwitch VPN core"
  fi
  # NetBird's daemon gets it (ks netbird_sync) so pf can let NetBird past the VPN
  if ! dscl . -read /Groups/_ksnetbird >/dev/null 2>&1; then
    gid=$(free_gid) || exit 1
    dscl . -create /Groups/_ksnetbird PrimaryGroupID "$gid"
    dscl . -create /Groups/_ksnetbird RealName "KillSwitch: NetBird past the VPN"
  fi
  # 711: the app checks files in it by name; the core's log in it is root-only (ks core_log_tidy)
  install -d -o root -g wheel -m 711 "$DIR/core"
  [ -f "$DIR/core/core.log" ] || install -o root -g wheel -m 600 /dev/null "$DIR/core/core.log"
  chmod 600 "$DIR/core/core.log"
  # the diagnostics journal (ADR 0021): root-only, the app gets it redacted through «Собрать отчёт»
  install -d -o root -g wheel -m 700 "$DIR/diag"
  vpn_migrate
  watchdog_update "$ks_new" "$plist_new"
  watchdog_takeover
  if [ -f mihomo ] || [ -f xray ]; then core_update; fi
  [ -e "$DIR/events.log" ] || install -o root -g wheel -m 644 /dev/null "$DIR/events.log"

  sudoers_text "$USER_NAME" "$DIR/ks" > "$SUDOERS.tmp"
  chmod 440 "$SUDOERS.tmp"
  visudo -cf "$SUDOERS.tmp"
  mv "$SUDOERS.tmp" "$SUDOERS"

  # ks checks each address against pf and skips duplicates
  for ip in "$@"; do ks_run server-add "$ip"; done

  if [ "$upgrade" = 1 ]; then
    echo "kill switch: $(ks_run state)"
  else
    sleep 1
    ks_run on
    ks_run status | head -1
  fi

  # The app relies on this working without a password
  if sudo -u "$USER_NAME" sudo -n "$DIR/ks" state >/dev/null; then
    echo "app access: ok"
  else
    echo "app access: failed: $USER_NAME cannot run ks state without a password" >&2
    exit 1
  fi
  write_marker
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced by Helper/tests
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
cd "$(dirname "$0")"
main "$@"
