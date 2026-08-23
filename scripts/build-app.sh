#!/bin/bash
# Assembles an ad-hoc signed Sapo.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.1.0)"
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Sapo"

APP="build/Sapo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/Sapo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Sapo</string>
    <key>CFBundleIdentifier</key><string>com.sapomac.Sapo</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Sapo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sapo records audio from applications and your microphone as separate tracks.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (${VERSION})"

if [ "${DMG:-0}" = "1" ]; then
    DMG_PATH="build/Sapo-${VERSION}.dmg"
    rm -f "$DMG_PATH"
    hdiutil create -volname "Sapo" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH"
    echo "Built $DMG_PATH"
fi
