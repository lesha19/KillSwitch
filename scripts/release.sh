#!/bin/bash
# Release build outside the App Store: Developer ID signing, hardened runtime, notarization,
# a signed and notarized .dmg in build/release/. See README, section "Выпуск".
#
#   scripts/release.sh           full release
#   scripts/release.sh --check   only check that certificates, profiles and the notary profile exist
#   scripts/release.sh --sign-only   build and sign build/release/KillSwitch.app, no notarization
#   scripts/release.sh --publish     full release, then `gh release create v<version>` in
#                                    lesha19/KillSwitch-releases with the .dmg and appcast.xml
#
# What it needs (found automatically, nothing secret is printed):
#   - certificate + private key "Developer ID Application: … (YR58655PJ7)" in the login keychain
#     (security find-identity -p codesigning);
#   - notarytool keychain profile "killswitch-notary" (xcrun notarytool store-credentials);
#   - Developer ID provisioning profiles for com.lesha19.KillSwitch (System Extension + Network
#     Extensions) and com.lesha19.KillSwitch.Filter (Network Extensions), both allowing
#     content-filter-provider-systemextension. Looked up in
#     ~/Library/Developer/Xcode/UserData/Provisioning Profiles and
#     ~/Library/MobileDevice/Provisioning Profiles; override with KS_PROFILE_APP / KS_PROFILE_FILTER;
#   - Helper/mihomo (Helper/fetch-mihomo.sh): the core is signed here as com.lesha19.KillSwitch.core.
#   - Helper/geosite.dat and Helper/geoip.metadb (Helper/fetch-geodata.sh): Russian sites and
#     addresses outside the VPN (coredirect=1).
#     Shipped like mihomo, in the app's Resources/Helper; install.sh copies them to /Library/KillSwitch/core.
#   - Sparkle EdDSA private key in the login keychain (Sparkle's generate_keys, run once; only the
#     public key is in project.yml as SUPublicEDKey). generate_appcast signs the .dmg with it.
#   - --publish only: gh logged in with access to lesha19/KillSwitch-releases, and release notes:
#     the "## <version>" section of CHANGELOG.md or a file given in KS_RELEASE_NOTES.
# The widget has no restricted entitlements (its app group is team-prefixed) and needs no profile.
# The privileged daemon (ADR 0010) is Contents/MacOS/KillSwitchHelper, signed as
# com.lesha19.KillSwitch.helper with the hardened runtime before the app; the app and the daemon
# check each other's designated requirement, so both are verified against it at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=YR58655PJ7
NOTARY_PROFILE=killswitch-notary
APP_ID=com.lesha19.KillSwitch
FILTER_ID=com.lesha19.KillSwitch.Filter
HELPER_ID=com.lesha19.KillSwitch.helper
HELPER_PLIST=HelperDaemon/LaunchDaemons/$HELPER_ID.plist
# what the daemon asks of the app and the app of the daemon (App/Core/HelperProtocol.swift)
requirement() { echo "anchor apple generic and identifier \"$1\" and certificate leaf[subject.OU] = \"$TEAM\""; }
NE_VALUE=content-filter-provider-systemextension   # Developer ID form of content-filter-provider
OUT=build/release
SPM=build/spm   # SwiftPM checkouts + Sparkle's binary tools (generate_appcast), kept between releases
RELEASES_REPO=lesha19/KillSwitch-releases
MODE=${1:-}

problems=()
problem() { problems+=("$1"); }

# Prints the path of the newest valid Developer ID profile for bundle id $1 that allows $NE_VALUE.
find_profile() {
  /usr/bin/python3 -I - "$TEAM.$1" "$NE_VALUE" <<'PY'
import glob, os, plistlib, subprocess, sys, datetime
app_id, ne = sys.argv[1], sys.argv[2]
dirs = ["~/Library/Developer/Xcode/UserData/Provisioning Profiles", "~/Library/MobileDevice/Provisioning Profiles"]
best = None
for d in dirs:
    for path in glob.glob(os.path.join(os.path.expanduser(d), "*.provisionprofile")):
        try:
            raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
            p = plistlib.loads(raw)
        except Exception:
            continue
        ent = p.get("Entitlements", {})
        if ent.get("com.apple.application-identifier") != app_id: continue
        if not p.get("ProvisionsAllDevices"): continue          # Developer ID profiles only
        if ne not in ent.get("com.apple.developer.networking.networkextension", []): continue
        if p["ExpirationDate"] <= datetime.datetime.now(): continue
        if best is None or p["CreationDate"] > best[0]:
            best = (p["CreationDate"], path)
if best: print(best[1])
PY
}

