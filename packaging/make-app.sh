#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/packaging/Info.plist")"
APP="${1:-$ROOT/dist/CleanAlephaMac98.app}"

echo "building CleanAlephaMac98 $VERSION"

BIN=""
if swift build -c release --product CleanAlephaMac98 --arch arm64 --arch x86_64; then
  if [[ -x "$ROOT/.build/apple/Products/Release/CleanAlephaMac98" ]]; then
    BIN="$ROOT/.build/apple/Products/Release/CleanAlephaMac98"
  fi
fi
if [[ -z "$BIN" ]]; then
  swift build -c release --product CleanAlephaMac98
  BIN="$ROOT/.build/release/CleanAlephaMac98"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CleanAlephaMac98"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/packaging/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT/packaging/Resources/"*.png "$APP/Contents/Resources/"
if ls "$ROOT/packaging/Resources/"*.wav >/dev/null 2>&1; then
  cp "$ROOT/packaging/Resources/"*.wav "$APP/Contents/Resources/"
fi

ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
SRC="$ROOT/packaging/Resources/AppIcon.png"
sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/CleanAlephaMac98"

# Sign with a stable identity when one exists. macOS privacy grants (Full Disk Access) are bound to
# the app's designated requirement; with ad-hoc signing that requirement is the binary's cdhash, so
# every rebuild silently lost the grant. A certificate-based requirement survives rebuilds.
# Override with CAM98_SIGN_IDENTITY="…" (or "-" to force ad-hoc).
IDENTITY="${CAM98_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  IDENTITY="$(print -r -- "$IDS" | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(print -r -- "$IDS" | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)"
  fi
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] && codesign -s "$IDENTITY" --force --deep "$APP" >/dev/null 2>&1; then
  echo "signed: stable identity (privacy grants survive rebuilds)"
else
  codesign -s - --force --deep "$APP" >/dev/null 2>&1 || true
  echo "signed: ad-hoc — Full Disk Access must be re-granted after every rebuild"
fi
echo "app $APP"
file "$APP/Contents/MacOS/CleanAlephaMac98"
