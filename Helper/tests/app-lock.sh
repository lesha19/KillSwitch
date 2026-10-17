#!/bin/bash
# shellcheck disable=SC2329,SC2034 # the stubs and globals are used by install.sh's app_lock
# F3 (#91): launchd runs the root daemon (SMAppService, BundleProgram) from inside the app bundle,
# so install.sh makes our app in /Applications root:wheel and writable by nobody else, in both
# modes (a first install and the daemon's --upgrade after an update). app_lock runs against a fake
# /Applications with chown and chmod stubbed: nothing changes owner, nothing runs as root.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
code() { grep -vE '^[[:space:]]*#' "$1"; }   # without comment lines

eval "$(sed -n '/^app_lock() {/,/^}/p' "$here/../install.sh")"
check "install.sh has app_lock" "$(type -t app_lock)" function

app() {  # app <name> <bundle id>
  mkdir -p "$tmp/apps/$1/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' \
    "$2" > "$tmp/apps/$1/Contents/Info.plist"
}
app KillSwitch.app com.lesha19.KillSwitch
app "Kill Switch 2.app" com.lesha19.KillSwitch   # renamed by the user: still ours
app Other.app com.example.Other
mkdir -p "$tmp/elsewhere"; app Linked.app com.lesha19.KillSwitch
mv "$tmp/apps/Linked.app" "$tmp/elsewhere/Linked.app"; ln -s "$tmp/elsewhere/Linked.app" "$tmp/apps/Linked.app"

APPS_DIR="$tmp/apps"; APP_ID=com.lesha19.KillSwitch
L="$tmp/log"
chown() { echo "chown $*" >> "$L"; }
chmod() { echo "chmod $*" >> "$L"; }
: > "$L"
app_lock 2> "$tmp/err"
check "our app: root:wheel, recursively" "$(grep -cxF "chown -hR -P root:wheel $tmp/apps/KillSwitch.app" "$L")" 1
check "our app: writable by nobody else, recursively" "$(grep -cxF "chmod -R go-w $tmp/apps/KillSwitch.app" "$L")" 1
check "our app: ACLs removed, recursively" "$(grep -cxF "chmod -R -N $tmp/apps/KillSwitch.app" "$L")" 1
check "our app under another name: locked too" "$(grep -cF "$tmp/apps/Kill Switch 2.app" "$L")" 3
check "another app: untouched" "$(grep -c 'Other.app' "$L")" 0
check "a link named like an app: not followed" "$(grep -c 'Linked.app' "$L")" 0
check "nothing else is changed" "$(wc -l < "$L" | tr -d ' ')" 6
check "nothing on stderr" "$(cat "$tmp/err")" ""

# a failure is said, and does not stop the install (the bundle stays as it was before #91)
chown() { return 1; }
check "a failed chown is reported" "$(app_lock 2>&1 >/dev/null | grep -c 'cannot lock')" 2
unset -f chown chmod

# a FIFO in place of Info.plist must not hang PlistBuddy
mkdir -p "$tmp/apps/Fifo.app/Contents"; mkfifo "$tmp/apps/Fifo.app/Contents/Info.plist"
check "a FIFO Info.plist: skipped, no hang" "$(perl -e 'alarm 5; exec @ARGV' bash -c "$(declare -f app_lock); APPS_DIR='$tmp/apps'; APP_ID=x; chown(){ :; }; chmod(){ :; }; app_lock; echo done" 2>&1 | tail -1)" "done"
rm -rf "$tmp/apps/Fifo.app"

# no app at all (a build run from Xcode): nothing happens
rm -rf "$tmp/apps"; mkdir "$tmp/apps"
check "no app in /Applications: nothing, exit 0" "$(app_lock 2>&1; echo $?)" 0

# --- main: the lock in both modes, before the marker that says the install is done
main_body=$(code "$here/../install.sh" | sed -n '/^main() {/,/^}/p')
check "main calls app_lock once" "$(grep -c '^  app_lock$' <<<"$main_body")" 1
check "app_lock comes before write_marker" \
  "$(grep -nE '^  (app_lock|write_marker)$' <<<"$main_body" | cut -d: -f2 | tr -d ' ' | paste -sd' ' -)" "app_lock write_marker"
check "app_lock is after the --upgrade branch (runs in both modes)" \
  "$(awk '/^  fi$/ && !f {f=NR} /^  app_lock$/ {a=NR} END {print (f && a > f) ? "yes" : "no"}' <<<"$main_body")" yes
check "install.sh looks in /Applications for our bundle id" \
  "$(code "$here/../install.sh" | grep -cxE 'APPS_DIR=/Applications; APP_ID=com\.lesha19\.KillSwitch')" 1

# --- the helper is current: the daemon runs "install.sh --lock-app" (only the lock), also checked
# in the daemon's source, so a user-owned bundle is locked again without a helper version change
check "install.sh has a --lock-app mode that only locks" \
  "$(code "$here/../install.sh" | sed -n '/^main() {/,/^}/p' | grep -A2 -- '--lock-app' | grep -cE '^    app_lock; exit 0$')" 1
check "--lock-app comes before the install steps" \
  "$(code "$here/../install.sh" | sed -n '/^main() {/,/^}/p' | grep -nE -- '--lock-app|^  app_lock$|^  elif|^  if \[ "\$\{1:-\}" = --upgrade' | head -1 | grep -c -- '--lock-app')" 1
check "Runner .current branch runs --lock-app" \
  "$(code "$here/../../HelperDaemon/Runner.swift" | awk '/case \.current:/ {f=1} /case \.upgrade:/ {f=0} f' | grep -c -- '"--lock-app"')" 1

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