# --- preflight: everything is checked before anything is built ---------------------------------

for tool in xcodebuild xcodegen; do
  command -v "$tool" >/dev/null || problem "Нет $tool в PATH."
done

IDENTITY=$(security find-identity -v -p codesigning | sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"Developer ID Application: .*\($TEAM\)\"$/\1/p" | head -1)
[ -n "$IDENTITY" ] || problem "Нет сертификата «Developer ID Application» команды $TEAM в связке ключей.
    Создать: Xcode → Settings → Accounts → $TEAM → Manage Certificates → + → Developer ID Application."

if [ "$MODE" != --sign-only ] &&
   ! security find-generic-password -s com.apple.gke.notary.tool -a "com.apple.gke.notary.tool.saved-creds.$NOTARY_PROFILE" >/dev/null 2>&1 &&
   ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  problem "Нет профиля нотаризации «$NOTARY_PROFILE» в связке ключей.
    Создать: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM
    (пароль приложения с appleid.apple.com вводится в ответ на запрос, не в командной строке)."
fi

PROFILE_APP=${KS_PROFILE_APP:-$(find_profile "$APP_ID")}
PROFILE_FILTER=${KS_PROFILE_FILTER:-$(find_profile "$FILTER_ID")}
HOWTO_PROFILES="Скачать: Xcode → Settings → Accounts → $TEAM → Download Manual Profiles."
[ -n "$PROFILE_APP" ] && [ -f "$PROFILE_APP" ] ||
  problem "Нет профиля Developer ID для $APP_ID с $NE_VALUE (на портале: «KillSwitch Developer ID»).
    $HOWTO_PROFILES"
[ -n "$PROFILE_FILTER" ] && [ -f "$PROFILE_FILTER" ] ||
  problem "Нет профиля Developer ID для $FILTER_ID с $NE_VALUE (на портале: «KillSwitch Filter Developer ID»).
    $HOWTO_PROFILES"

# The daemon trusts the app by its signature: without the hardened runtime other code could be
# injected into the app and inherit its connection.
grep -qE '^ +ENABLE_HARDENED_RUNTIME: YES' project.yml ||
  problem "В project.yml нет ENABLE_HARDENED_RUNTIME: YES (ADR 0010)."
if ! plutil -lint -s "$HELPER_PLIST" ||
   [ "$(plutil -extract BundleProgram raw "$HELPER_PLIST" 2>/dev/null)" != Contents/MacOS/KillSwitchHelper ] ||
   [ "$(plutil -extract Label raw "$HELPER_PLIST" 2>/dev/null)" != "$HELPER_ID" ]; then
  problem "$HELPER_PLIST: нет файла или в нём не BundleProgram Contents/MacOS/KillSwitchHelper и Label $HELPER_ID."
fi

[ -f Helper/mihomo ] || problem "Нет Helper/mihomo (ядро VPN): запустите Helper/fetch-mihomo.sh."
[ -f Helper/geosite.dat ] && [ -f Helper/geoip.metadb ] ||
  problem "Нет Helper/geosite.dat или Helper/geoip.metadb (российские сайты мимо VPN): запустите Helper/fetch-geodata.sh."
# root installs them as they are: only the pinned files
for f in geosite.dat:SHA256_GEOSITE geoip.metadb:SHA256_GEOIP; do
  pin=$(sed -nE "s/^${f#*:}=\"([0-9a-f]{64})\".*/\1/p" Helper/fetch-geodata.sh)
  [ ! -f "Helper/${f%%:*}" ] || echo "$pin  Helper/${f%%:*}" | shasum -a 256 -c - >/dev/null 2>&1 ||
    problem "Helper/${f%%:*} не совпадает с sha256 из Helper/fetch-geodata.sh: запустите его заново."
