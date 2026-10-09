#!/usr/bin/env bash
# Builds a Developer ID signed, notarized SimPR.dmg.
#
# Requirements:
#   - A "Developer ID Application" certificate in the login keychain.
#   - A notarytool keychain profile:  xcrun notarytool store-credentials simpr-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific password>
#
# Environment:
#   DEVELOPMENT_TEAM          Apple team ID (required)
#   SIMPR_GITHUB_CLIENT_ID    OAuth app client ID with Device Flow enabled (recommended)
#   NOTARY_PROFILE            notarytool profile name (default: simpr-notary)
#   SKIP_NOTARIZE=1           sign only (for testing the script)
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-simpr-notary}"
BUILD_DIR="${BUILD_DIR:-$PWD/../dist}"
ARCHIVE="$BUILD_DIR/SimPR.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/SimPR-release}"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
fi

xcodebuild archive \
  -project SimPR.xcodeproj \
  -scheme SimPR \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  SIMPR_GITHUB_CLIENT_ID="${SIMPR_GITHUB_CLIENT_ID:-}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

sed "s/__TEAM_ID__/$DEVELOPMENT_TEAM/" Scripts/ExportOptions.plist > "$BUILD_DIR/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP="$EXPORT_DIR/SimPR.app"
codesign --verify --deep --strict --verbose=2 "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/SimPR-$VERSION.dmg"

STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/SimPR.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SimPR" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ "${SKIP_NOTARIZE:-}" != "1" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "Built $DMG"
echo "version: $VERSION"
echo "sha256:  $SHA256"
echo "Update Packaging/simpr.rb with these values, then upload the DMG to a GitHub release tagged mac-v$VERSION."
