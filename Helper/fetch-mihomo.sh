#!/bin/bash
# Downloads the pinned mihomo release into Helper/mihomo and checks its sha256.
set -eu
cd "$(dirname "$0")"
VERSION=v1.19.32
SHA256=3312a6780652c622890fd4357c6a853bbf865464fd047ac7b7f52dab8de18652
curl -fsSL -o mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/$VERSION/mihomo-darwin-arm64-$VERSION.gz"
echo "$SHA256  mihomo.gz" | shasum -a 256 -c -
gunzip -f mihomo.gz
chmod 755 mihomo
./mihomo -v
