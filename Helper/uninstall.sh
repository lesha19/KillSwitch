#!/bin/bash
# Removes everything install.sh put in place and lifts the rules.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
export HOME=/var/root LC_ALL=C
unset CURL_HOME BASH_ENV ENV CDPATH
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
# A stopped watchdog disables the physical network services unless protection is off (the
# shutdown guard), so it is switched off first; then wait until the old watchdog is gone.
if [ -x /Library/KillSwitch/ks ]; then /Library/KillSwitch/ks off >/dev/null 2>&1
elif [ -d /Library/KillSwitch ]; then echo 0 > /Library/KillSwitch/disabled; fi
launchctl bootout system/local.killswitch 2>/dev/null
for _ in $(seq 1 50); do launchctl print system/local.killswitch >/dev/null 2>&1 || break; sleep 0.2; done
# stops our core and gives the network services their DNS back
[ -x /Library/KillSwitch/ks ] && /Library/KillSwitch/ks core off >/dev/null 2>&1
launchctl enable system/local.killswitch.core
# services disabled at an earlier shutdown, or by a watchdog that raced the switch-off
if [ -f /Library/KillSwitch/wifi-off-by-ks ]; then
  while IFS= read -r svc; do networksetup -setnetworkserviceenabled "$svc" on; done < /Library/KillSwitch/wifi-off-by-ks
fi
pfctl -a com.apple/killswitch -F all 2>/dev/null
dscl . -delete /Groups/_ksvpn 2>/dev/null
# NetBird's daemon back to how its installer left it (ks netbird_sync gave it our group)
nb=/Library/LaunchDaemons/netbird.plist
if [ "$(/usr/libexec/PlistBuddy -c 'Print :GroupName' "$nb" 2>/dev/null)" = _ksnetbird ]; then
  /usr/libexec/PlistBuddy -c 'Delete :GroupName' "$nb"
  label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$nb")
  launchctl bootout "system/$label" 2>/dev/null
  for _ in $(seq 1 50); do launchctl print "system/$label" >/dev/null 2>&1 || break; sleep 0.2; done
  launchctl bootstrap system "$nb" 2>/dev/null
fi
dscl . -delete /Groups/_ksnetbird 2>/dev/null
rm -f /Library/LaunchDaemons/local.killswitch.plist /Library/LaunchDaemons/local.killswitch.core.plist /etc/sudoers.d/killswitch
rm -rf /Library/KillSwitch
# the right of the privileged daemon (ADR 0010); the app unregisters the daemon itself
security authorizationdb remove com.lesha19.KillSwitch.widen >/dev/null 2>&1
echo "kill switch removed"
