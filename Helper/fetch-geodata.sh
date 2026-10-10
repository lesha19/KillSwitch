#!/bin/bash
# Downloads geosite.dat of a pinned MetaCubeX/meta-rules-dat release into Helper/geosite.dat and
# checks its sha256. install.sh puts it into /Library/KillSwitch/core; with coredirect=1 the
# generator then sends Russian sites (GEOSITE,category-ru) outside the VPN. The core never
# downloads geodata itself (geo-auto-update is off, rules are added only for files present).
# GEOIP,RU uses geoip.metadb, which install.sh already takes from dropweb.
set -eu
cd "$(dirname "$0")"
RELEASE=""   # a tag from https://github.com/MetaCubeX/meta-rules-dat/releases
SHA256=""    # sha256 of geosite.dat of that release
[ -n "$RELEASE" ] || { echo "Set RELEASE (and SHA256) in $0 first" >&2; exit 1; }
curl -fsSL -o geosite.dat.tmp "https://github.com/MetaCubeX/meta-rules-dat/releases/download/$RELEASE/geosite.dat"
if [ -z "$SHA256" ]; then
  shasum -a 256 geosite.dat.tmp; rm -f geosite.dat.tmp
  echo "Not pinned yet: put this sha256 into SHA256 in $0 and run it again" >&2; exit 1
fi
echo "$SHA256  geosite.dat.tmp" | shasum -a 256 -c -
mv geosite.dat.tmp geosite.dat
