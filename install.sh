#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Hex God Screenshot Master"
BUNDLE_ID="dev.leekool.hex-god-screenshot-master"
EXECUTABLE="hex-god-screenshot-master"
SIGNING_IDENTITY="Hex God Screenshot Master Local Signing"
APP_ROOT="${1:-$HOME/Applications}"
APP="$APP_ROOT/$APP_NAME.app"
LAUNCHER="$HOME/.local/bin/$EXECUTABLE"

swift build -c release

if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
    scripts/setup-local-signing.sh >/dev/null
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"

mkdir -p "$(dirname "$LAUNCHER")"
printf '#!/bin/sh\nopen -a %q\n' "$APP" > "$LAUNCHER"
chmod +x "$LAUNCHER"

echo "Installed: $APP"
echo "Launcher:  $LAUNCHER"
echo
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo "Add this to your shell config if needed:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi
