#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Root's files that several ks processes write at once (#50): settings (put_setting, drop_setting,
# "ks set" and a server pick), the off/pause flag and events.log. Each write is a
# whole new file moved into place, under a lock where it reads the old one first, through a
# temporary file of its own: no update is lost, no reader sees a half-written file, and a stray
# file at an old fixed temporary name changes nothing. Nothing is loaded; pfctl is a fake.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DIR="$tmp"; FLAG="$DIR/disabled"; SETTINGS="$DIR/settings"; EVENTS="$DIR/events.log"; DIAG="$tmp/none"
pfctl() { :; }
fails=0
check() {  # check <desc> <condition...>
  local d=$1; shift
  if "$@"; then echo "ok    $d"; else echo "FAIL  $d"; fails=$((fails + 1)); fi
}

# --- put_setting: 40 writers at once, every key ends up in the file
printf 'lan=1\n' > "$SETTINGS"
for i in $(seq 1 40); do put_setting "k$i" "$i" & done; wait
n=$(grep -c '^k[0-9]*=' "$SETTINGS")
check "40 concurrent put_setting: no update lost ($n of 40)" [ "$n" = 40 ]
check "  the line that was there stays" grep -qx 'lan=1' "$SETTINGS"
check "  mode 644, no temporary file left" [ "$(stat -f %Lp "$SETTINGS")" = 644 -a -z "$(find "$DIR" -mindepth 1 -name '*tmp*' -o -mindepth 1 -name '*.new')" ]

# a file (or folder) at the old shared temporary name is not used
mkdir "$SETTINGS.tmp"
put_setting lan 0 2>/dev/null
check "put_setting ignores a stray settings.tmp" grep -qx 'lan=0' "$SETTINGS"
drop_setting k1 2>/dev/null
check "drop_setting ignores it too" [ -z "$(grep '^k1=' "$SETTINGS")" ]
rmdir "$SETTINGS.tmp"

# drop_setting and put_setting racing: each change lands
for i in $(seq 2 21); do drop_setting "k$i" & put_setting "n$i" 1 & done; wait
check "20 drops and 20 puts at once all land" [ "$(grep -c '^k' "$SETTINGS") $(grep -c '^n' "$SETTINGS")" = "19 20" ]
put_setting dns 1 "$tmp/other"
check "put_setting into another file (set_multihop's copy) still works" grep -qx 'dns=1' "$tmp/other"
# set_multihop's copy of the settings (and its lock) in a folder of its own, not in a temporary
# directory others share
check "set_multihop copies the settings into a private folder" [ -n "$(declare -f set_multihop | grep 'd=$(mktemp -d)')" -a -z "$(declare -f set_multihop | grep 's=$(mktemp)')" ]

# "ks set <key>" writes through put_setting, not its own copy of it
check "ks set <switch> uses put_setting" [ -z "$(grep -n '> "\$SETTINGS.tmp"' "$here/../ks")" ]

# --- the off/pause flag: a new file moved into place, never truncated and rewritten
echo 100 > "$FLAG"; ln "$FLAG" "$tmp/flag-old"
disable 0
check "disable writes the flag" [ "$(cat "$FLAG")" = 0 ]
check "  as a new file (the old one never read empty)" [ "$(cat "$tmp/flag-old")" = 100 ]
check "  mode 644, nothing left beside it" [ "$(stat -f %Lp "$FLAG")" = 644 -a -z "$(find "$DIR" -name 'disabled?*')" ]

# --- events.log: 40 lines at once into a full log, each one kept and the log trimmed to 500
: > "$EVENTS"; for i in $(seq 1 499); do echo "old $i"; done > "$EVENTS"
mkdir "$EVENTS.tmp"   # the old fixed temporary name, taken
for i in $(seq 1 40); do log_event "new $i" & done; wait
check "events.log trimmed to 500 lines ($(wc -l < "$EVENTS" | tr -d ' '))" [ "$(wc -l < "$EVENTS" | tr -d ' ')" = 500 ]
check "  every one of 40 concurrent lines kept ($(grep -c ' new ' "$EVENTS"))" [ "$(grep -c ' new ' "$EVENTS")" = 40 ]
check "  the oldest dropped, the rest in order" [ "$(grep -m1 '^old' "$EVENTS")" = "old 40" ]
check "  mode 644" [ "$(stat -f %Lp "$EVENTS")" = 644 ]
rmdir "$EVENTS.tmp"

# --- the lock files are root's alone (0600): a local user who could open one could hold it for
# ever, and every log line, setting, core import and watchdog pass would wait on it (review of #50)
check "settings.lock and events.log.lock are 0600" [ "$(stat -f %Lp "$SETTINGS.lock" "$EVENTS.lock" | sort -u)" = 600 ]
rm -f "$SETTINGS.lock"; (umask 022; : > "$SETTINGS.lock"); ino=$(stat -f %i "$SETTINGS.lock")
put_setting lan 1
check "  one left 0644 by an older ks is replaced by a 0600 one" [ "$(stat -f %Lp "$SETTINGS.lock")" = 600 -a "$(stat -f %i "$SETTINGS.lock")" != "$ino" ]
rm -f "$SETTINGS.lock"; ln -s "$tmp/victim" "$SETTINGS.lock"
put_setting lan 0
check "  a link at its name is never followed" [ ! -e "$tmp/victim" -a ! -L "$SETTINGS.lock" -a "$(stat -f %Lp "$SETTINGS.lock")" = 600 ] && grep -qx lan=0 "$SETTINGS"
# log_event does not wait for a held lock: after a moment the line is appended without the trim
perl -MFcntl=:flock -e 'open my $f, ">>", $ARGV[0] or die; flock $f, LOCK_EX or die; print "held\n"; $| = 1; sleep 15' "$EVENTS.lock" > "$tmp/held" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/held" ] && break; sleep 0.2; done
start=$(date +%s); log_event "while held"; took=$(( $(date +%s) - start ))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "log_event with its lock held elsewhere: done in ${took} s, not 30" [ "$took" -le 4 ]
check "  the line is there" grep -q ' while held$' "$EVENTS"
# the lockf locks: core, dns, netbird, diagnostics
(umask 022; : > "$tmp/old.lock"); ln -s "$tmp/victim2" "$tmp/link.lock"
lock_ready "$tmp/core.lock"; lock_ready "$tmp/old.lock"; lock_ready "$tmp/link.lock"
check "lock_ready: new, 0644 and linked lock files all become plain 0600 files" \
  [ "$(stat -f '%Lp %HT' "$tmp/core.lock" "$tmp/old.lock" "$tmp/link.lock" | sort -u)" = "600 Regular File" -a ! -e "$tmp/victim2" ]
check "every lockf of ks prepares its file with lock_ready" [ -z "$(grep -n 'lockf -k' "$here/../ks" | grep -v lock_ready)" ]

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
