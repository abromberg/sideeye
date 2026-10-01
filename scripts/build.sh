#!/bin/sh
# Build Release and install Side Eye to ~/Applications, for development. scripts/release.sh makes the distributable zip.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project SideEye.xcodeproj -scheme SideEye -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' build -quiet
mkdir -p "$HOME/Applications"
pkill -x "Side Eye" 2>/dev/null || true
rm -rf "$HOME/Applications/Side Eye.app"
cp -R "build/Build/Products/Release/Side Eye.app" "$HOME/Applications/"
# Only the installed copy should own the bundle ID (TCC keys off LaunchServices' pick).
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in build/Build/Products/*/"Side Eye.app"; do
  "$LSREG" -u "$app" 2>/dev/null || true
done
"$LSREG" -f "$HOME/Applications/Side Eye.app"
echo "Installed ~/Applications/Side Eye.app"
[ "${1:-}" = "--open" ] && open "$HOME/Applications/Side Eye.app"
exit 0
