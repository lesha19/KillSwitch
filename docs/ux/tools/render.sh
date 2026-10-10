#!/bin/bash
# Renders every screen of the app into docs/ux/screens (light + dark) without launching the app.
# Builds a throwaway SwiftPM package from patched copies of App/ (prepare.py) in $TMPDIR; the app
# target and its sources are not touched. Needs Xcode and a resolved Yams checkout (any earlier
# xcodebuild of the project leaves one in DerivedData) or network access for SwiftPM.
# Usage: docs/ux/tools/render.sh [icon-branch]   (default icon-sparkle; menu bar SVGs are read from it)
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
work=${UX_RENDER_DIR:-${TMPDIR:-/tmp}/ks-ux-render}
python3 "$repo/docs/ux/tools/prepare.py" "$repo" "$work"

yams=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/KillSwitch-*/SourcePackages/checkouts/Yams 2>/dev/null | head -1 || true)
if [ -n "$yams" ]; then dep=".package(path: \"$yams\")"; else dep='.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")'; fi
cat > "$work/Package.swift" <<PKG
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "UXRender",
    platforms: [.macOS(.v15)],
    dependencies: [$dep],
    targets: [.executableTarget(name: "UXRender", dependencies: ["Yams"], swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")])]
)
PKG

icons="$work/icons"; mkdir -p "$icons"
branch=${1:-icon-sparkle}
for s in Connected Disconnected Paused; do
  lower=$(echo "$s" | tr '[:upper:]' '[:lower:]')
  git -C "$repo" show "$branch:Assets.xcassets/MenuBar$s.imageset/menubar-$lower.svg" > "$icons/$lower.svg" 2>/dev/null || rm -f "$icons/$lower.svg"
done

swift build --package-path "$work" -c debug 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^.*warning" | tail -20
"$work/.build/debug/UXRender" "$repo/docs/ux/screens" "$icons"
