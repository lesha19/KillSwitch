#!/bin/bash
# Removes everything install.sh put in place and lifts the rules.
set -u
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
launchctl bootout system/local.killswitch 2>/dev/null
# the watchdog disables network services when stopped; give them back
if [ -f /Library/KillSwitch/wifi-off-by-ks ]; then
  while IFS= read -r svc; do networksetup -setnetworkserviceenabled "$svc" on; done < /Library/KillSwitch/wifi-off-by-ks
fi
pfctl -a com.apple/killswitch -F all 2>/dev/null
rm -f /Library/LaunchDaemons/local.killswitch.plist /etc/sudoers.d/killswitch
rm -rf /Library/KillSwitch
echo "kill switch removed"
