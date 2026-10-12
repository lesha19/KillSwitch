#!/bin/bash
# The helper tests as CI runs them (.github/workflows/ci.yml), before a push: a copy of the files
# git tracks (the working tree's, uncommitted changes included) in a temporary folder, so none of
# what Helper/fetch-*.sh leaves behind (xray, mihomo, geosite.dat, geoip.dat, geoip.metadb) is
# there, and no core: neither the installed one in /Library/KillSwitch/core nor XRAY/MIHOMO from
# the environment. Every Helper/tests/*.sh, 6 at a time; exit 1 when one fails.
#   scripts/test-helper-ci.sh [bash]   (default /bin/bash; also run it with Homebrew's bash 5)
# The normal run, with the cores and geodata: XRAY=$PWD/Helper/xray MIHOMO=$PWD/Helper/mihomo and
# the same loop over Helper/tests/*.sh.
set -u
sh=${1:-/bin/bash}
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/src" "$tmp/out"
(cd "$root" && git ls-files -z | while IFS= read -r -d '' f; do [ ! -e "$f" ] || printf '%s\0' "$f"; done |
  /usr/bin/xargs -0 tar -cf - --) | tar -xf - -C "$tmp/src" || { echo "could not copy the tracked files" >&2; exit 1; }
export XRAY=/nonexistent/xray MIHOMO=/nonexistent/mihomo
cd "$tmp/src" || exit 1
printf '%s\0' Helper/tests/*.sh | /usr/bin/xargs -0 -P 6 -I{} "$sh" -c \
  'n=$(basename "$1" .sh); "$0" "$1" > "$2/$n.out" 2>&1; echo $? > "$2/$n.rc"' "$sh" {} "$tmp/out"
fails=0
for r in "$tmp/out"/*.rc; do
  n=$(basename "$r" .rc)
  [ "$(cat "$r")" = 0 ] && continue
  fails=$((fails + 1)); echo "== $n"; grep '^FAIL' "$tmp/out/$n.out" | cut -c1-300
done
echo "$("$sh" -c 'echo "$BASH_VERSION"'): $(ls "$tmp/out"/*.rc | wc -l | tr -d ' ') files, $(cat "$tmp/out"/*.out | grep -c '^ok') ok," \
  "$(cat "$tmp/out"/*.out | grep -c '^skip') skip, $fails failed"
[ "$fails" = 0 ]
