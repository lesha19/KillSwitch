#!/bin/bash
# Downloads geosite.dat and geoip.metadb of a pinned MetaCubeX/meta-rules-dat release into Helper/
# and checks their sha256. They ship inside the app (signed with it); install.sh copies them from
# the bundle into /Library/KillSwitch/core, never from anywhere the user can write. The
# subscription's own GEOSITE/GEOIP rules (e.g. GEOIP,RU,DIRECT) and the opt-in ad block read them
# (ADR 0013). The core never downloads geodata itself (geo-auto-update is off; without the files
# such rules are left out of the config).
set -eu
cd "$(dirname "$0")"
# meta-rules-dat has a single moving release tag, "latest", rebuilt daily, and force-pushes the
# same files to its "release" branch. So the pin is the commit of that branch for one dated build
# ("Released on 2026-10-10 09:50", identical to that day's latest/ files), plus their sha256.
# To update: gh api 'repos/MetaCubeX/meta-rules-dat/commits?sha=release&per_page=1', take the sha,
# set RELEASE, empty both SHA256 values, run once and pin the printed sha256s.
RELEASE="fa4922ac71ae2ac2ae1c1f5b61447b42095fd665"   # commit of the "release" branch
SHA256_GEOSITE="e0ad83c50ba6bf79d5b872432af581a6ce785d24af61a3ffb00fd9085aadea59"   # its geosite.dat
SHA256_GEOIP="cc522e05d607c725bdd4b1219b6d80e2b6c3454571ca07157e73a17951ba8c84"     # its geoip.metadb
[ -n "$RELEASE" ] || { echo "Set RELEASE (and the SHA256 values) in $0 first" >&2; exit 1; }
# A force-push can drop the pinned commit, so every published release of KillSwitch carries a copy
# of both files (scripts/release.sh --publish). The copy is asked first; the commit only when the
# copy is missing or of another pin (right after the pin was moved). Both must match the pin.
COPY="https://github.com/lesha19/KillSwitch-releases/releases/latest/download"
UPSTREAM="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/$RELEASE"
trap 'rm -f geosite.dat.tmp geoip.metadb.tmp' EXIT
# Each download gives up after 3 minutes (#27); a file only replaces the one here once its sha256
# is the pinned one, so any failure keeps the old file.
fetch() {  # fetch <file> <sha256>
  local url
  if [ -z "$2" ]; then
    curl -q --max-time 180 -fsSL -o "$1.tmp" "$UPSTREAM/$1"
    shasum -a 256 "$1.tmp"; rm -f "$1.tmp"
    echo "Not pinned yet: put this sha256 of $1 into $0 and run it again" >&2; return 1
  fi
  for url in "$COPY/$1" "$UPSTREAM/$1"; do
    rm -f "$1.tmp"
    if curl -q --max-time 180 -fsSL -o "$1.tmp" "$url" && echo "$2  $1.tmp" | shasum -a 256 -c - >/dev/null 2>&1; then
      mv "$1.tmp" "$1"
      echo "$1: $url"
      return 0
    fi
    echo "Не подошёл (нет файла или другой sha256): $url" >&2
  done
  echo "Нет $1 с sha256 $2 ни в выпусках KillSwitch, ни в meta-rules-dat" >&2
  return 1
}
fetch geosite.dat "$SHA256_GEOSITE"
fetch geoip.metadb "$SHA256_GEOIP"
