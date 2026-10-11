#!/bin/bash
# Downloads the pinned mihomo release into Helper/mihomo, checks its sha256 and signs it
# (scripts/sign-core.sh).
set -eu
cd "$(dirname "$0")"
VERSION=v1.19.32
SHA256=3312a6780652c622890fd4357c6a853bbf865464fd047ac7b7f52dab8de18652
# github.com/MetaCubeX/mihomo/archive/refs/tags/$VERSION.tar.gz: the GPL-3.0 source that
# scripts/release.sh --publish attaches to each release. Update it together with VERSION.
# shellcheck disable=SC2034  # read by scripts/release.sh (core_source)
SOURCE_SHA256=ab130b7fab3893d01aa44c0d39be34a26da716c1d36832fbac9fa054a1d862a0
curl -fsSL -o mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/mihomo-darwin-arm64-$VERSION.gz"
echo "$SHA256  mihomo.gz" | shasum -a 256 -c -
gunzip -f mihomo.gz
chmod 755 mihomo
# The content filter trusts the core only by our signature (Filter/TrustedCode.swift).
../scripts/sign-core.sh Helper/mihomo ||
  echo "Ядро не подписано: фильтр macOS не будет ему доверять (нужен сертификат команды YR58655PJ7)" >&2
./mihomo -v
