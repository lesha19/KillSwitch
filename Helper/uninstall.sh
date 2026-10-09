#!/bin/bash
# Removes everything install.sh put in place and lifts the rules.
set -u
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
launchctl bootout system/local.killswitch 2>/dev/null
pfctl -a com.apple/killswitch -F all 2>/dev/null
rm -f /Library/LaunchDaemons/local.killswitch.plist /etc/sudoers.d/killswitch
rm -rf /Library/KillSwitch
echo "kill switch removed"
