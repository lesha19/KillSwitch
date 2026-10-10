#!/bin/bash
# Release build outside the App Store: Developer ID signing, hardened runtime, notarization,
# a signed and notarized .dmg in build/release/. See README, section "Выпуск".
#
#   scripts/release.sh           full release
#   scripts/release.sh --check   only check that certificates, profiles and the notary profile exist
#   scripts/release.sh --sign-only   build and sign build/release/KillSwitch.app, no notarization
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
# The widget has no restricted entitlements (its app group is team-prefixed) and needs no profile.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=YR58655PJ7
NOTARY_PROFILE=killswitch-notary
APP_ID=com.lesha19.KillSwitch
FILTER_ID=com.lesha19.KillSwitch.Filter
NE_VALUE=content-filter-provider-systemextension   # Developer ID form of content-filter-provider
OUT=build/release
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

[ -f Helper/mihomo ] || problem "Нет Helper/mihomo (ядро VPN): запустите Helper/fetch-mihomo.sh."

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
  -destination generic/platform=macOS -archivePath "$OUT/KillSwitch.xcarchive" CODE_SIGNING_ALLOWED=NO -quiet
APP="$OUT/KillSwitch.app"
ditto "$OUT/KillSwitch.xcarchive/Products/Applications/KillSwitch.app" "$APP"
SYSEXT="$APP/Contents/Library/SystemExtensions/$FILTER_ID.systemextension"
WIDGET="$APP/Contents/PlugIns/KillSwitchWidget.appex"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

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
sign --entitlements Widget/KillSwitchWidget.entitlements "$WIDGET"
entitlements Filter/KillSwitchFilter.entitlements "$PROFILE_FILTER" "$OUT/filter.entitlements"
cp "$PROFILE_FILTER" "$SYSEXT/Contents/embedded.provisionprofile"
sign --entitlements "$OUT/filter.entitlements" "$SYSEXT"
entitlements App/KillSwitch.entitlements "$PROFILE_APP" "$OUT/app.entitlements"
cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
sign --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
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
echo "Готово: $DMG"
shasum -a 256 "$DMG"
