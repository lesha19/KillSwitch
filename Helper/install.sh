#!/bin/bash
# Installs the kill switch into root-owned locations and starts it.
# The installing user may run only "ks state" and "ks on" without a password, so the
# app can show the state and turn protection back on in one click. Turning it off,
# pausing and changing what is let through always need the admin password, so a
# program running as the user cannot silently open a hole.
set -eu
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
cd "$(dirname "$0")"
DIR="/Library/KillSwitch"
USER_NAME="${SUDO_USER:-${1:?usage: install.sh <user> when run as root}}"

install -d -o root -g wheel -m 755 "$DIR"
install -o root -g wheel -m 755 ks "$DIR/ks"
install -o root -g wheel -m 644 local.killswitch.plist /Library/LaunchDaemons/local.killswitch.plist

SUDOERS=/etc/sudoers.d/killswitch
echo "$USER_NAME ALL=(root) NOPASSWD: $DIR/ks state, $DIR/ks on" > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp"
mv "$SUDOERS.tmp" "$SUDOERS"

launchctl bootout system/local.killswitch 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.killswitch.plist
sleep 1
"$DIR/ks" on
"$DIR/ks" status | head -1

# The app relies on this working without a password
sudo -u "$USER_NAME" sudo -n "$DIR/ks" state >/dev/null && echo "app access: ok"
