#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
APP="$ROOT/dist/CleanAlephaMac98.app"
STAGE="$ROOT/dist/dmg-root"
VOL="CleanAlephaMac98"
DMG="$ROOT/dist/CleanAlephaMac98.dmg"
RW="$ROOT/dist/.rw-dmg.dmg"
BG="$ROOT/packaging/dmg-background.png"
DS_STORE="$ROOT/packaging/dmg-DS_Store"

zsh "$ROOT/packaging/make-app.sh" "$APP"

# 1320×800 @ 72dpi ⇒ full-size window (144dpi half-size clipped Applications).
sips -s dpiWidth 72 -s dpiHeight 72 "$BG" >/dev/null

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/CleanAlephaMac98.app"
ln -sf /Applications "$STAGE/Applications"
cp "$BG" "$STAGE/.background/background.png"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

SIZE_MB="$(du -sm "$STAGE" | awk '{print int($1) + 50}')"

# Prefer Finder styling locally. On CI (no reliable Finder automation) reuse a
# checked-in .DS_Store captured from a good local build.
if [[ "${CI:-}" == "true" || "${CAM98_DMG_USE_TEMPLATE:-}" == "1" ]]; then
  if [[ ! -f "$DS_STORE" ]]; then
    echo "missing $DS_STORE for CI template build" >&2
    exit 1
  fi
  cp "$DS_STORE" "$STAGE/.DS_Store"
  hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -size "${SIZE_MB}m" \
    "$DMG" >/dev/null
else
  hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_MB}m" \
    "$RW" >/dev/null

  MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/\/Volumes\//{print $NF; exit}')"
  [[ -n "${MOUNT:-}" && -d "$MOUNT" ]]

  SetFile -a C "$MOUNT" 2>/dev/null || true
  SetFile -a V "$MOUNT/.background" 2>/dev/null || true

  # macOS 15+/26: relative "file of folder of disk" often fails (-10006).
  # POSIX path works. Window matches art 1:1 at 72dpi so nothing is clipped.
  osascript <<EOF
tell application "Finder"
  activate
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 80, 1420, 880}
    delay 0.3
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    try
      set text size of opts to 14
    end try
    set background picture of opts to POSIX file "$MOUNT/.background/background.png"
    delay 0.5
    set position of item "CleanAlephaMac98.app" of container window to {340, 350}
    set position of item "Applications" of container window to {980, 350}
    delay 0.5
    close
    open
    delay 1
    set icon size of icon view options of container window to 128
    set bounds of container window to {100, 80, 1420, 880}
    set position of item "CleanAlephaMac98.app" of container window to {340, 350}
    set position of item "Applications" of container window to {980, 350}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

  VERIFY="$(osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set w to container window
    set b to bounds of w
    set wW to (item 3 of b) - (item 1 of b)
    set wH to (item 4 of b) - (item 2 of b)
    set icn to icon size of icon view options of w
    try
      set background picture of icon view options of w to POSIX file "$MOUNT/.background/background.png"
      set ok to "bg-ok"
    on error e
      set ok to "bg-fail:" & e
    end try
    try
      set n to count of items
    on error
      set n to -1
    end try
    close
    return "size=" & wW & "x" & wH & " icons=" & icn & " items=" & n & " " & ok
  end tell
end tell
EOF
)"
  echo "verify: $VERIFY"
  echo "$VERIFY" | grep -q 'size=1320x800' || { echo "bad window size" >&2; exit 1; }
  echo "$VERIFY" | grep -q 'icons=128' || { echo "bad icon size" >&2; exit 1; }
  echo "$VERIFY" | grep -q 'bg-ok' || { echo "background not applied" >&2; exit 1; }
  test -f "$MOUNT/.DS_Store"
  cp "$MOUNT/.DS_Store" "$DS_STORE"

  sync
  hdiutil detach "$MOUNT" >/dev/null
  sleep 1
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
  rm -f "$RW"
fi

echo "dmg $DMG ($VERSION)"
ls -lh "$DMG"
test -f "$DMG"
