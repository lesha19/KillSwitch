#!/bin/bash
# Downloads geosite.dat of a pinned MetaCubeX/meta-rules-dat release into Helper/geosite.dat and
# checks its sha256. install.sh puts it into /Library/KillSwitch/core; with coredirect=1 the
# generator then sends Russian sites (GEOSITE,category-ru) outside the VPN. The core never
# downloads geodata itself (geo-auto-update is off, rules are added only for files present).
# GEOIP,RU uses geoip.metadb, which install.sh already takes from dropweb.
set -eu
cd "$(dirname "$0")"
# meta-rules-dat has a single moving release tag, "latest", rebuilt daily, and force-pushes the
# same files to its "release" branch. So the pin is the commit of that branch for one dated build
# ("Released on 2026-10-10 09:50", identical to that day's latest/geosite.dat), plus its sha256.
# To update: gh api 'repos/MetaCubeX/meta-rules-dat/commits?sha=release&per_page=1', take the sha,
# set RELEASE, empty SHA256, run once and pin the printed sha256.
RELEASE="fa4922ac71ae2ac2ae1c1f5b61447b42095fd665"   # commit of the "release" branch
SHA256="e0ad83c50ba6bf79d5b872432af581a6ce785d24af61a3ffb00fd9085aadea59"   # its geosite.dat
[ -n "$RELEASE" ] || { echo "Set RELEASE (and SHA256) in $0 first" >&2; exit 1; }
curl -fsSL -o geosite.dat.tmp "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$RELEASE/geosite.dat"
if [ -z "$SHA256" ]; then
  shasum -a 256 geosite.dat.tmp; rm -f geosite.dat.tmp
  echo "Not pinned yet: put this sha256 into SHA256 in $0 and run it again" >&2; exit 1
fi
echo "$SHA256  geosite.dat.tmp" | shasum -a 256 -c -
mv geosite.dat.tmp geosite.dat
