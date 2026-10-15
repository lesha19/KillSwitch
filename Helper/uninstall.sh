#!/bin/bash
# Removes everything install.sh put in place and lifts the rules.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
export HOME=/var/root LC_ALL=C
unset CURL_HOME BASH_ENV ENV CDPATH

# networksetup killed after NS_TIMEOUT seconds, as in ks: a hanging one does not hold the uninstall.
NS_TIMEOUT=3
ns() {
  (
    networksetup "$@" 2>/dev/null & p=$!
    perl -e 'sleep shift; kill 9, shift' "$NS_TIMEOUT" "$p" >/dev/null 2>&1 & k=$!
    wait "$p"; rc=$?
    kill "$k" 2>/dev/null
    exit "$rc"
  )
}

# network_back <ks>: the services the boot window guard turned off back on (ks netrestore checks
# each one, ADR 0037); then, as the last chance, every disabled service on a physical port
# (en*, bridge*): a mark lost or never written (0.19, the 15.10.2026 incident) would otherwise leave
# the Mac without network once ks is gone.
network_back() {
  local name
  [ -x "$1" ] && "$1" netrestore
  ns -listnetworkserviceorder | awk '
    /^\(\*\) / { sub(/^\(\*\) /, ""); name = $0; next }
    /Device: (en|bridge)[0-9]+\)/ { if (name != "") print name }
    { name = "" }' |
    while IFS= read -r name; do
      ns -setnetworkserviceenabled "$name" on && echo "network service turned back on: $name"
    done
}

main() {
  # A stopped watchdog disables the physical network services unless protection is off (the
  # shutdown guard), so it is switched off first; then wait until the old watchdog is gone.
  if [ -x /Library/KillSwitch/ks ]; then /Library/KillSwitch/ks off >/dev/null 2>&1
  elif [ -d /Library/KillSwitch ]; then echo 0 > /Library/KillSwitch/disabled; fi
  # with the VPN on (ADR 0035) the guard would still count as protection on: the target goes first
  rm -f /Library/KillSwitch/vpn-on
  launchctl bootout system/local.killswitch 2>/dev/null
  for _ in $(seq 1 50); do launchctl print system/local.killswitch >/dev/null 2>&1 || break; sleep 0.2; done
  # stops our core and gives the network services their DNS back
  [ -x /Library/KillSwitch/ks ] && /Library/KillSwitch/ks core off >/dev/null 2>&1
  launchctl enable system/local.killswitch.core
  # services disabled at an earlier shutdown, or by a watchdog that raced the switch-off
  network_back /Library/KillSwitch/ks
  pfctl -a com.apple/killswitch -F all 2>/dev/null
  dscl . -delete /Groups/_ksvpn 2>/dev/null
  # NetBird's daemon back to how its installer left it (ks netbird_sync gave it our group)
  nb=/Library/LaunchDaemons/netbird.plist
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :GroupName' "$nb" 2>/dev/null)" = _ksnetbird ]; then
    /usr/libexec/PlistBuddy -c 'Delete :GroupName' "$nb"
    label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$nb" 2>/dev/null)
    # no label, no bootout: "system/" alone is not NetBird's job
    if [ -n "$label" ]; then
      launchctl bootout "system/$label" 2>/dev/null
      for _ in $(seq 1 50); do launchctl print "system/$label" >/dev/null 2>&1 || break; sleep 0.2; done
      launchctl bootstrap system "$nb" 2>/dev/null
    fi
  fi
  dscl . -delete /Groups/_ksnetbird 2>/dev/null
  rm -f /Library/LaunchDaemons/local.killswitch.plist /Library/LaunchDaemons/local.killswitch.core.plist /etc/sudoers.d/killswitch
  rm -rf /Library/KillSwitch
  # the right of the privileged daemon (ADR 0010); the app unregisters the daemon itself
  security authorizationdb remove com.lesha19.KillSwitch.widen >/dev/null 2>&1
  echo "kill switch removed"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced by Helper/tests
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
main "$@"
