#!/bin/bash
set -euo pipefail

# Build a signed release DMG for Whispur
# Usage: ./scripts/build-dmg.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT/build"
SCHEME="Whispur"
APP_NAME="Whispur"
IDENTITY="Developer ID Application: Sophiie AI Pty Ltd (U2KP726DRL)"
TEAM_ID="U2KP726DRL"
ENTITLEMENTS="$ROOT/Whispur.entitlements"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "==> Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Generating Xcode project"
cd "$ROOT"
xcodegen generate

echo "==> Archiving release build"
xcodebuild \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    exit 1
fi

echo "==> Re-signing app with Developer ID + hardened runtime"
codesign --force --sign "$IDENTITY" \
    --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH"

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Creating DMG"
rm -f "$DMG_PATH"

VOL_NAME="Install Whispur"
VOL_PATH="/Volumes/$VOL_NAME"
TEMP_DMG="$BUILD_DIR/Whispur-temp.dmg"

if [ -d "$VOL_PATH" ]; then
    hdiutil detach "$VOL_PATH" -force 2>/dev/null || true
    sleep 1
fi

STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -a "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -srcfolder "$STAGING" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 100m \
    "$TEMP_DMG"

MOUNT_OUTPUT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen)
DEVICE=$(echo "$MOUNT_OUTPUT" | tail -1 | awk '{print $1}')
echo "    Mounted at $VOL_PATH (device: $DEVICE)"

SetFile -a E "$VOL_PATH/Whispur.app" 2>/dev/null || true
mdutil -i off "$VOL_PATH" 2>/dev/null || true

echo "    Configuring Finder window"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 740, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set position of item "Whispur.app" of container window to {150, 190}
        set position of item "Applications" of container window to {390, 190}
        try
            set position of item ".fseventsd" of container window to {900, 900}
        end try
        try
            set position of item ".DS_Store" of container window to {900, 900}
        end try
        try
            set position of item ".Trashes" of container window to {900, 900}
        end try
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 1

chflags hidden "$VOL_PATH/.fseventsd" 2>/dev/null || true
SetFile -a V "$VOL_PATH/.fseventsd" 2>/dev/null || true
rm -rf "$VOL_PATH/.fseventsd"

hdiutil detach "$DEVICE"
sleep 1

hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$TEMP_DMG"
rm -rf "$STAGING"

echo "==> Signing DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

echo ""
echo "==> DMG created at: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
