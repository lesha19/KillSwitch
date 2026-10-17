#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The watchdog's one-second loop never hangs (#88, audit M6): what it asks launchd and configd and
# the DNS lock it takes are bounded (CALL_TIMEOUT, DNS_TIMEOUT). A call that does not answer in time
# changes nothing (the core's state, the DNS, no standby: the rules keep blocking) and is asked
# again on the next pass. The fakes hang in /bin/sleep; nothing of the system is touched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"; DNS_STATE="$CORE_DIR/dns-state"; EVENTS="$tmp/events.log"; DIAG="$tmp/none"
FOREIGN_VPN="$tmp/foreign-vpn"; VPN_ON="$tmp/vpn-on"; APPROVED_HOSTS="$tmp/none"; CORE_JOB=fake
CALL_TIMEOUT=1; DNS_TIMEOUT=1
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
hang() { /bin/sleep 20; }
took() { echo $((SECONDS - s)); }
quick() { [ "$(took)" -le 8 ]; }   # the 1 s bound and the forks around it; the fakes sleep 20, a loaded VM still passes
utun_addrs() { :; }   # no tunnels: foreign_tuns asks nothing more
dns_locked() { echo "dns $*" >> "$tmp/dns"; return 1; }
boot_id() { echo B1; }

# --- launchd does not answer: the core's state and the DNS as they were
launchctl() { hang; }
CORE_STATE=on; CORE_PID=100; echo "boot B1" > "$DNS_STATE"
s=$SECONDS; core_guard
quick && [ "$CORE_STATE" = on ] && [ "$CORE_PID" = 100 ] && [ ! -e "$tmp/dns" ] &&
  ok "launchd hangs: core_guard back within the bound, core state kept, DNS not touched" ||
  bad "launchd hangs: $(took) s, core $CORE_STATE pid $CORE_PID, $(cat "$tmp/dns" 2>/dev/null)"
launchctl() { return 113; }
core_guard
[ "$CORE_STATE" = off ] && [ "$(cat "$tmp/dns" 2>/dev/null)" = "dns restore watch" ] &&
  ok "  launchd says not loaded: the DNS restored, the watchdog's way (no wait for the lock)" || bad "  not loaded: $CORE_STATE, $(cat "$tmp/dns" 2>/dev/null)"

# --- configd does not answer while the core runs: nothing written, back in time
launchctl() { echo "state = running"; }
scutil() { hang; }
rm -f "$tmp/dns"; s=$SECONDS; core_guard
quick && [ "$CORE_STATE" = on ] && [ ! -e "$tmp/dns" ] &&
  ok "configd hangs: no DNS write, core_guard back within the bound" || bad "configd hangs: $(took) s, core $CORE_STATE, $(cat "$tmp/dns" 2>/dev/null)"
s=$SECONDS; out=$(configd_ifs)
quick && [ -z "$out" ] && ok "configd hangs: net_guard's interface list empty in time (the network is looked at again)" || bad "configd_ifs: $(took) s, '$out'"

# --- the DNS lock: the watchdog never waits for it, and what runs under it is killed in time
eval "$(sed -n '/^dns_locked() {/,/^}/p' "$here/../ks")"   # the real one back over the stub above
lockf() { echo "$*" > "$tmp/lockf"; hang; }
s=$SECONDS; dns_locked apply watch; rc=$?
quick && [ "$rc" != 0 ] && [[ "$(cat "$tmp/lockf")" == "-k -t 0 $CORE_DIR/dns.lock "*" _dns apply" ]] &&
  ok "DNS from the watchdog: the lock not waited for (-t 0), killed after DNS_TIMEOUT, failed (next pass again)" ||
  bad "DNS lock: $(took) s, rc $rc, lockf $(cat "$tmp/lockf")"
lockf() { echo "$*" > "$tmp/lockf"; }
dns_locked restore
[[ "$(cat "$tmp/lockf")" == "-k -t 30 $CORE_DIR/dns.lock "*" _dns restore" ]] && ok "  ks core on|off: still waits up to 30 s for it" || bad "  ks core lock: $(cat "$tmp/lockf")"

# --- dns_apply killed between two keys: the originals are already in the state file
dns_snapshot() { printf 'Setup:/A\t8.8.8.8\nState:/B\t1.1.1.1\n'; }
dns_migrate() { return 1; }
n=0; dns_put() { echo "$1" >> "$tmp/puts"; kill -9 "$BASHPID"; }
rm -f "$DNS_STATE" "$tmp/puts"
{ ( dns_apply ) >/dev/null 2>&1; } 2>/dev/null
[ "$(cat "$tmp/puts")" = "Setup:/A" ] && grep -q "$(printf 'Setup:/A\t8.8.8.8')" "$DNS_STATE" 2>/dev/null && grep -q "$(printf 'State:/B\t1.1.1.1')" "$DNS_STATE" &&
  ok "dns_apply killed at the first key: both originals already recorded, nothing lost" ||
  bad "dns_apply killed mid-write: state $(cat "$DNS_STATE" 2>/dev/null | tr '\n\t' '|-')"

# --- standby (ADR 0018): launchd not answering counts as our core running, so no standby
utun_addrs() { echo "utun9 198.18.0.5"; }   # another program's VPN tunnel
launchctl() { hang; }
s=$SECONDS; if vpn_standby; then r=1; else r=0; fi
quick && [ "$r" = 0 ] && ok "launchd hangs: no standby, the rules keep blocking, in time" || bad "standby with launchd hanging: $r, $(took) s"
launchctl() { return 113; }
vpn_standby && ok "  launchd says not loaded, another VPN's tunnel: standby as before" || bad "  no standby next to another VPN"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
