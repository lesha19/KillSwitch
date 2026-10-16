#!/bin/bash
# shellcheck disable=SC2329,SC2034 # the stubs and KS are used by the sourced uninstall.sh
# Uninstall never leaves the core job or our DNS behind (#92): with ks missing or "ks core off"
# failing, local.killswitch.core is booted out and every network service's DNS goes back to
# automatic before /Library/KillSwitch is removed, and the output says so. main runs against
# stubs: launchctl, networksetup, rm, pfctl, dscl, security and ks only log; nothing is removed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
[ "$(id -u)" != 0 ] || { echo "skip  uninstall.sh: not run as root"; exit 0; }
# main writes /Library/KillSwitch/disabled by a redirect no stub catches: only where it is not installed
[ ! -e /Library/KillSwitch ] || { echo "skip  uninstall.sh: /Library/KillSwitch exists here"; exit 0; }
# PlistBuddy is called by absolute path (no stub): only reading is allowed, so not with a NetBird ks changed
[ "$(/usr/libexec/PlistBuddy -c 'Print :GroupName' /Library/LaunchDaemons/netbird.plist 2>/dev/null)" != _ksnetbird ] ||
  { echo "skip  uninstall.sh: NetBird's plist has our group, main would edit it"; exit 0; }

# shellcheck source=../uninstall.sh
. "$here/../uninstall.sh"
L="$tmp/log"
printf '#!/bin/bash\necho "ks $*" >> %q\n[ "$*" != "core off" ] || [ ! -e %q ]\n' "$L" "$tmp/core-fails" > "$tmp/ks"
chmod +x "$tmp/ks"

# run <ks path>: main against the stubs, its output in $tmp/out, every call in $L
run() {
  : > "$L"
  (
    KS=$1
    launchctl() { echo "launchctl $*" >> "$L"; [ "$1" != print ]; }
    networksetup() {
      echo "networksetup $*" >> "$L"
      case "$1" in
        -listallnetworkservices) printf '%s\n' 'An asterisk (*) denotes that a network service is disabled.' 'Wi-Fi' '*Thunderbolt Bridge' ;;
        -setdnsservers) [ "$2" != "$(cat "$tmp/dns-fails" 2>/dev/null)" ] ;;
      esac
    }
    rm() { echo "rm $*" >> "$L"; }
    pfctl() { :; }; dscl() { :; }; security() { :; }; sleep() { :; }
    # functions win over any PATH uninstall.sh sets; never reach main if one is not a stub
    for f in launchctl networksetup rm pfctl dscl security; do
      [ "$(type -t "$f")" = function ] || { echo "ABORT: $f is not a stub"; exit 99; }
    done
    case "$KS" in "$tmp"/*) ;; *) echo "ABORT: KS is $KS"; exit 99 ;; esac
    main
  ) > "$tmp/out" 2>&1
}
dns_reset_before_rm() {
  local w t r
  w=$(grep -n '^networksetup -setdnsservers Wi-Fi Empty$' "$L" | cut -d: -f1)
  t=$(grep -n '^networksetup -setdnsservers Thunderbolt Bridge Empty$' "$L" | cut -d: -f1)
  r=$(grep -n '^rm -rf /Library/KillSwitch$' "$L" | cut -d: -f1)
  [ -n "$w" ] && [ -n "$t" ] && [ -n "$r" ] && [ "$w" -lt "$r" ] && [ "$t" -lt "$r" ]
}

for c in "ks missing:$tmp/no-ks" "ks core off fails:$tmp/ks"; do
  name=${c%%:*}; : > "$tmp/core-fails"
  run "${c#*:}"
  grep -qx 'launchctl bootout system/local.killswitch.core' "$L" && ok "$name: the core job booted out" || bad "$name: core job left: $(cat "$L")"
  dns_reset_before_rm && ok "$name: every service's DNS automatic before the folder goes" || bad "$name: DNS not reset first: $(cat "$L")"
  grep -q 'DNS' "$tmp/out" && ok "  said so" || bad "  silent: $(cat "$tmp/out")"
done

rm -f "$tmp/core-fails"; run "$tmp/ks"
grep -qx 'ks core off' "$L" && ! grep -q -- '-setdnsservers' "$L" && ok "ks core off works: DNS left as ks restored it" || bad "core off ok: $(cat "$L")"
grep -qx 'launchctl bootout system/local.killswitch.core' "$L" && ok "  the core job booted out" || bad "  core job left: $(cat "$L")"

: > "$tmp/core-fails"; echo Wi-Fi > "$tmp/dns-fails"; run "$tmp/ks"
grep -q 'Wi-Fi' "$tmp/out" && grep -qx 'networksetup -setdnsservers Thunderbolt Bridge Empty' "$L" &&
  ok "a service whose DNS cannot be reset is named, the rest still reset" || bad "dns fails: $(cat "$tmp/out")"
rm -f "$tmp/dns-fails"

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
