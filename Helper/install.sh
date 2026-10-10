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
# The installing user may run only "ks state" and "ks on" without a password, so the
# app can show the state and turn protection back on in one click. Turning it off,
# pausing and changing what is let through always need the admin password, so a
# program running as the user cannot silently open a hole. Starting and stopping our own
# VPN core, listing and switching its servers and refreshing its profile with known server
# addresses are passwordless too: they never widen the rules; importing a new profile is not.
set -eu
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
  echo "$1 ALL=(root) NOPASSWD: $ks state, $ks probe, $ks on, $ks netrestore, $ks core state, $ks core on, $ks core off," \
    "$ks core proxies, $ks core traffic, $ks core connections, $ks core select *, $ks core delay *, $ks core refresh *"
}

# --upgrade: the user the installed entry names (install.sh wrote it), so nobody gains anything.
sudoers_user() { sed -nE 's/^([A-Za-z_][A-Za-z0-9_.-]{0,31}) ALL=\(root\) NOPASSWD: .*/\1/p' "$SUDOERS" 2>/dev/null | head -1; }

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

ks_run() { "$DIR/ks" "$@"; }
job_loaded() { launchctl print "$1" >/dev/null 2>&1; }
job_running() { launchctl print "$1" 2>/dev/null | grep -q 'state = running'; }
job_disabled() { launchctl print-disabled system 2>/dev/null | grep -qE "\"${1#system/}\" => (disabled|true)"; }

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
  elif [ "$1" = 1 ]; then
    launchctl kill HUP "$WATCH_JOB"
    echo "watchdog: new helper"
  fi
}

# Own VPN core (optional: only if Helper/mihomo is present, see fetch-mihomo.sh). Prints
# "core: restarted" or "core: kept".
core_update() {
  local restart=0 plist=0
  if put_file mihomo "$DIR/core/mihomo" 755; then restart=1; fi
  # the subscription's GEOSITE/GEOIP rules and the ad block (ADR 0013): the pinned files of the app bundle
  # (fetch-geodata.sh), never a copy from a place the user can write. A geoip.metadb that older
  # versions took from dropweb's folder is replaced, or removed if the bundle has none. The core
  # reads them when it starts.
  if [ -f geosite.dat ] && put_file geosite.dat "$DIR/core/geosite.dat" 644; then restart=1; fi
  if [ -f geoip.metadb ]; then
    if put_file geoip.metadb "$DIR/core/geoip.metadb" 644; then restart=1; fi
  elif [ -e "$DIR/core/geoip.metadb" ]; then
    rm -f "$DIR/core/geoip.metadb"; restart=1
  fi
  # the core starts at boot only after "ks core on"; an upgrade keeps a running core running
  job_running "$CORE_JOB" || launchctl disable "$CORE_JOB"
  if put_file local.killswitch.core.plist "$CORE_PLIST" 644; then plist=1; fi
  # a config the new generator writes differently: reloaded through the core's API, no restart
  if [ -s "$DIR/core/config.yaml" ]; then ks_run _regen || echo "core config: not rebuilt"; fi
  if ! job_loaded "$CORE_JOB" || [ "$((restart + plist))" = 0 ]; then
    echo "core: kept"
    return 0
  fi
  # Down for about a second: pf keeps everything outside the tunnel blocked, and the system DNS
  # stays on the core (the watchdog restores it only after 5 s), so nothing leaks meanwhile.
  if [ "$plist" = 1 ]; then
    launchctl bootout "$CORE_JOB" 2>/dev/null || true
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
  if put_file ks "$DIR/ks" 755; then ks_new=1; fi
  # «Российские сайты напрямую» (coredirect, 0.7–0.14) is gone (ADR 0013): what goes outside the
  # VPN comes from the subscription's rules only. Its line is dropped; every other setting stays.
  if grep -q '^coredirect=' "$DIR/settings" 2>/dev/null; then
    grep -v '^coredirect=' "$DIR/settings" > "$DIR/settings.tmp"; chmod 644 "$DIR/settings.tmp"; mv "$DIR/settings.tmp" "$DIR/settings"
  fi
  if put_file local.killswitch.plist "$WATCH_PLIST" 644; then plist_new=1; fi
  put_file tsrelays "$DIR/tsrelays" 644 || true
  if ! dscl . -read /Groups/_ksvpn >/dev/null 2>&1; then
    for gid in $(seq 450 499); do
      dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qx "$gid" || break
    done
    dscl . -create /Groups/_ksvpn PrimaryGroupID "$gid"
    dscl . -create /Groups/_ksvpn RealName "KillSwitch VPN core"
  fi
  # 711: the app checks files in it by name; the core's log in it is root-only (ks core_log_tidy)
  install -d -o root -g wheel -m 711 "$DIR/core"
  [ -f "$DIR/core/core.log" ] || install -o root -g wheel -m 600 /dev/null "$DIR/core/core.log"
  chmod 600 "$DIR/core/core.log"
  [ ! -f mihomo ] || core_update
  [ -e "$DIR/events.log" ] || install -o root -g wheel -m 644 /dev/null "$DIR/events.log"

  sudoers_text "$USER_NAME" "$DIR/ks" > "$SUDOERS.tmp"
  chmod 440 "$SUDOERS.tmp"
  visudo -cf "$SUDOERS.tmp"
  mv "$SUDOERS.tmp" "$SUDOERS"

  # ks checks each address against pf and skips duplicates
  for ip in "$@"; do ks_run server-add "$ip"; done

  watchdog_update "$ks_new" "$plist_new"
  if [ "$upgrade" = 1 ]; then
    echo "kill switch: $(ks_run state)"
  else
    sleep 1
    ks_run on
    ks_run status | head -1
  fi

  # The app relies on this working without a password
  sudo -u "$USER_NAME" sudo -n "$DIR/ks" state >/dev/null && echo "app access: ok"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced by Helper/tests
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
cd "$(dirname "$0")"
main "$@"
