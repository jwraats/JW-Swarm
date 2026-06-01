#!/usr/bin/env bash
# Build JWSwarmNode and wrap it in a proper .app bundle so the menu-bar agent
# works reliably. Running the bare `swift run` binary does NOT register a
# clickable status-bar menu on macOS; an LSUIElement .app bundle is required.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="JWSwarmNode"
CONFIG="${1:-debug}"

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

# Copy SwiftPM-generated resource bundle(s) into Resources so Bundle.module can
# find them (menu-bar icon, etc.). Resources/ is the codesign-friendly location.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
done

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
