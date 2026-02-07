#!/bin/bash
# Install audioReader to iOS Simulator with TTS models
# Models are copied to the app's data container (Documents) instead of the bundle

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="com.voicelink.audioReader"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

# Find the most recent build (exclude Index.noindex which is for Xcode's internal use)
APP_PATH=$(find "$DERIVED_DATA" -name "audioReader.app" -path "*Build/Products/Debug-iphonesimulator*" -not -path "*Index.noindex*" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "Error: audioReader.app not found in DerivedData"
    echo "Please build the project first: xcodebuild build -scheme audioReader -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro'"
    exit 1
fi

echo "Found app at: $APP_PATH"

# Check if simulator is running
if ! xcrun simctl list devices booted | grep -q "Booted"; then
    echo "Starting simulator..."
    xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
    sleep 5
fi

# Uninstall existing app
echo "Uninstalling existing app..."
xcrun simctl uninstall booted "$BUNDLE_ID" 2>/dev/null || true

# Install app
echo "Installing app..."
xcrun simctl install booted "$APP_PATH"

# Find app's DATA container (not bundle container)
DATA_CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)
echo "Data container: $DATA_CONTAINER"

# Copy TTS models to Documents/Models if they exist
MODELS_SRC="$SCRIPT_DIR/Resources/Models"
if [ -d "$MODELS_SRC" ]; then
    MODELS_DST="$DATA_CONTAINER/Documents/Models"
    echo "Copying TTS models to Documents..."
    mkdir -p "$MODELS_DST"
    rm -rf "$MODELS_DST/pocket-tts"
    cp -R "$MODELS_SRC/pocket-tts" "$MODELS_DST/"
    echo "TTS models copied successfully"

    # Show what was copied
    echo "TTS models:"
    ls -la "$MODELS_DST/pocket-tts/"
else
    echo "No Models folder found at $MODELS_SRC"
fi

echo ""
echo "Installation complete!"
echo "Launching app..."
xcrun simctl launch booted "$BUNDLE_ID"
