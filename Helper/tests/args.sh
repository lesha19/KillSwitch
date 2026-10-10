#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Arguments of the commands sudoers lets the user run without a password (passwordless_args_ok of
# Helper/ks): exactly what the app sends, nothing more, whatever sudoers says. No root.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
takes()   { if passwordless_args_ok "$@"; then ok "takes: ks $*"; else bad "refused: ks $*"; fi; }
refuses() { if passwordless_args_ok "$@"; then bad "took: ks $(printf '%q ' "$@")"; else ok "refuses: ks $(printf '%q ' "$@")"; fi; }

# every passwordless command of install.sh's sudoers, as written there
eval "$(sed -n '/^sudoers_text() {/,/^}/p' "$here/../install.sh")"
cmds=$(sudoers_text someone /k | sed -n 's/^someone ALL=(root) NOPASSWD: //p' | tr ',' '\n' | sed 's/^ *\/k //')
[ "$(wc -l <<<"$cmds")" -eq 11 ] && ok "sudoers lists 11 passwordless commands" || bad "sudoers commands: $cmds"
while IFS= read -r c; do
  [[ "$c" == *'*' ]] && continue
  # shellcheck disable=SC2086 # the command's words
  { takes $c; refuses $c extra; }
done <<<"$cmds"

takes core select "🚀 Выбор сервера" "NL reality"
refuses core select g
refuses core select g p extra
refuses core select $'g\nx' p
refuses core select g "$(printf 'p%.0s' $(seq 300))"
takes core delay "DE trojan \"q\""
refuses core delay
refuses core delay a b
refuses core delay $'a\rb'
takes core refresh "/Users/me/Library/Caches/com.lesha19.KillSwitch/sub.json"
refuses core refresh
refuses core refresh relative.json
refuses core refresh $'/tmp/a\nb'
refuses core refresh /a /b
# the rest needs the admin password and is checked further on
takes set lan 0
takes core import /x.json

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
