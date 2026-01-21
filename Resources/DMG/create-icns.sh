#!/bin/bash
# Creates AppIcon.icns from PNG files in the Assets.xcassets/AppIcon.appiconset directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ICON_SET="$REPO_ROOT/Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset"
OUTPUT_DIR="$SCRIPT_DIR"

# Create temporary iconset
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"

echo "==> Creating iconset from PNG files..."

# Copy and rename files to match iconset naming convention
cp "$ICON_SET/icon_16x16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SET/icon_16x16@2x.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SET/icon_32x32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SET/icon_32x32@2x.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SET/icon_128x128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SET/icon_128x128@2x.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SET/icon_256x256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SET/icon_256x256@2x.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SET/icon_512x512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SET/icon_512x512@2x.png" "$ICONSET_DIR/icon_512x512@2x.png"

echo "==> Converting iconset to icns..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_DIR/AppIcon.icns"

# Cleanup
rm -rf "$(dirname "$ICONSET_DIR")"

echo "==> Created: $OUTPUT_DIR/AppIcon.icns"
ls -la "$OUTPUT_DIR/AppIcon.icns"
