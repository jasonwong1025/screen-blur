#!/bin/bash
# Builds build/ScreenBlur.app (menu-bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/ScreenBlur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ScreenBlur "$APP/Contents/MacOS/ScreenBlur"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ScreenBlur</string>
    <key>CFBundleIdentifier</key><string>com.jason.screenblur</string>
    <key>CFBundleExecutable</key><string>ScreenBlur</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists: macOS ties the Accessibility
# grant to the signature, and an ad-hoc one changes on every rebuild, which
# silently invalidates the grant. Override with CODESIGN_IDENTITY=... (or "-").
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
