#!/bin/bash
# Installs the kill switch into root-owned locations and starts it.
#   install.sh <user> [server-ip ...]
# Server addresses are added to /Library/KillSwitch/servers (VPN servers that may be reached
# without the tunnel). Safe to run again: it upgrades the helper in place and keeps the
# existing settings, exceptions and servers.
# The installing user may run only "ks state" and "ks on" without a password, so the
# app can show the state and turn protection back on in one click. Turning it off,
# pausing and changing what is let through always need the admin password, so a
# program running as the user cannot silently open a hole.
set -eu
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

for ip in "$@"; do
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || { echo "bad server address: $ip" >&2; exit 1; }
done

install -d -o root -g wheel -m 755 "$DIR"
install -o root -g wheel -m 755 ks "$DIR/ks"
install -o root -g wheel -m 644 local.killswitch.plist /Library/LaunchDaemons/local.killswitch.plist
[ -e "$DIR/events.log" ] || install -o root -g wheel -m 644 /dev/null "$DIR/events.log"

SUDOERS=/etc/sudoers.d/killswitch
echo "$USER_NAME ALL=(root) NOPASSWD: $DIR/ks state, $DIR/ks on" > "$SUDOERS.tmp"
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
