#!/bin/sh
# Builds ClaudeNative and wraps it in an .app bundle at build/ClaudeNative.app.
set -eu
cd "$(dirname "$0")/.."
swift build -c "${CONFIG:-debug}"
BIN="$(swift build -c "${CONFIG:-debug}" --show-bin-path)/ClaudeNative"
APP=build/ClaudeNative.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNative"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>net.bopp.ClaudeNative</string>
  <key>CFBundleName</key><string>ClaudeNative</string>
  <key>CFBundleDisplayName</key><string>Claude Native</string>
  <key>CFBundleExecutable</key><string>ClaudeNative</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
