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
[ "$(wc -l <<<"$cmds")" -eq 14 ] && ok "sudoers lists 14 passwordless commands" || bad "sudoers commands: $cmds"
grep -qx 'core traffic' <<<"$cmds" && ok "sudoers: core traffic (the menu bar speed)" || bad "sudoers: no core traffic"
grep -qx 'core connections' <<<"$cmds" && ok "sudoers: core connections (the «Трафик» window)" || bad "sudoers: no core connections"
grep -qx 'diag report \*' <<<"$cmds" && ok "sudoers: diag report («Собрать отчёт», ADR 0021)" || bad "sudoers: no diag report"
# settings, ad blocking included, keep asking for the password (ADR 0010 right in the daemon)
grep -q '^set' <<<"$cmds" && bad "sudoers: a set command without password" || ok "sudoers: no set command"
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
refuses core traffic now
refuses core connections all
refuses core connections ""
takes core delay "DE trojan \"q\""
refuses core delay
refuses core delay a b
refuses core delay $'a\rb'
takes core refresh "/Users/me/Library/Caches/com.lesha19.KillSwitch/sub.json"
refuses core refresh
refuses core refresh relative.json
refuses core refresh $'/tmp/a\nb'
refuses core refresh /a /b
takes diag report /Users/me/Desktop
refuses diag report Desktop
refuses diag report /a /b
refuses diag status
# the rest needs the admin password and is checked further on
takes set lan 0
takes set adblock 1
takes set blockadult 1
takes set doh https://dns.example.com/dns-query
takes core import /x.json

# --- install.sh: the user it writes into sudoers
eval "$(sed -n '/^valid_user() {/,/^}/p' "$here/../install.sh")"
me=$(id -un)
if [ "$(id -u)" -ge 500 ]; then
  valid_user "$me" && ok "install.sh: takes the user running it ($me)" || bad "install.sh: refused $me"
fi
for u in ALL root daemon %admin '#0' 'a b' $'me\nx' "$me ALL" "$me,root" nosuchuser_ks_test -x ''; do
  valid_user "$u" && bad "install.sh: took user $(printf '%q' "$u")" || ok "install.sh: refuses user $(printf '%q' "$u")"
done

# every command that writes the core's config runs under the core lock (rotation, refresh and
# import write the same files): ks's own dispatch asks core_lock_wanted (ADR 0023)
for c in "core import /f" "core refresh /f" "set splitapps x" "set multihop off" "set diag 1" "set adblock 1" "set blockadult 1" "set blocksocial 0" "set blockbetting 1" "set doh https://dns.example.com/q" "_regen" "repair" "core select Сервер DE"; do
  # shellcheck disable=SC2086 # the command's words
  core_lock_wanted $c && ok "under the core lock: ks $c" || bad "not under the core lock: ks $c"
done
core_lock_wanted core state && bad "ks core state waits for the core lock" || ok "not under the core lock: ks core state"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
