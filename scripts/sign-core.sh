#!/bin/bash
# Signs the mihomo binary as our VPN core. The content filter trusts the core only by this
# signature: team YR58655PJ7 + identifier com.lesha19.KillSwitch.core (Filter/TrustedCode.swift).
# The upstream binary is ad-hoc signed and would not be trusted.
#
#   scripts/sign-core.sh [binary] [identity]
#     binary    default Helper/mihomo (after Helper/fetch-mihomo.sh)
#     identity  release.sh passes its Developer ID identity. Default: "Developer ID Application" of
#               team YR58655PJ7 if the keychain has it, else "Apple Development". Both certificates
#               carry the team in subject.OU, so the filter's requirement accepts either.
set -euo pipefail
cd "$(dirname "$0")/.."
binary="${1:-Helper/mihomo}"
identity="${2:-}"
[ -f "$binary" ] || { echo "Нет $binary: сначала Helper/fetch-mihomo.sh" >&2; exit 1; }
timestamp=--timestamp   # notarization needs a secure timestamp; development builds do not
if [ -z "$identity" ]; then
  timestamp=--timestamp=none
  identity=$(security find-identity -v -p codesigning |
    sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "Developer ID Application: .*\(YR58655PJ7\)"$/\1/p' | head -1)
  identity="${identity:-Apple Development}"
fi
case "$identity" in "Apple Development"*) timestamp=--timestamp=none ;; esac
codesign --force --sign "$identity" --identifier com.lesha19.KillSwitch.core --options runtime "$timestamp" "$binary"
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "YR58655PJ7" and identifier "com.lesha19.KillSwitch.core"' "$binary"
