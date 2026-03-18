#!/bin/bash
set -e

SCHEME="Copiha"
CONFIG="Release"
ARCHIVE_PATH="build/Copiha.xcarchive"
EXPORT_PATH="build/"

echo "Building Copiha..."

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

echo "Build complete: build/Copiha.app"

# Optional: create DMG (requires create-dmg: brew install create-dmg)
if command -v create-dmg &> /dev/null; then
  echo "Creating DMG..."
  create-dmg \
    --volname "Copiha" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Copiha.app" 175 190 \
    --app-drop-link 425 190 \
    "build/Copiha.dmg" \
    "build/Copiha.app"
  echo "DMG created: build/Copiha.dmg"
fi
