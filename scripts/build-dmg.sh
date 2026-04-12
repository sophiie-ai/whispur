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
PROJECT_FILE="$ROOT/$APP_NAME.xcodeproj"

marketing_version_from_project() {
    sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' "$ROOT/project.yml" | head -1
}

version_to_build_number() {
    local version="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"
    echo $((10#$major * 10000 + 10#$minor * 100 + 10#$patch))
}

sparkle_version_dir() {
    local framework_path="$1"
    local current_link="$framework_path/Versions/Current"

    if [ -L "$current_link" ]; then
        echo "$framework_path/Versions/$(readlink "$current_link")"
        return
    fi

    find "$framework_path/Versions" -maxdepth 1 -mindepth 1 -type d | head -1
}

sign_sparkle_framework() {
    local framework_path="$1"
    local version_dir

    [ -d "$framework_path" ] || return 0
    version_dir="$(sparkle_version_dir "$framework_path")"
    [ -n "$version_dir" ] || return 0

    echo "==> Re-signing Sparkle framework internals"

    for binary in Downloader Installer; do
        local path="$version_dir/XPCServices/$binary.xpc/Contents/MacOS/$binary"
        [ -f "$path" ] && codesign --force --sign "$IDENTITY" --timestamp --options runtime "$path"
    done

    local updater_binary="$version_dir/Updater.app/Contents/MacOS/Updater"
    [ -f "$updater_binary" ] && codesign --force --sign "$IDENTITY" --timestamp --options runtime "$updater_binary"

    local autoupdate_binary="$version_dir/Autoupdate"
    [ -f "$autoupdate_binary" ] && codesign --force --sign "$IDENTITY" --timestamp --options runtime "$autoupdate_binary"

    for xpc in Downloader.xpc Installer.xpc; do
        local bundle="$version_dir/XPCServices/$xpc"
        [ -d "$bundle" ] && codesign --force --sign "$IDENTITY" --timestamp --options runtime "$bundle"
    done

    local updater_app="$version_dir/Updater.app"
    [ -d "$updater_app" ] && codesign --force --sign "$IDENTITY" --timestamp --options runtime "$updater_app"
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$framework_path"
}

MARKETING_VERSION="${MARKETING_VERSION:-$(marketing_version_from_project)}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-$(version_to_build_number "$MARKETING_VERSION")}"

echo "==> Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Generating Xcode project"
cd "$ROOT"
xcodegen generate

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: create-dmg is required. Install it with: brew install create-dmg"
    exit 1
fi

echo "==> Archiving release build"
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    exit 1
fi

SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
sign_sparkle_framework "$SPARKLE_FW"

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
create-dmg \
    --volname "Install Whispur" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "Whispur.app" 150 190 \
    --hide-extension "Whispur.app" \
    --app-drop-link 390 190 \
    --text-size 13 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" || true

[ -f "$DMG_PATH" ] || { echo "ERROR: DMG not created"; exit 1; }

echo "==> Signing DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

echo ""
echo "==> DMG created at: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
echo "    Marketing version: $MARKETING_VERSION"
echo "    Build number: $CURRENT_PROJECT_VERSION"
