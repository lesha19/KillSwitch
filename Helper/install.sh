#!/bin/bash
# Installs the kill switch into root-owned locations and starts it.
#   install.sh <user> [server-ip ...]
# Server addresses are added to /Library/KillSwitch/servers (VPN servers that may be reached
# without the tunnel). Safe to run again: it upgrades the helper in place and keeps the
# existing settings, exceptions and servers.
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
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
cd "$(dirname "$0")"
DIR="/Library/KillSwitch"
# Under sudo the user is known; the admin prompt of the app passes it as the first argument.
if [ -n "${SUDO_USER:-}" ]; then
  USER_NAME="$SUDO_USER"
  [ "${1:-}" = "$USER_NAME" ] && shift
else
  USER_NAME="${1:?usage: install.sh <user> [server-ip ...]}"
  shift
fi
# The user goes into sudoers: an existing ordinary account with a plain name, never a sudoers
# keyword (ALL), a group (%…), a uid (#…), several words or root.
valid_user() {
  local uid
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && [ "$1" != ALL ] || return 1
  uid=$(id -u "$1" 2>/dev/null) && [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 500 ]
}
valid_user "$USER_NAME" || { echo "bad user: $USER_NAME" >&2; exit 1; }

for ip in "$@"; do
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || { echo "bad server address: $ip" >&2; exit 1; }
done

fresh=0; [ -e "$DIR/ks" ] || fresh=1
install -d -o root -g wheel -m 755 "$DIR"
install -o root -g wheel -m 755 ks "$DIR/ks"
# Operator's choice (0.7): on a new install Russian sites go outside the VPN, everything else
# through it (coredirect=1, see ks core_generate). An upgrade keeps the setting it had.
if [ "$fresh" = 1 ] && ! grep -q '^coredirect=' "$DIR/settings" 2>/dev/null; then
  echo coredirect=1 >> "$DIR/settings"
fi
install -o root -g wheel -m 644 local.killswitch.plist /Library/LaunchDaemons/local.killswitch.plist
install -o root -g wheel -m 644 tsrelays "$DIR/tsrelays"
# Own VPN core (optional: only if Helper/mihomo is present, see fetch-mihomo.sh).
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
if [ -f mihomo ]; then
  install -o root -g wheel -m 755 mihomo "$DIR/core/mihomo"
  # the core starts at boot only after "ks core on"; an upgrade keeps a running core running
  launchctl print system/local.killswitch.core 2>/dev/null | grep -q 'state = running' ||
    launchctl disable system/local.killswitch.core
  install -o root -g wheel -m 644 local.killswitch.core.plist /Library/LaunchDaemons/local.killswitch.core.plist
  # Russian sites and addresses outside the VPN (coredirect=1): the pinned files of the app bundle
  # (fetch-geodata.sh), never a copy from a place the user can write. A geoip.metadb that older
  # versions took from dropweb's folder is replaced, or removed if the bundle has none.
  [ ! -f geosite.dat ] || install -o root -g wheel -m 644 geosite.dat "$DIR/core/geosite.dat"
  if [ -f geoip.metadb ]; then install -o root -g wheel -m 644 geoip.metadb "$DIR/core/geoip.metadb"
  else rm -f "$DIR/core/geoip.metadb"; fi
  launchctl print system/local.killswitch.core >/dev/null 2>&1 && launchctl kickstart -k system/local.killswitch.core
fi
[ -e "$DIR/events.log" ] || install -o root -g wheel -m 644 /dev/null "$DIR/events.log"

SUDOERS=/etc/sudoers.d/killswitch
# "core refresh" (subscription auto-update) is refused by ks if it brings new server addresses;
# "core import" may add servers the core can reach, so it keeps asking for the password.
# "netrestore" only turns back on the network services ks itself turned off, and refuses while the
# watchdog runs without its rules.
# The environment: secure_path and env_reset for ks whatever the system's sudoers says, and none
# of the variables macOS keeps by default (HOME would hand curl the user's ~/.curlrc).
sudoers_text() {  # sudoers_text <user> <ks>
  local ks=$2
  echo "Defaults!$ks secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\", env_reset"
  echo "Defaults!$ks env_keep-=\"HOME MAIL CHARSET LANG LANGUAGE LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME SSH_AUTH_SOCK TZ EDITOR VISUAL\""
  echo "Defaults!$ks env_delete+=\"HOME CURL_HOME BASH_ENV ENV LC_ALL\""
  echo "$1 ALL=(root) NOPASSWD: $ks state, $ks probe, $ks on, $ks netrestore, $ks core state, $ks core on, $ks core off," \
    "$ks core proxies, $ks core select *, $ks core delay *, $ks core refresh *"
}
sudoers_text "$USER_NAME" "$DIR/ks" > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp"
mv "$SUDOERS.tmp" "$SUDOERS"

# ks checks each address against pf and skips duplicates
for ip in "$@"; do "$DIR/ks" server-add "$ip"; done

launchctl bootout system/local.killswitch 2>/dev/null || true
# bootout returns before the old watchdog has finished its shutdown handler
for _ in $(seq 1 50); do launchctl print system/local.killswitch >/dev/null 2>&1 || break; sleep 0.2; done
launchctl bootstrap system /Library/LaunchDaemons/local.killswitch.plist
sleep 1
"$DIR/ks" on
"$DIR/ks" status | head -1

# The app relies on this working without a password
sudo -u "$USER_NAME" sudo -n "$DIR/ks" state >/dev/null && echo "app access: ok"
