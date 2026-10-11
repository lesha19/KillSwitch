#!/bin/bash
# Release build outside the App Store: Developer ID signing, hardened runtime, notarization,
# a signed and notarized .dmg in build/release/. See README, section "Выпуск".
#
#   scripts/release.sh           full release
#   scripts/release.sh --check   only check that certificates, profiles and the notary profile exist
#   scripts/release.sh --sign-only   build and sign build/release/KillSwitch.app, no notarization
#   scripts/release.sh --publish     full release, then `gh release create v<version>` in
#                                    lesha19/KillSwitch-releases with the .dmg, appcast.xml,
#                                    geosite.dat and geoip.metadb (+ .sha256), the source tarballs of the
#                                    pinned mihomo (GPL-3.0) and Xray-core tags, and SHA256SUMS of them all
#   KS_CHANNEL=beta scripts/release.sh --publish
#                                    a beta (#16): its appcast item is in Sparkle's "beta" channel, the
#                                    GitHub release is a pre-release (never "latest"), and the item is
#                                    added to the latest stable release's appcast.xml (+ its SHA256SUMS),
#                                    the one feed every app reads; only «Бета-версии» installs it.
#                                    The next stable release's appcast has no beta item again.
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
#   - Helper/mihomo (Helper/fetch-mihomo.sh) and Helper/xray (Helper/fetch-xray.sh, ADR 0020): both
#     cores are signed here as com.lesha19.KillSwitch.core (one runs at a time).
#   - Helper/geosite.dat, Helper/geoip.metadb and Helper/geoip.dat (Helper/fetch-geodata.sh): the subscription's
#     GEOSITE/GEOIP rules and the ad block (ADR 0013).
#     Shipped like mihomo, in the app's Resources/Helper; install.sh copies them to /Library/KillSwitch/core.
#     They must be the pinned files: --publish uploads them (with their sha256) as the copies that
#     fetch-geodata.sh asks first, in case the pinned meta-rules-dat commit disappears.
#   - Sparkle EdDSA private key in the login keychain (Sparkle's generate_keys, run once; only the
#     public key is in project.yml as SUPublicEDKey). generate_appcast signs the .dmg with it.
#   - --publish only: gh logged in with access to lesha19/KillSwitch-releases, and release notes:
#     the "## <version>" section of CHANGELOG.md or a file given in KS_RELEASE_NOTES.
# The widget has no restricted entitlements (its app group is team-prefixed) and needs no profile.
# The privileged daemon (ADR 0010) is Contents/MacOS/KillSwitchHelper, signed as
# com.lesha19.KillSwitch.helper with the hardened runtime before the app; the app and the daemon
# check each other's designated requirement, so both are verified against it at the end.
# `killswitch` (ADR 0025) is Contents/Helpers/killswitch, signed as com.lesha19.KillSwitch.cli with
# the hardened runtime: the daemon lets it in by that identifier, so it is verified the same way.

# geodata_pinned <dir> <file>: <dir>/<file> (geosite.dat, geoip.metadb, geoip.dat) has the sha256 pinned in
# <dir>/fetch-geodata.sh. Root installs them as they are: only the pinned files ship.
geodata_pinned() {
  local var pin
  case "$2" in geosite.dat) var=SHA256_GEOSITE ;; geoip.metadb) var=SHA256_GEOIP ;; geoip.dat) var=SHA256_GEOIP_DAT ;; *) return 1 ;; esac
  pin=$(sed -nE "s/^$var=\"([0-9a-f]{64})\".*/\\1/p" "$1/fetch-geodata.sh")
  [ -n "$pin" ] && [ -f "$1/$2" ] && [ "$(shasum -a 256 < "$1/$2" | cut -d' ' -f1)" = "$pin" ]
}

