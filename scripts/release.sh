#!/bin/sh
# Build a Developer ID–signed, notarized Side Eye and its Sparkle appcast, in build/release/dist/.
# Needs, once: a "Developer ID Application" certificate in the keychain, the Sparkle signing key (Sparkle's
# generate_keys) in the keychain, and a notarytool profile:
#   xcrun notarytool store-credentials side-eye --apple-id <email> --team-id <team ID>
# Usage: DEVELOPER_ID="Developer ID Application: Experimental LLC (<team ID>)" scripts/release.sh
set -eu
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
# The team is the ID in parentheses at the end of a Developer ID certificate's name.
TEAM_ID="${TEAM_ID:-$(echo "$DEVELOPER_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}"
: "${TEAM_ID:?Set TEAM_ID to your Apple team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-side-eye}"
OUT=build/release
DIST="$OUT/dist"
xcodegen generate --quiet
rm -rf "$OUT"
xcodebuild -project SideEye.xcodeproj -scheme SideEye -configuration Release \
  -derivedDataPath "$OUT" -destination 'generic/platform=macOS' build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
APP="$OUT/Build/Products/Release/Side Eye.app"

# Xcode leaves Sparkle's helpers ad-hoc signed. Notarization needs every piece signed with the Developer ID,
# innermost first, and then the app again.
sign() { codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# The app's own entitlements only: notarization rejects the debugging one (get-task-allow) Xcode can add.
sign --entitlements App/SideEye.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
FEED=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$PLIST")
mkdir -p "$DIST"
ZIP="$DIST/Side-Eye-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
# notarytool exits 0 even when Apple rejects the build, so check the verdict.
NOTARY=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait)
echo "$NOTARY"
if ! echo "$NOTARY" | grep -q "status: Accepted"; then
  ID=$(echo "$NOTARY" | sed -n 's/^ *id: //p' | head -1)
  echo "Notarization failed. Apple's reasons: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$APP"
# Re-zip so the download carries the stapled ticket and opens offline.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The appcast lists this version, signed with the Sparkle key, downloading from the matching GitHub release.
TAG="v$VERSION"
"$OUT/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --download-url-prefix "${FEED%/latest/download/appcast.xml}/download/$TAG/" "$DIST"
echo
echo "Ready in $DIST. To publish:"
echo "  gh release create $TAG \"$ZIP\" \"$DIST/appcast.xml\" --title \"Side Eye $VERSION\" --generate-notes"
