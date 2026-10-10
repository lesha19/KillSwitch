#!/bin/bash
# Checks the SHA256SUMS that scripts/release.sh writes next to the release files (nothing is
# built or signed here: the script is only sourced for its functions).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../../scripts/release.sh
. "$here/../../scripts/release.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

printf 'dmg\n' > "$tmp/KillSwitch-0.13.dmg"
printf '<rss/>\n' > "$tmp/appcast.xml"
printf 'geo\n' > "$tmp/geosite.dat"
mkdir "$tmp/other"

write_sums "$tmp" KillSwitch-0.13.dmg appcast.xml geosite.dat
check "one line per file, by bare name" "$(awk '{ print $2 }' "$tmp/SHA256SUMS" | paste -sd' ' -)" \
  "KillSwitch-0.13.dmg appcast.xml geosite.dat"
check "the format shasum -c reads" "$(cd "$tmp" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 && echo ok)" ok
check "bare names: checked in the folder of the files" "$(cd "$tmp/other" && shasum -a 256 -c ../SHA256SUMS >/dev/null 2>&1 && echo ok || echo no)" no
printf 'tampered\n' > "$tmp/appcast.xml"
check "a changed file is caught" "$(cd "$tmp" && shasum -a 256 -c SHA256SUMS 2>/dev/null | grep -c FAILED)" 1
check "a missing file fails the release" "$(write_sums "$tmp" nope.dmg 2>/dev/null && echo written || echo refused)" refused

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
