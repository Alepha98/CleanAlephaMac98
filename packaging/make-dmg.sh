#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
APP="$ROOT/dist/CleanAlephaMac98.app"
STAGE="$ROOT/dist/dmg-root"
VOL="CleanAlephaMac98"
DMG="$ROOT/dist/CleanAlephaMac98.dmg"
RW="$ROOT/dist/.rw.dmg"
BG_SRC="$ROOT/packaging/dmg-background.png"
BG_TIFF="$ROOT/packaging/dmg-background.tiff"
DS_STORE="$ROOT/packaging/dmg-DS_Store"

# Window is 660×400 pt. Retina needs 1320×800 px; classic needs 660×400 px.
# TIFF with both @72dpi is the reliable Finder background format.
prepare_background() {
  local one="$ROOT/dist/.dmg-bg-1x.png"
  local two="$ROOT/dist/.dmg-bg-2x.png"
  mkdir -p "$ROOT/dist"
  sips -z 400 660 "$BG_SRC" --out "$one" >/dev/null
  sips -z 800 1320 "$BG_SRC" --out "$two" >/dev/null
  sips -s dpiWidth 72 -s dpiHeight 72 "$one" >/dev/null
  sips -s dpiWidth 72 -s dpiHeight 72 "$two" >/dev/null
  tiffutil -cathidpicheck "$one" "$two" -out "$BG_TIFF"
  rm -f "$one" "$two"
}

zsh "$ROOT/packaging/make-app.sh" "$APP"
prepare_background

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CleanAlephaMac98.app"
ln -s /Applications "$STAGE/Applications"

# Sized RW image, then decorate Finder view.
SIZE_MB="$(du -sm "$STAGE" | awk '{print int($1) + 40}')"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -size "${SIZE_MB}m" "$RW" >/dev/null

MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/\/Volumes\//{print $NF; exit}')"
[[ -n "${MOUNT:-}" && -d "$MOUNT" ]]

# Volume icon
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT" 2>/dev/null || true
fi

mkdir -p "$MOUNT/.background"
cp "$BG_TIFF" "$MOUNT/.background/background.tiff"
# Hide clutter
SetFile -a V "$MOUNT/.background" 2>/dev/null || true

# Prefer a checked-in .DS_Store (works on CI without Finder automation).
if [[ -f "$DS_STORE" ]]; then
  cp "$DS_STORE" "$MOUNT/.DS_Store"
  SetFile -a V "$MOUNT/.DS_Store" 2>/dev/null || true
else
  # Local GUI path: ask Finder to style the window, then we can refresh the template.
  osascript <<EOF || true
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "CleanAlephaMac98.app" of container window to {165, 155}
    set position of item "Applications" of container window to {495, 155}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
  sleep 2
  if [[ -f "$MOUNT/.DS_Store" ]]; then
    cp "$MOUNT/.DS_Store" "$DS_STORE"
    echo "wrote packaging/dmg-DS_Store from Finder"
  fi
fi

sync
hdiutil detach "$MOUNT" >/dev/null
# Wait for detach to settle
sleep 1
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW"

echo "dmg $DMG ($VERSION)"
ls -lh "$DMG"
