#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Meeting Recorder"
BUNDLE_ID="com.simplyai.meeting-recorder"
APP="/Applications/${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "=== Building Meeting Recorder (SPM) ==="

swift build -c release 2>&1

echo "=== Building .app bundle ==="

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/MeetingRecorder" "$APP/Contents/MacOS/MeetingRecorder"

# Copy icon if available
if [ -f "../AppIcon.icns" ]; then
    cp "../AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Info.plist
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>6.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>6.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- LSUIElement removed: the app launches with a window and dock icon.
         MainView toggles NSApp.activationPolicy between .regular (window open)
         and .accessory (window closed, menu-bar-only). -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Meeting Recorder needs microphone access to record your meetings.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Meeting Recorder captures system audio output so both sides of video calls are recorded.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Entitlements
cat > "$BUILD_DIR/entitlements.plist" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

# Sign with entitlements
codesign --force --deep --sign - \
    --entitlements "$BUILD_DIR/entitlements.plist" \
    "$APP" 2>/dev/null

xattr -cr "$APP"

echo ""
echo "=== Installed: $APP ==="
echo "Open from Spotlight or: open -a '${APP_NAME}'"
