#!/bin/sh
# Package an app into a disk image that opens to a drag-to-Applications window.
# Usage: scripts/make-dmg.sh "path/to/Side Eye.app" path/to/Side-Eye.dmg
# Finder lays out the window, so this needs a logged-in session, and the first run asks to let Terminal control Finder.
set -eu
APP="$1"
DMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Side Eye"
# Finder only finds the volume by name, so another disk with this name would get the layout instead.
if [ -e "/Volumes/$NAME" ]; then
  echo "Eject the disk named \"$NAME\" first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "/Volumes/$NAME" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir "$WORK/stage" "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/$NAME.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$ROOT/design/dmg-background.tiff" "$WORK/stage/.background/background.tiff"

# Writable first, with room for the .DS_Store Finder saves the layout in.
SIZE=$(( $(du -sm "$WORK/stage" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$NAME" -fs HFS+ -format UDRW -size "${SIZE}m" "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"

# Icon centers here match the arrow in design/dmg-background.svg. The window is 640 × 400 below its 32-point title bar.
osascript <<EOF
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 552}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

# Finder writes .DS_Store on its own schedule. Wait for it, so the layout makes it into the image.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "/Volumes/$NAME/.DS_Store" ] && break
  sleep 1
done
[ -s "/Volumes/$NAME/.DS_Store" ] || { echo "Finder didn't save the window layout." >&2; exit 1; }
# The disk's own icon goes on last: Finder removes it while saving the layout.
cp "$APP/Contents/Resources/AppIcon.icns" "/Volumes/$NAME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$NAME"
rm -rf "/Volumes/$NAME/.fseventsd"
sync
hdiutil detach -quiet "/Volumes/$NAME"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$DMG"
echo "Made $DMG"
