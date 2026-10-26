#!/usr/bin/env bash
# Build Presenter for release: Developer ID signature, notarization, stapled DMG.
# Usage: scripts/release.sh [--skip-notarize]
# Output: build/release/Presenter-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="58XKRG9VMA"
IDENTITY="Developer ID Application: Marc Swan ($TEAM_ID)"
: "${NOTARY_PROFILE:=conduit-notary}"
VERSION="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
BUILD_NUMBER="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Presenter.xcarchive"
APP="$OUT/Presenter.app"
DMG="$OUT/Presenter-$VERSION.dmg"

NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    *) echo "usage: scripts/release.sh [--skip-notarize]" >&2; exit 2 ;;
  esac
done

fail() { echo "release: $*" >&2; exit 1; }
step() { echo "::progress::$1/7 $2" >&2; }

# Sends a file to Apple and waits. Prints the notary log and stops if Apple rejects it.
notarize() {
  local file="$1" result id status
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$result")"
  status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization of $(basename "$file") ended with status '$status' (submission $id)"
  fi
  echo "release: notarized $(basename "$file") (submission $id)" >&2
}

step 1 "Checking preconditions"
[ -n "$VERSION" ] || fail "MARKETING_VERSION is missing from project.yml"
[ -n "$BUILD_NUMBER" ] || fail "CURRENT_PROJECT_VERSION is missing from project.yml"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || fail "signing identity not found: $IDENTITY"
if [ "$NOTARIZE" = 1 ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notary profile '$NOTARY_PROFILE' does not work (see xcrun notarytool store-credentials)"
fi
[ -z "$(git status --porcelain)" ] || echo "release: warning: the working tree has uncommitted changes" >&2
rm -rf "$OUT"
mkdir -p "$OUT"

step 2 "Archiving the Release build"
xcodegen generate --quiet
xcodebuild archive \
  -project Presenter.xcodeproj -scheme Presenter -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS=--timestamp -quiet 2>&1 \
  | sed -E '/CoreSimulator|SimServiceContext|IDERunDestination|DVTErrorPresenter|^Domain:|^Code: 3|^Failure Reason|^Recovery Suggestion|^--$|^$/d'
# The export re-signs Sparkle's XPC services and helpers with the Developer ID.
# A copy out of the archive leaves them ad-hoc signed.
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/scripts/export-options.plist" -exportPath "$OUT/export" -quiet 2>&1 \
  | sed -E '/CoreSimulator|SimServiceContext|IDERunDestination|DVTErrorPresenter|^Domain:|^Code: 3|^Failure Reason|^Recovery Suggestion|^--$|^$/d'
ditto "$OUT/export/Presenter.app" "$APP"
rm -rf "$OUT/export"

step 3 "Checking the signature"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || fail "app version '$APP_VERSION' differs from MARKETING_VERSION '$VERSION'"
[ "$APP_BUILD" = "$BUILD_NUMBER" ] || fail "app build '$APP_BUILD' differs from CURRENT_PROJECT_VERSION '$BUILD_NUMBER'"
# Capture output before grep. "grep -q" exits early, and with pipefail the
# SIGPIPE to the writer fails the whole check.
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=$IDENTITY" <<<"$SIGNATURE" || fail "the app is not signed with $IDENTITY"
grep -q "flags=0x10000(runtime)" <<<"$SIGNATURE" || fail "the hardened runtime is off"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
if grep -q "get-task-allow" <<<"$ENTITLEMENTS"; then
  fail "the app has the get-task-allow entitlement (a debug signature)"
fi
# Updates download through Sparkle's Downloader service. The app itself has no network access.
if grep -q "com.apple.security.network.client" <<<"$ENTITLEMENTS"; then
  fail "the app has the network client entitlement"
fi
for name in spks spki; do
  grep -q "com.marcswan.Presenter-$name" <<<"$ENTITLEMENTS" || fail "the app has no mach-lookup entitlement for Sparkle's -$name service"
done
# Sparkle's services and helpers need their own Developer ID signature for notarization.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  PART_SIGNATURE="$(codesign -dvv "$SPARKLE/$part" 2>&1)"
  grep -q "Authority=$IDENTITY" <<<"$PART_SIGNATURE" \
    && grep -q "flags=0x10000(runtime)" <<<"$PART_SIGNATURE" \
    || fail "Sparkle $part is not signed with $IDENTITY and the hardened runtime"
done

if [ "$NOTARIZE" = 1 ]; then
  step 4 "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/Presenter.zip"
  notarize "$OUT/Presenter.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/Presenter.zip"
else
  step 4 "Skipping app notarization"
fi

step 5 "Building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Presenter.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Presenter $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  step 6 "Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  step 7 "Checking Gatekeeper"
  APP_CHECK="$(spctl -a -vv -t exec "$APP" 2>&1 || true)"
  grep -q "source=Notarized Developer ID" <<<"$APP_CHECK" || fail "Gatekeeper does not accept the app: $APP_CHECK"
  DMG_CHECK="$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
  grep -q "source=Notarized Developer ID" <<<"$DMG_CHECK" || fail "Gatekeeper does not accept the DMG: $DMG_CHECK"
else
  step 6 "Skipping DMG notarization"
  step 7 "Skipping Gatekeeper check"
fi

shasum -a 256 "$DMG"
echo "release: $DMG"
