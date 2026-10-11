#!/bin/bash
# Checks App/ThirdPartyNotices.txt (shown in «О программе → Лицензии») against what ships: every
# pinned version of Helper/fetch-*.sh and project.yml must be named there, so moving a pin without
# updating the notices fails here. Also the licence texts the notices must carry in full.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root="$here/../.."
notices="$root/App/ThirdPartyNotices.txt"
fails=0
has() {  # has <what> <text>
  if grep -qF -- "$2" "$notices" 2>/dev/null; then echo "ok    $1"; else echo "FAIL  $1: no '$2' in App/ThirdPartyNotices.txt"; fails=$((fails + 1)); fi
}
pin() { sed -n "s/^$1=\"\{0,1\}\([^\" ]*\)\"\{0,1\}.*/\1/p" "$2" | head -1; }   # pin <VAR> <file>
pkg() { awk -v p="  $1:" '$0 == p { f = 1; next } f && /exactVersion:/ { print $2; exit }' "$root/project.yml"; }

xray=$(pin VERSION "$root/Helper/fetch-xray.sh")
mihomo=$(pin VERSION "$root/Helper/fetch-mihomo.sh")
geodata=$(pin RELEASE "$root/Helper/fetch-geodata.sh")
sparkle=$(pkg Sparkle)
yams=$(pkg Yams)
for v in xray mihomo geodata sparkle yams; do
  [ -n "${!v}" ] || { echo "FAIL  no pinned $v version found"; fails=$((fails + 1)); }
done

has "Xray-core $xray" "Xray-core $xray"
has "  its source at that tag" "https://github.com/XTLS/Xray-core/tree/$xray"
has "mihomo $mihomo" "mihomo $mihomo"
has "  its corresponding source at that tag (GPL-3.0)" "https://github.com/MetaCubeX/mihomo/tree/$mihomo"
has "geodata at meta-rules-dat $geodata" "https://github.com/MetaCubeX/meta-rules-dat/tree/$geodata"
has "Sparkle $sparkle" "Sparkle $sparkle"
has "  its source at that tag" "https://github.com/sparkle-project/Sparkle/tree/$sparkle"
has "Yams $yams" "Yams $yams"
has "  its source at that tag" "https://github.com/jpsim/Yams/tree/$yams"
has "the GPL-3.0 text in full" "GNU GENERAL PUBLIC LICENSE"
has "  to its last section" "END OF TERMS AND CONDITIONS"
has "the MPL-2.0 text" "Mozilla Public License Version 2.0"
has "the MIT text (Yams, libYAML, Sparkle)" "Permission is hereby granted, free of charge"
has "the BSD text (bsdiff in Sparkle)" "Redistribution and use in source and binary forms"
has "the zlib-style text (ed25519 in Sparkle)" "This notice may not be removed or altered from any source distribution."
has "MaxMind attribution (geoip)" "GeoLite2 data created by MaxMind"

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
