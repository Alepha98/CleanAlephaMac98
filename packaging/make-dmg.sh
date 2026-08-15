#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
APP="$ROOT/dist/CleanAlephaMac98.app"
STAGE="$ROOT/dist/dmg-root"
VOL="CleanAlephaMac98"
DMG="$ROOT/dist/CleanAlephaMac98.dmg"
BG="$ROOT/packaging/dmg-background.png"

zsh "$ROOT/packaging/make-app.sh" "$APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CleanAlephaMac98.app"

# 1320×800 px @ 72 dpi is treated as 1320×800 pt, so a 660×400 window crops the art
# and clips the icons. 144 dpi makes those pixels fill the window on Retina.
sips -s dpiWidth 144 -s dpiHeight 144 "$BG" >/dev/null

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$VOL" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$BG" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "CleanAlephaMac98.app" 165 155 \
    --hide-extension "CleanAlephaMac98.app" \
    --app-drop-link 495 155 \
    --no-internet-enable \
    "$DMG" \
    "$STAGE"
else
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

echo "dmg $DMG ($VERSION)"
ls -lh "$DMG"
