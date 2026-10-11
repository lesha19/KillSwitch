#!/bin/bash
# Downloads the pinned Xray-core release into Helper/xray, checks the zip's sha256 and signs it
# (scripts/sign-core.sh) with the same identifier as mihomo, so the content filter trusts it
# without a change (ADR 0020). Only the binary is taken: geodata comes pinned from
# fetch-geodata.sh. To update: gh api repos/XTLS/Xray-core/releases/tags/<tag>, take the
# Xray-macos-arm64-v8a.zip digest (the same as SHA2-256 in its .dgst), and run the core tests
# with the new binary (configs change keys between tags).
set -eu
cd "$(dirname "$0")"
VERSION=v26.9.30
SHA256=4b363bd924df5bf09f87bd445755ff8e5742b9a8a0480cda261061416c3c7dce   # Xray-macos-arm64-v8a.zip
# github.com/XTLS/Xray-core/archive/refs/tags/$VERSION.tar.gz: the MPL-2.0 source that
# scripts/release.sh --publish attaches to each release. Update it together with VERSION.
# shellcheck disable=SC2034  # read by scripts/release.sh (core_source)
SOURCE_SHA256=85162fa61eb6d1adc9199afff7b41299e69dedd094907e9c56ef665c236b3ef0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -q --max-time 300 -fsSL -o "$tmp/xray.zip" \
  "https://github.com/XTLS/Xray-core/releases/download/$VERSION/Xray-macos-arm64-v8a.zip"
echo "$SHA256  $tmp/xray.zip" | shasum -a 256 -c - >/dev/null
unzip -q -o "$tmp/xray.zip" xray -d "$tmp"
chmod 755 "$tmp/xray"
mv -f "$tmp/xray" xray
# The content filter trusts the core only by our signature (Filter/TrustedCode.swift).
../scripts/sign-core.sh Helper/xray ||
  echo "Ядро не подписано: фильтр macOS не будет ему доверять (нужен сертификат команды YR58655PJ7)" >&2
./xray version | head -1
