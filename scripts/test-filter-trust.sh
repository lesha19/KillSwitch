#!/bin/bash
# Tests the content filter's trusted-program rules (Filter/TrustedCode.swift) against real
# binaries: forged, unsigned and ad-hoc ones must not match, properly signed ones must.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp /usr/bin/true "$work/forged"
codesign -f -s - -i com.lesha19.KillSwitch.core "$work/forged" 2>/dev/null
cp /usr/bin/true "$work/unsigned"
codesign --remove-signature "$work/unsigned"
# The positive case needs a certificate of our team; without one it is skipped.
if security find-identity -v -p codesigning | grep -q "Apple Development"; then
  cp /usr/bin/true "$work/dev-core"
  cp /usr/bin/true "$work/dev-other"
  codesign -f -s "Apple Development" -i com.lesha19.KillSwitch.core "$work/dev-core" 2>/dev/null || rm -f "$work/dev-core"
  codesign -f -s "Apple Development" -i com.lesha19.KillSwitch.other "$work/dev-other" 2>/dev/null || rm -f "$work/dev-other"
fi

if security find-identity -v -p codesigning | grep -q "Developer ID Application: .*(YR58655PJ7)"; then
  cp /usr/bin/true "$work/devid-core"
  codesign -f -s "Developer ID Application: " --timestamp=none -i com.lesha19.KillSwitch.core "$work/devid-core" 2>/dev/null ||
    rm -f "$work/devid-core"
fi
# What scripts/sign-core.sh signs with by default (Developer ID if present, else Apple Development).
cp /usr/bin/true "$work/signed-core"
scripts/sign-core.sh "$work/signed-core" >/dev/null 2>&1 || rm -f "$work/signed-core"
# The upstream core, as Helper/fetch-mihomo.sh downloads it before signing: ad-hoc.
if [ -f Helper/mihomo ]; then
  cp Helper/mihomo "$work/adhoc-mihomo"
  codesign -f -s - "$work/adhoc-mihomo" 2>/dev/null
fi

swiftc -swift-version 6 -o "$work/test" Filter/TrustedCode.swift scripts/filter-trust-test/main.swift
"$work/test" "$work"