# core_source <fetch script> <owner/repo> <dir>: downloads the source tarball of the tag pinned in
# <fetch script> (VERSION) into <dir>/<repo>-<tag>-source.tar.gz and prints that name. It must have
# the sha256 pinned there as SOURCE_SHA256, otherwise nothing is left in <dir>. mihomo is GPL-3.0:
# the binary in the app is published with its source (§6); Xray-core (MPL-2.0) the same way.
# KS_SOURCE_BASE replaces https://github.com (tests).
core_source() {
  local tag pin name
  tag=$(sed -nE 's/^VERSION=([^ ]+).*/\1/p' "$1")
  pin=$(sed -nE 's/^SOURCE_SHA256=([0-9a-f]{64})( .*)?$/\1/p' "$1")
  name="${2#*/}-$tag-source.tar.gz"
  [ -n "$tag" ] && [ -n "$pin" ] || { echo "$1: нет VERSION или SOURCE_SHA256" >&2; return 1; }
  if curl -q --max-time 300 -fsSL -o "$3/$name" "${KS_SOURCE_BASE:-https://github.com}/$2/archive/refs/tags/$tag.tar.gz" &&
     [ "$(shasum -a 256 < "$3/$name" | cut -d' ' -f1)" = "$pin" ]; then
    echo "$name"
  else
    rm -f "$3/$name"
    echo "Исходники $2 $tag: не скачались или sha256 не $pin ($1)" >&2
    return 1
  fi
}

# write_sums <dir> <file>...: <dir>/SHA256SUMS for files in <dir>, by bare name, in the format
# `shasum -a 256 -c SHA256SUMS` checks (README, «Проверка загрузки»). Fails if one is missing.
write_sums() {
  local dir=$1
  shift
  (cd "$dir" && shasum -a 256 "$@" > SHA256SUMS.tmp) && mv "$dir/SHA256SUMS.tmp" "$dir/SHA256SUMS" ||
    { rm -f "$dir/SHA256SUMS.tmp"; return 1; }
}

# appcast_with_beta <stable appcast> <beta appcast>: the stable appcast with its old beta items
# replaced by the items of the beta appcast (generate_appcast --channel beta), put first (#16).
# Fails if the beta appcast has no beta item.
appcast_with_beta() {
  grep -q '<sparkle:channel>beta</sparkle:channel>' "$2" || return 1
  awk '
    FNR == NR { if ($0 ~ /<item>/) on = 1; if (on) beta = beta $0 "\n"; if ($0 ~ /<\/item>/) on = 0; next }
    /<item>/ { item = $0 "\n"; on = 1; next }
    on {
      item = item $0 "\n"
      if ($0 ~ /<\/item>/) {
        on = 0
        if (!done) { printf "%s", beta; done = 1 }
        if (item !~ /<sparkle:channel>beta<\/sparkle:channel>/) printf "%s", item
      }
      next
    }
    /<\/channel>/ && !done { printf "%s", beta; done = 1 }
    { print }' "$2" "$1"
}

# sums_replace <SHA256SUMS> <name> <file>: the line of <name> gets the sha256 of <file> (the stable
# release's appcast.xml after a beta went into it). Fails if <name> is not listed.
sums_replace() {
  local hash
  awk -v n="$2" '$2 == n { found = 1 } END { exit !found }' "$1" || return 1
  hash=$(shasum -a 256 < "$3" | cut -d' ' -f1)
  awk -v n="$2" -v h="$hash" '$2 == n { $0 = h "  " n } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# appcast_max_build <appcast.xml>: the highest build (sparkle:version) of its items, beta ones too;
# nothing when it has none. Sparkle offers only a build greater than the installed one.
appcast_max_build() {
  # one line, so an element split over lines or padded with spaces is still read
  { tr '\n\r\t' '   ' < "$1" | grep -oE 'sparkle:version(>|=")[[:space:]]*[0-9]+' || true; } |
    sed -E 's/.*[^0-9]//' | sort -n | tail -1
}

# published_build_problem <build> <published appcast.xml>: why <build> cannot be published after
# that appcast, or nothing. Items whose build cannot be read are a problem, not "nothing published".
published_build_problem() {
  local last
  last=$(appcast_max_build "$2")
  if [ -z "$last" ] && grep -q '<item' "$2"; then
    echo "В appcast.xml последнего выпуска есть выпуски, но номер сборки (sparkle:version) не прочитать: проверь его вручную."
    return
  fi
  build_problem "$1" "$last"
}

# build_problem <build> <last published build>: why <build> cannot be published, or nothing.
build_problem() {
  case "$1" in ''|*[!0-9]*) echo "CURRENT_PROJECT_VERSION «$1» в project.yml — не целое число."; return ;; esac
  [ -z "$2" ] || [ "$1" -gt "$2" ] ||
    echo "CURRENT_PROJECT_VERSION $1 (project.yml) не больше последней опубликованной сборки $2: Sparkle не предложит такое обновление. Поставь $(($2 + 1))."
}

