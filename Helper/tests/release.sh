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

# #16: a beta goes into the stable release's appcast as a <sparkle:channel>beta</sparkle:channel>
# item; the app reads only releases/latest/download/appcast.xml.
item() {  # item <build> [channel]
  printf '        <item>\n            <title>%s</title>\n' "$1"
  if [ -n "${2:-}" ]; then printf '            <sparkle:channel>%s</sparkle:channel>\n' "$2"; fi
  printf '            <sparkle:version>%s</sparkle:version>\n' "$1"
  printf '            <enclosure url="https://x/%s.dmg" length="1" type="application/octet-stream" sparkle:edSignature="sig%s"/>\n        </item>\n' "$1" "$1"
}
feed() {  # feed <item>...
  printf '<?xml version="1.0" standalone="yes"?>\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n    <channel>\n        <title>KillSwitch</title>\n'
  for i in "$@"; do printf '%s\n' "$i"; done
  printf '    </channel>\n</rss>\n'
}
builds() { sed -nE 's|.*<sparkle:version>([0-9]+)</sparkle:version>.*|\1|p' "$1" | paste -sd' ' -; }
feed "$(item 23)" "$(item 22 beta)" > "$tmp/stable.xml"
feed "$(item 24 beta)" > "$tmp/beta.xml"
feed > "$tmp/empty.xml"
appcast_with_beta "$tmp/stable.xml" "$tmp/beta.xml" > "$tmp/merged.xml"
check "merged appcast is well-formed XML" "$(xmllint --noout "$tmp/merged.xml" 2>&1 && echo ok)" ok
check "the new beta, then the stable; the old beta is gone" "$(builds "$tmp/merged.xml")" "24 23"
check "the stable item keeps its signature" "$(grep -c 'sparkle:edSignature="sig23"' "$tmp/merged.xml")" 1
check "only the beta item is in the beta channel" "$(grep -c '<sparkle:channel>beta</sparkle:channel>' "$tmp/merged.xml")" 1
appcast_with_beta "$tmp/empty.xml" "$tmp/beta.xml" > "$tmp/merged-empty.xml"
check "an appcast without items gets the beta" "$(builds "$tmp/merged-empty.xml")" 24
check "a beta appcast without a beta item is refused" \
  "$(appcast_with_beta "$tmp/stable.xml" "$tmp/empty.xml" >/dev/null 2>&1 && echo merged || echo refused)" refused

# the stable release's SHA256SUMS follows its rewritten appcast.xml
printf '<rss/>\n' > "$tmp/appcast.xml"
write_sums "$tmp" KillSwitch-0.13.dmg appcast.xml
cp "$tmp/merged.xml" "$tmp/appcast.xml"
sums_replace "$tmp/SHA256SUMS" appcast.xml "$tmp/appcast.xml"
check "new appcast hash, the other lines kept" "$(cd "$tmp" && shasum -a 256 -c SHA256SUMS 2>/dev/null | grep -c ': OK')" 2
check "a name not in SHA256SUMS is refused" \
  "$(sums_replace "$tmp/SHA256SUMS" nope.xml "$tmp/appcast.xml" 2>/dev/null && echo replaced || echo refused)" refused

# GPL-3.0 §6 (#36): each release carries the source of the bundled mihomo (and Xray-core, MPL-2.0)
# for the tag pinned in Helper/fetch-*.sh, checked against SOURCE_SHA256 there. Offline: the
# "GitHub" here is a file:// tree (KS_SOURCE_BASE).
mkdir -p "$tmp/gh/Org/core/archive/refs/tags" "$tmp/pins" "$tmp/src"
printf 'core source\n' > "$tmp/gh/Org/core/archive/refs/tags/v1.2.tar.gz"
good=$(shasum -a 256 < "$tmp/gh/Org/core/archive/refs/tags/v1.2.tar.gz" | cut -d' ' -f1)
pin() { printf 'VERSION=%s\nSHA256=%064d\nSOURCE_SHA256=%s   # comment\n' "$1" 0 "$2" > "$tmp/pins/fetch.sh"; }
export KS_SOURCE_BASE="file://$tmp/gh"
pin v1.2 "$good"
check "the pinned tag's tarball, named after repo and tag" "$(core_source "$tmp/pins/fetch.sh" Org/core "$tmp/src")" \
  core-v1.2-source.tar.gz
check "its content is the archive of that tag" "$(cat "$tmp/src/core-v1.2-source.tar.gz")" "core source"
pin v1.2 "$(printf '%064d' 1)"
rm -f "$tmp/src/"*
check "another sha256 is refused" "$(core_source "$tmp/pins/fetch.sh" Org/core "$tmp/src" 2>/dev/null || echo refused)" refused
check "and nothing is left to publish" "$(ls "$tmp/src" | wc -l | tr -d ' ')" 0
pin v1.2 ""
check "no pin is refused" "$(core_source "$tmp/pins/fetch.sh" Org/core "$tmp/src" 2>/dev/null || echo refused)" refused
pin v9.9 "$good"
check "a missing tag is refused" "$(core_source "$tmp/pins/fetch.sh" Org/core "$tmp/src" 2>/dev/null || echo refused)" refused
unset KS_SOURCE_BASE
for f in fetch-mihomo.sh fetch-xray.sh; do
  check "$f pins the source tarball" "$(grep -cE '^SOURCE_SHA256=[0-9a-f]{64}( |$)' "$here/../$f")" 1
done

# ADR 0010, 0025: the daemon and killswitch are trusted by their signature, so release.sh refuses
# either without the hardened runtime or with an ad hoc signature. codesign's answer is faked here.
signed_as() { flags=$1; codesign() { printf 'CodeDirectory v=20500 size=1 flags=%s hashes=1\n' "$flags"; }; }
runtime() { runtime_signed "$tmp/tool" && echo yes || echo no; }
signed_as '0x10000(runtime)'
check "hardened runtime, Developer ID: taken" "$(runtime)" yes
signed_as '0x10002(adhoc,runtime)'
check "ad hoc with the runtime: refused" "$(runtime)" no
signed_as '0x0(none)'
check "without the runtime: refused" "$(runtime)" no
unset -f codesign
printf 'not code\n' > "$tmp/tool"
check "not signed at all: refused" "$(runtime)" no

# Sparkle offers only a greater build: --publish compares CURRENT_PROJECT_VERSION with the highest
# sparkle:version of the latest release's appcast (betas are in it); KS_VERSION is the app's version.
feed "$(item 23)" "$(item 25 beta)" > "$tmp/published.xml"
check "the highest build, beta items too" "$(appcast_max_build "$tmp/published.xml")" 25
printf '<enclosure url="https://x/9.dmg" sparkle:version="9"/>\n' > "$tmp/attribute.xml"
check "the attribute form is read" "$(appcast_max_build "$tmp/attribute.xml")" 9
check "an appcast without items gives nothing" "$(appcast_max_build "$tmp/empty.xml")" ""
check "a greater build: taken" "$(build_problem 26 25)" ""
check "nothing published yet: taken" "$(build_problem 1 '')" ""
check "the same build: refused" "$(build_problem 25 25 | grep -c 'Поставь 26')" 1
check "not a number: refused" "$(build_problem 2x 25 | grep -c 'не целое число')" 1
printf 'KS_VERSION="0.19.0" # the app'"'"'s version\n' > "$tmp/ks"
check "KS_VERSION equal to the app's: taken" "$(ks_version_problem "$tmp/ks" 0.19.0)" ""
check "KS_VERSION different: refused" "$(ks_version_problem "$tmp/ks" 0.19.1 | grep -c 'KS_VERSION «0.19.0»')" 1

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
