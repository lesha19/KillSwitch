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

swiftc -swift-version 6 -o "$work/test" Filter/TrustedCode.swift scripts/filter-trust-test/main.swift
"$work/test" "$work"
