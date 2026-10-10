#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Checks the system DNS handling of Helper/ks against a fake dynamic store (scutil and
# networksetup are replaced by functions here); the real system is not touched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
store="$tmp/store"; mkdir "$store"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
DNS_STATE="$CORE_DIR/dns-state"; EVENTS="$tmp/events.log"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"   # no rotation unless set below
core_rotate_bg() { echo rotate >> "$tmp/rotations"; }

# Fake store: one file per key, lines "A<tab>key<tab>v1 v2" (array) or "S<tab>key<tab>value".
kf() { echo "$store/$(tr '/' '|' <<<"$1")"; }
scutil() {
  local line cmd arg dict="" f k i
  while IFS= read -r line; do
    cmd=${line%% *}; arg=${line#* }
    case "$cmd" in
      list) i=0
            for f in "$store"/*; do
              [ -e "$f" ] || continue
              k=$(basename "$f" | tr '|' '/')
              [[ "$k" =~ ^$arg$ ]] && { echo "  subKey [$i] = $k"; i=$((i + 1)); }
            done ;;
      show) f=$(kf "$arg")
            if [ -f "$f" ]; then
              echo "<dictionary> {"
              while IFS=$'\t' read -r t k v; do
                if [ "$t" = A ]; then
                  echo "  $k : <array> {"; i=0
                  for x in $v; do echo "    $i : $x"; i=$((i + 1)); done
                  echo "  }"
                else echo "  $k : $v"; fi
              done < "$f"
              echo "}"
            else echo "  No such key"; fi ;;
      d.init) dict="" ;;
      get) f=$(kf "$arg"); [ -f "$f" ] && dict=$(cat "$f") ;;
      d.add) k=${arg%% *}; v=${arg#* \* }
             dict=$(grep -v "	$k	" <<<"$dict"; printf 'A\t%s\t%s' "$k" "$v") ;;
      d.remove) dict=$(grep -v "	$arg	" <<<"$dict") ;;
      set) grep -v '^$' <<<"$dict" > "$(kf "$arg")" ;;
      remove) rm -f "$(kf "$arg")" ;;
    esac
  done
}
networksetup() { echo "networksetup $*" >> "$tmp/networksetup.log"; }
dns_locked() { "dns_$1"; }   # no lockf in tests
put() { printf '%s\n' "${@:2}" | tr '|' '\t' > "$(kf "$1")"; }
get() { local f; f=$(kf "$1"); [ -f "$f" ] && awk -F'\t' -v k="${2:-ServerAddresses}" '$2 == k { print $3 }' "$f" || echo '!'; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

W=State:/Network/Service/W; WS=Setup:/Network/Service/W
E=Setup:/Network/Service/E; T=State:/Network/Service/T
put "$WS/Interface" "S|DeviceName|en0" "S|UserDefinedName|Wi-Fi"
put "$W/IPv4" "S|InterfaceName|en0" "A|Addresses|192.168.1.10"
put "$W/DNS" "A|ServerAddresses|192.168.1.1" "A|SearchDomains|lan"
put "$E/Interface" "S|DeviceName|en5"
put "$E/DNS" "A|ServerAddresses|9.9.9.9"
put "Setup:/Network/Service/T/Interface" "S|Type|VPN"
put "$T/IPv4" "S|InterfaceName|utun3"
put "$T/DNS" "A|ServerAddresses|100.100.100.100" "A|SupplementalMatchDomains|ts.net"

check "snapshot: physical services only" "$(dns_snapshot | sort | tr '\t' '=' | paste -sd' ' -)" \
  "$E/DNS=9.9.9.9 $WS/DNS=! $W/DNS=192.168.1.1"
changed=$(dns_apply | sort | paste -sd' ' -)
check "apply: changed keys" "$changed" "$E/DNS $WS/DNS $W/DNS"
check "apply: Wi-Fi State" "$(get "$W/DNS")" 127.0.0.1
check "apply: Wi-Fi Setup created" "$(get "$WS/DNS")" 127.0.0.1
check "apply: inactive Ethernet Setup" "$(get "$E/DNS")" 127.0.0.1
check "apply: search domains kept" "$(get "$W/DNS" SearchDomains)" lan
check "apply: Tailscale untouched" "$(get "$T/DNS")" 100.100.100.100
check "apply again: nothing to do" "$(dns_apply)" ""

put "$W/DNS" "A|ServerAddresses|192.168.1.254" "A|SearchDomains|lan"   # DHCP renew
check "overwritten by the system: set again" "$(dns_apply)" "$W/DNS"
check "  and the new value is the original" "$(awk -F'\t' -v p="$W/DNS" '$1 == p { print $2 }' "$DNS_STATE")" 192.168.1.254

dns_restore
check "restore: Wi-Fi State" "$(get "$W/DNS")" 192.168.1.254
check "restore: Wi-Fi Setup removed again" "$(get "$WS/DNS")" '!'
check "restore: Ethernet manual DNS" "$(get "$E/DNS")" 9.9.9.9
check "restore: search domains" "$(get "$W/DNS" SearchDomains)" lan
check "restore: state file gone" "$([ -e "$DNS_STATE" ] && echo yes || echo no)" no

dns_apply >/dev/null
put "$E/DNS" "A|ServerAddresses|8.8.8.8"   # changed by hand while the core ran
dns_restore
check "restore leaves a value someone else set" "$(get "$E/DNS")" 8.8.8.8

dns_apply >/dev/null
sed -i '' '1s/.*/boot 1/' "$DNS_STATE"   # saved before a reboot
dns_restore
check "originals of an earlier boot are not applied" "$(get "$W/DNS")" 127.0.0.1
check "  and dropped" "$([ -e "$DNS_STATE" ] && echo yes || echo no)" no
put "$W/DNS" "A|ServerAddresses|192.168.1.1"

printf 'Wi-Fi\t192.168.1.1\nEthernet\t\n' > "$CORE_DIR/dns-saved"   # left by the networksetup version
check "migration: apply waits a round" "$(dns_apply)" ""
check "migration: old DNS put back" "$(paste -sd' ' - < "$tmp/networksetup.log")" \
  "networksetup -setdnsservers Wi-Fi 192.168.1.1 networksetup -setdnsservers Ethernet Empty"
check "migration: once" "$([ -e "$CORE_DIR/dns-saved" ] && echo yes || echo no)" no
check "migration: store untouched" "$(get "$W/DNS")" 192.168.1.1

CORE_JOB=fake
launchctl() { [ "$LAUNCHD" != unloaded ] || return 1; echo "state = $LAUNCHD"; }
LAUNCHD=running; core_guard
check "watchdog: core running -> DNS set" "$(get "$W/DNS")" 127.0.0.1
LAUNCHD=waiting; core_guard
check "watchdog: core just stopped -> DNS kept" "$(get "$W/DNS")" 127.0.0.1
CORE_DOWN=$(( $(date +%s) - 6 )); core_guard
check "watchdog: core down 5 s -> DNS restored" "$(get "$W/DNS")" 192.168.1.1
LAUNCHD=running; core_guard
check "watchdog: core back -> DNS set" "$(get "$W/DNS")" 127.0.0.1
LAUNCHD=unloaded; core_guard
check "watchdog: core unloaded -> DNS restored" "$(get "$W/DNS")" 192.168.1.1
grep -q 'core not running: DNS restored' "$EVENTS" && echo "ok    events logged" || { echo "FAIL  events"; fails=$((fails + 1)); }
check "watchdog: no approved names -> no rotation" "$(cat "$tmp/rotations" 2>/dev/null)" ""
echo de.example.com > "$APPROVED_HOSTS"; ROT_NEXT=1
LAUNCHD=waiting; core_guard
check "watchdog: core not running -> no rotation" "$(cat "$tmp/rotations" 2>/dev/null)" ""
LAUNCHD=running; core_guard
check "watchdog: core running, check due -> rotation started" "$(cat "$tmp/rotations" 2>/dev/null)" rotate
LAUNCHD=running; core_guard
check "watchdog: not again at once" "$(cat "$tmp/rotations" 2>/dev/null)" rotate

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