# ks_version_problem <Helper/ks> <MARKETING_VERSION>: nothing when KS_VERSION in ks is the app's version.
ks_version_problem() {
  local ks
  ks=$(sed -nE 's/^KS_VERSION="([^"]*)".*/\1/p' "$1")
  [ "$ks" = "$2" ] || echo "$1: KS_VERSION «$ks», а версия программы «$2» (project.yml, MARKETING_VERSION): поменяй KS_VERSION."
}

# runtime_signed <file>: <file> is signed with the hardened runtime and nothing else in its flags
# (no ad hoc signature). The daemon and the CLI are trusted by their signature (ADR 0010, 0025).
runtime_signed() {
  case "$(codesign -d --verbose "$1" 2>&1)" in   # not `| grep -q`: pipefail and SIGPIPE
    *'flags=0x10000(runtime)'*) return 0 ;;
    *) return 1 ;;
  esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced by Helper/tests
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=YR58655PJ7
NOTARY_PROFILE=killswitch-notary
APP_ID=com.lesha19.KillSwitch
FILTER_ID=com.lesha19.KillSwitch.Filter
HELPER_ID=com.lesha19.KillSwitch.helper
HELPER_PLIST=HelperDaemon/LaunchDaemons/$HELPER_ID.plist
CLI_ID=com.lesha19.KillSwitch.cli
# what the daemon asks of the app and the app of the daemon (App/Core/HelperProtocol.swift)
requirement() { echo "anchor apple generic and identifier \"$1\" and certificate leaf[subject.OU] = \"$TEAM\""; }
NE_VALUE=content-filter-provider-systemextension   # Developer ID form of content-filter-provider
OUT=build/release
SPM=build/spm   # SwiftPM checkouts + Sparkle's binary tools (generate_appcast), kept between releases
RELEASES_REPO=lesha19/KillSwitch-releases
MODE=${1:-}
CHANNEL=${KS_CHANNEL:-}

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
[ -f Helper/xray ] || problem "Нет Helper/xray (ядро VPN): запустите Helper/fetch-xray.sh."
for f in geosite.dat geoip.metadb geoip.dat; do
  if [ ! -f "Helper/$f" ]; then
    problem "Нет Helper/$f (правила GEOSITE и GEOIP подписки): запустите Helper/fetch-geodata.sh."
  elif ! geodata_pinned Helper "$f"; then
    problem "Helper/$f не совпадает с sha256 из Helper/fetch-geodata.sh: запустите его заново."
  fi
done

# Existence only: nothing is read out of the keychain item.
security find-generic-password -s https://sparkle-project.org -a ed25519 >/dev/null 2>&1 ||
  problem "Нет ключа EdDSA Sparkle в связке ключей (им подписываются обновления).
    Создать один раз: <SourcePackages>/artifacts/sparkle/Sparkle/bin/generate_keys,
    затем открытый ключ (generate_keys -p) — в project.yml, SUPublicEDKey."

case "$CHANNEL" in
  "") ;;
  beta) [ "$MODE" = --publish ] || [ "$MODE" = --check ] || problem "KS_CHANNEL=beta выпускается только с --publish." ;;
  *) problem "KS_CHANNEL: только beta (или не задан), а не «$CHANNEL»." ;;
esac

