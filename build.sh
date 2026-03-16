#!/bin/bash
set -e

SCHEME="ClipStack"
CONFIG="Release"
ARCHIVE_PATH="build/ClipStack.xcarchive"
EXPORT_PATH="build/"

echo "Building ClipStack..."

xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "Exporting archive..."

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist ExportOptions.plist

echo "Build complete: build/ClipStack.app"

# Optional: create DMG (requires create-dmg: brew install create-dmg)
if command -v create-dmg &> /dev/null; then
  echo "Creating DMG..."
  create-dmg \
    --volname "ClipStack" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "ClipStack.app" 175 190 \
    --app-drop-link 425 190 \
    "build/ClipStack.dmg" \
    "build/ClipStack.app"
  echo "DMG created: build/ClipStack.dmg"
fi
