#!/bin/bash
set -euo pipefail

# Full release workflow for Whispur
# Usage: ./scripts/release.sh <version> [release-notes-file]

if [ $# -lt 1 ]; then
    echo "Usage: $0 <version> [release-notes-file]"
    echo "Example: $0 0.1.0 RELEASE_NOTES.md"
    exit 1
fi

VERSION="$1"
NOTES_FILE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT/build"
DMG_PATH="$BUILD_DIR/Whispur.dmg"
REPO="sophiie-ai/whispur"
TAG="v$VERSION"

echo "============================================"
echo "  Releasing Whispur $TAG"
echo "============================================"

echo "==> Step 1: Building DMG"
"$SCRIPT_DIR/build-dmg.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG not found at $DMG_PATH"
    exit 1
fi

echo ""
echo "==> Step 2: Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "notarytool" \
    --wait

echo ""
echo "==> Step 3: Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo ""
echo "==> Step 4: Creating GitHub release $TAG"

if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo "    Deleting existing release $TAG"
    gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag
fi

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    gh release create "$TAG" \
        --repo "$REPO" \
        --title "Whispur $TAG" \
        --notes-file "$NOTES_FILE" \
        "$DMG_PATH"
else
    gh release create "$TAG" \
        --repo "$REPO" \
        --title "Whispur $TAG" \
        --generate-notes \
        "$DMG_PATH"
fi

echo ""
echo "============================================"
echo "  Whispur $TAG released successfully!"
echo "============================================"
echo "  DMG:     $DMG_PATH"
echo "  Release: https://github.com/$REPO/releases/tag/$TAG"