MARKETING_VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml | head -1)
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([^"]+)"?$/\1/p' project.yml | head -1)
version_problem=$(ks_version_problem Helper/ks "$MARKETING_VERSION")
[ -z "$version_problem" ] || problem "$version_problem"

NOTES=${KS_RELEASE_NOTES:-}
if [ "$MODE" = --publish ]; then
  if ! command -v gh >/dev/null; then
    problem "Нет gh в PATH (brew install gh)."
  elif ! gh auth status >/dev/null 2>&1; then
    problem "gh не авторизован: gh auth login."
  else
    # The latest stable release's appcast is the feed every app reads; betas are added to it.
    rm -rf build/published && mkdir -p build/published
    if gh release download --repo "$RELEASES_REPO" --dir build/published --pattern appcast.xml >/dev/null 2>&1; then
      build_problem=$(published_build_problem "$BUILD" build/published/appcast.xml)
      [ -z "$build_problem" ] || problem "$build_problem"
    else
      problem "Не скачался appcast.xml последнего выпуска $RELEASES_REPO: номер сборки не проверить."
    fi
  fi
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
# Before the long build, so a broken pin stops the release early.
if [ "$MODE" != --sign-only ]; then
  MIHOMO_SRC=$(core_source Helper/fetch-mihomo.sh MetaCubeX/mihomo "$OUT")
  XRAY_SRC=$(core_source Helper/fetch-xray.sh XTLS/Xray-core "$OUT")
fi
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
CLI="$APP/Contents/Helpers/killswitch"
[ -f "$CLI" ] || { echo "В приложении нет $CLI" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
for f in mihomo xray geosite.dat geoip.metadb geoip.dat; do
  cmp -s "Helper/$f" "$APP/Contents/Resources/Helper/$f" || { echo "В приложении нет Helper/$f" >&2; exit 1; }
done
[ ! -e "$APP/Contents/Resources/Helper/tests" ] || { echo "В приложение попали Helper/tests (project.yml)" >&2; exit 1; }

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
scripts/sign-core.sh "$APP/Contents/Resources/Helper/xray" "$IDENTITY"
sign --identifier "$HELPER_ID" "$HELPER"
sign --identifier "$CLI_ID" "$CLI"
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
codesign --verify --strict -R="$(requirement "$CLI_ID")" "$CLI"
codesign --verify --strict -R="$(requirement "$APP_ID")" "$APP"
for f in "$HELPER" "$CLI"; do
  runtime_signed "$f" || { echo "$f подписан без hardened runtime" >&2; exit 1; }
done
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
  ${CHANNEL:+--channel "$CHANNEL"} -o "$OUT/appcast.xml" "$OUT/appcast"
rm -rf "$OUT/appcast"
grep -q 'sparkle:edSignature=' "$OUT/appcast.xml" || { echo "appcast.xml без подписи EdDSA" >&2; exit 1; }

# The copies of the pinned geodata that Helper/fetch-geodata.sh asks first (see there).
for f in geosite.dat geoip.metadb geoip.dat; do
  cp "Helper/$f" "$OUT/$f"
  (cd "$OUT" && shasum -a 256 "$f" > "$f.sha256")
done

# Checksums of what is published, for people who verify the download (README).
write_sums "$OUT" "$(basename "$DMG")" appcast.xml geosite.dat geoip.metadb geoip.dat "$MIHOMO_SRC" "$XRAY_SRC"

echo "Готово: $DMG, $OUT/appcast.xml, $OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"

if [ "$MODE" = --publish ]; then
  gh release create "v$VERSION" --repo "$RELEASES_REPO" --title "KillSwitch $VERSION" ${CHANNEL:+--prerelease} \
    --notes-file "$NOTES" "$DMG" "$OUT/appcast.xml" "$OUT/geosite.dat" "$OUT/geosite.dat.sha256" \
    "$OUT/geoip.metadb" "$OUT/geoip.metadb.sha256" "$OUT/geoip.dat" "$OUT/geoip.dat.sha256" \
    "$OUT/$MIHOMO_SRC" "$OUT/$XRAY_SRC" "$OUT/SHA256SUMS"
  if [ "$CHANNEL" = beta ]; then
    # The app reads releases/latest/download/appcast.xml and a pre-release is never "latest": the
    # beta item goes into the latest stable release's appcast; its SHA256SUMS follows.
    STABLE_TAG=$(gh release view --repo "$RELEASES_REPO" --json tagName --jq .tagName)
    mkdir "$OUT/stable"
    gh release download "$STABLE_TAG" --repo "$RELEASES_REPO" --dir "$OUT/stable" --pattern appcast.xml --pattern SHA256SUMS
    appcast_with_beta "$OUT/stable/appcast.xml" "$OUT/appcast.xml" > "$OUT/stable/appcast.new"
    mv "$OUT/stable/appcast.new" "$OUT/stable/appcast.xml"
    sums_replace "$OUT/stable/SHA256SUMS" appcast.xml "$OUT/stable/appcast.xml"
    gh release upload "$STABLE_TAG" --repo "$RELEASES_REPO" --clobber "$OUT/stable/appcast.xml" "$OUT/stable/SHA256SUMS"
    echo "Бета добавлена в appcast.xml выпуска $STABLE_TAG."
  fi
  echo "Опубликовано: https://github.com/$RELEASES_REPO/releases/tag/v$VERSION"
fi