done

# Existence only: nothing is read out of the keychain item.
security find-generic-password -s https://sparkle-project.org -a ed25519 >/dev/null 2>&1 ||
  problem "Нет ключа EdDSA Sparkle в связке ключей (им подписываются обновления).
    Создать один раз: <SourcePackages>/artifacts/sparkle/Sparkle/bin/generate_keys,
    затем открытый ключ (generate_keys -p) — в project.yml, SUPublicEDKey."

NOTES=${KS_RELEASE_NOTES:-}
if [ "$MODE" = --publish ]; then
  command -v gh >/dev/null || problem "Нет gh в PATH (brew install gh)."
  gh auth status >/dev/null 2>&1 || problem "gh не авторизован: gh auth login."
  MARKETING_VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml | head -1)
  if [ -z "$NOTES" ] && [ -f CHANGELOG.md ]; then
    NOTES=build/release-notes.md
    mkdir -p build
    # Lines under "## 0.7" / "## [0.7]" / "## v0.7 — …" up to the next "## " heading.
    awk -v v="$MARKETING_VERSION" '
      /^## / { h = $0; sub(/^## \[?v?/, "", h); on = (index(h, v) == 1 && substr(h, length(v) + 1, 1) !~ /[0-9.]/); next }
      on' CHANGELOG.md > "$NOTES"
    [ -s "$NOTES" ] || NOTES=
  fi
  [ -n "$NOTES" ] && [ -s "$NOTES" ] ||
    problem "Нет описания выпуска $MARKETING_VERSION: раздел «## $MARKETING_VERSION» в CHANGELOG.md или файл в KS_RELEASE_NOTES."
fi

if [ ${#problems[@]} -gt 0 ]; then
  echo "Выпуск невозможен:" >&2
  for p in "${problems[@]}"; do echo "  - $p" >&2; done
  exit 1
fi
echo "Проверка пройдена: сертификат, профиль нотаризации и профили на месте."
[ "$MODE" = --check ] && exit 0

# --- build ---------------------------------------------------------------------------------------

rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --quiet
# Built unsigned; everything is signed below, inside out, with Developer ID entitlements.
xcodebuild archive -project KillSwitch.xcodeproj -scheme KillSwitch -configuration Release \
  -destination generic/platform=macOS -archivePath "$OUT/KillSwitch.xcarchive" \
  -clonedSourcePackagesDirPath "$SPM" CODE_SIGNING_ALLOWED=NO -quiet
APP="$OUT/KillSwitch.app"
ditto "$OUT/KillSwitch.xcarchive/Products/Applications/KillSwitch.app" "$APP"
SYSEXT="$APP/Contents/Library/SystemExtensions/$FILTER_ID.systemextension"
WIDGET="$APP/Contents/PlugIns/KillSwitchWidget.appex"
HELPER="$APP/Contents/MacOS/KillSwitchHelper"
[ -f "$HELPER" ] && [ -f "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist" ] ||
  { echo "В приложении нет службы $HELPER_ID (Contents/MacOS, Contents/Library/LaunchDaemons)" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
for f in mihomo geosite.dat geoip.metadb; do
  cmp -s "Helper/$f" "$APP/Contents/Resources/Helper/$f" || { echo "В приложении нет Helper/$f" >&2; exit 1; }
done

# Entitlements as in the repo, with the Developer ID NetworkExtension value and the identifiers
# from the profile (AMFI matches them against the embedded profile at launch).
entitlements() {  # entitlements <repo .entitlements> <profile> <out>
  local decoded="$OUT/profile.plist" pb=/usr/libexec/PlistBuddy key value
  cp "$1" "$3"
  security cms -D -i "$2" > "$decoded"
  "$pb" -c "Delete :com.apple.developer.networking.networkextension" "$3"
  "$pb" -c "Add :com.apple.developer.networking.networkextension array" \
        -c "Add :com.apple.developer.networking.networkextension:0 string $NE_VALUE" "$3"
  for key in com.apple.application-identifier com.apple.developer.team-identifier; do
    value=$("$pb" -c "Print :Entitlements:$key" "$decoded")
    "$pb" -c "Add :$key string $value" "$3"
  done
  rm -f "$decoded"
}

sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }

echo "Подпись…"
scripts/sign-core.sh "$APP/Contents/Resources/Helper/mihomo" "$IDENTITY"
sign --identifier "$HELPER_ID" "$HELPER"
sign --entitlements Widget/KillSwitchWidget.entitlements "$WIDGET"
entitlements Filter/KillSwitchFilter.entitlements "$PROFILE_FILTER" "$OUT/filter.entitlements"
cp "$PROFILE_FILTER" "$SYSEXT/Contents/embedded.provisionprofile"
sign --entitlements "$OUT/filter.entitlements" "$SYSEXT"
# Sparkle, inside out and without --deep (sparkle-project.org/documentation/sandboxing, "Code
# Signing"). The app is not sandboxed, so Sparkle's XPC services are unused and removed, as the
# same page describes; Autoupdate and Updater.app get Developer ID + hardened runtime.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
entitlements App/KillSwitch.entitlements "$PROFILE_APP" "$OUT/app.entitlements"
cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
sign --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
# each side only talks to the other if these hold (and the daemon runs with the hardened runtime)
codesign --verify --strict -R="$(requirement "$HELPER_ID")" "$HELPER"
codesign --verify --strict -R="$(requirement "$APP_ID")" "$APP"
case "$(codesign -d --verbose "$HELPER" 2>&1)" in   # not `| grep -q`: pipefail and SIGPIPE
  *'flags=0x10000(runtime)'*) ;;
  *) echo "$HELPER подписан без hardened runtime" >&2; exit 1 ;;
