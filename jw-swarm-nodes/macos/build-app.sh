#!/usr/bin/env bash
# Build JWSwarmNode and wrap it in a proper .app bundle so the menu-bar agent
# works reliably. Running the bare `swift run` binary does NOT register a
# clickable status-bar menu on macOS; an LSUIElement .app bundle is required.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="JWSwarmNode"
CONFIG="${1:-debug}"
ICON_SVG="Sources/JWSwarmNode/Resources/JWIcon.svg"

echo "Building ($CONFIG)..."
if [ "$CONFIG" = "release" ]; then
  swift build -c release
  BIN=".build/release/$APP_NAME"
else
  swift build
  BIN=".build/debug/$APP_NAME"
fi

BIN_DIR="$(dirname "$BIN")"

APP_BUNDLE="build/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy SwiftPM-generated resource bundle(s) into Resources (codesign-safe
# location). Icon loading resolves this path directly.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
done

# Build a macOS app icon from the SVG source.
if [ -f "$ICON_SVG" ]; then
  TMP_DIR=$(mktemp -d)
  ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  BASE_PNG="$TMP_DIR/icon_1024.png"

  sips -s format png "$ICON_SVG" --out "$BASE_PNG" >/dev/null

  sips -z 16 16 "$BASE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$BASE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$BASE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$BASE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$BASE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$BASE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$BASE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$BASE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$BASE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  cp "$BASE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

  iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$TMP_DIR"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>JWSwarmNode</string>
  <key>CFBundleIdentifier</key>
  <string>com.jwraats.jwswarmnode</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>JW Swarm Node</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the app has a stable code identity (required for some macOS
# UI services to trust the process).
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Launch with: open \"$APP_BUNDLE\""
