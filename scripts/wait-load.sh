#!/bin/bash
# Waits until this Mac's 1-minute load average is below KS_LOAD_MAX, so a gate run (the VM runs on this
# Mac) is not started on a busy machine, where the timing tests (netbird 'up hangs', vpn-on 'switch gap')
# fail for no reason. Gives up after KS_LOAD_WAIT seconds and goes on with a message: it never blocks.
#   scripts/wait-load.sh
# Env: KS_LOAD_MAX (default 20), KS_LOAD_WAIT (seconds, default 600; 0 = do not wait),
#      KS_LOAD_POLL (seconds between looks, default 15), KS_LOAD_FILE (tests: read the load from this file
#      instead of sysctl vm.loadavg). Exit 0 always.
set -u
max=${KS_LOAD_MAX:-20}; wait=${KS_LOAD_WAIT:-600}; poll=${KS_LOAD_POLL:-15}
load() { # the 1-minute load average, or empty when it cannot be read
  if [ -n "${KS_LOAD_FILE:-}" ]; then cat "$KS_LOAD_FILE" 2>/dev/null
  else sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'; fi | awk 'NR == 1 && $1 ~ /^[0-9.]+$/ { print $1 }'
}
below() { awk -v l="$1" -v m="$max" 'BEGIN { exit !(l < m) }'; }
case $wait$max$poll in *[!0-9.]*) echo "wait-load: KS_LOAD_MAX, KS_LOAD_WAIT, KS_LOAD_POLL must be numbers: not waiting" >&2; exit 0;; esac
[ "$wait" != 0 ] || exit 0
l=$(load); [ -n "$l" ] || { echo "wait-load: cannot read the load average: not waiting" >&2; exit 0; }
below "$l" && exit 0
echo "wait-load: load average $l is not below $max (KS_LOAD_MAX): waiting up to ${wait}s (KS_LOAD_WAIT) before the run" >&2
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "${wait%.*}" ]; do
  sleep "$poll"
  l=$(load); [ -n "$l" ] || break
  if below "$l"; then echo "wait-load: load average $l, starting after $((SECONDS - t0))s" >&2; exit 0; fi
done
echo "wait-load: load average still ${l:-?} after $((SECONDS - t0))s: starting anyway (timing tests may fail; rerun them when the Mac is quiet)" >&2
exit 0
