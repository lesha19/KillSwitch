#!/bin/bash
# Installs the kill switch into root-owned locations and starts it.
# Also lets the installing user run ks without a password (only ks, nothing else),
# so the KillSwitch app can switch it with one click.
set -eu
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
cd "$(dirname "$0")"
DIR="/Library/KillSwitch"
USER_NAME="${SUDO_USER:-${1:?usage: install.sh <user> when run as root}}"

pfctl -n -f killswitch.pf.conf   # syntax check, loads nothing

install -d -o root -g wheel -m 755 "$DIR"
install -o root -g wheel -m 644 killswitch.pf.conf "$DIR/killswitch.pf.conf"
install -o root -g wheel -m 755 ks "$DIR/ks"
install -o root -g wheel -m 644 local.killswitch.plist /Library/LaunchDaemons/local.killswitch.plist

SUDOERS=/etc/sudoers.d/killswitch
echo "$USER_NAME ALL=(root) NOPASSWD: $DIR/ks" > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp"
mv "$SUDOERS.tmp" "$SUDOERS"

launchctl bootout system/local.killswitch 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.killswitch.plist
sleep 1
"$DIR/ks" status

# The app relies on this working without a password
sudo -u "$USER_NAME" sudo -n "$DIR/ks" state >/dev/null && echo "app access: ok"