esac
[ "$MODE" = --sign-only ] && { echo "Подписано (без нотаризации): $APP"; exit 0; }

# Fails with notarytool's log unless Apple accepts the file.
notarize() {
  local result status id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  status=$(printf '%s' "$result" | plutil -extract status raw - 2>/dev/null || echo "нет ответа")
  id=$(printf '%s' "$result" | plutil -extract id raw - 2>/dev/null || true)
  if [ "$status" != Accepted ]; then
    echo "Нотаризация $1 не прошла: $status" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

echo "Нотаризация приложения (несколько минут)…"
ditto -c -k --keepParent "$APP" "$OUT/KillSwitch.zip"
notarize "$OUT/KillSwitch.zip"
rm -f "$OUT/KillSwitch.zip"
xcrun stapler staple -q "$APP"

echo "Образ диска…"
DMG="$OUT/KillSwitch-$VERSION.dmg"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/KillSwitch.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "KillSwitch $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$OUT/dmg"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"

# Sparkle feed: one item for this .dmg, EdDSA-signed with the key from the login keychain.
# The app reads releases/latest/download/appcast.xml, so each release carries its own appcast.
echo "appcast.xml…"
mkdir "$OUT/appcast"
cp "$DMG" "$OUT/appcast/"
"$SPM/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/$RELEASES_REPO/releases/tag/v$VERSION" \
  -o "$OUT/appcast.xml" "$OUT/appcast"
rm -rf "$OUT/appcast"
grep -q 'sparkle:edSignature=' "$OUT/appcast.xml" || { echo "appcast.xml без подписи EdDSA" >&2; exit 1; }

echo "Готово: $DMG, $OUT/appcast.xml"
shasum -a 256 "$DMG"

if [ "$MODE" = --publish ]; then
  gh release create "v$VERSION" --repo "$RELEASES_REPO" --title "KillSwitch $VERSION" \
    --notes-file "$NOTES" "$DMG" "$OUT/appcast.xml"
  echo "Опубликовано: https://github.com/$RELEASES_REPO/releases/tag/v$VERSION"
fi
