#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
APP="$ROOT/dist/CleanAlephaMac98.app"
STAGE="$ROOT/dist/dmg-root"
VOL="CleanAlephaMac98"
DMG="$ROOT/dist/CleanAlephaMac98.dmg"
TMP_DMG="$ROOT/dist/.tmp.dmg"
BG="$ROOT/packaging/dmg-background.png"

zsh "$ROOT/packaging/make-app.sh" "$APP"

rm -rf "$STAGE" "$TMP_DMG" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CleanAlephaMac98.app"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$VOL" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$BG" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "CleanAlephaMac98.app" 160 175 \
    --hide-extension "CleanAlephaMac98.app" \
    --app-drop-link 500 175 \
    --no-internet-enable \
    "$DMG" \
    "$STAGE"
else
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

# Prefer a real Finder alias so the Applications drop-target keeps its folder icon.
if [[ -f "$DMG" ]]; then
  hdiutil convert "$DMG" -format UDRW -ov -o "$TMP_DMG" >/dev/null
  MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" | awk '/\/Volumes\//{print $NF; exit}')"
  if [[ -n "${MOUNT:-}" && -d "$MOUNT" ]]; then
    rm -f "$MOUNT/Applications"
    osascript <<EOF >/dev/null 2>&1 || true
tell application "Finder"
  make new alias file at POSIX file "$MOUNT" to POSIX file "/Applications" with properties {name:"Applications"}
end tell
EOF
    if [[ -e "$MOUNT/Applications alias" && ! -e "$MOUNT/Applications" ]]; then
      mv "$MOUNT/Applications alias" "$MOUNT/Applications"
    fi
    sync
    hdiutil detach "$MOUNT" >/dev/null
    rm -f "$DMG"
    hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
  fi
  rm -f "$TMP_DMG"
fi

echo "dmg $DMG ($VERSION)"
ls -lh "$DMG"
