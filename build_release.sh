#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PastaApp"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release

echo "==> Staging app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp -R "$ROOT_DIR/Sources/PastaApp/Resources/" "$APP_DIR/Contents/Resources/"

echo "==> Creating Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Pasta</string>
    <key>CFBundleDisplayName</key>
    <string>Pasta</string>
    <key>CFBundleIdentifier</key>
    <string>com.pasta.clipboard</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>PastaApp</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Pasta</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> Done: $APP_DIR"
echo "Next: codesign --deep --force --options runtime --sign \"Developer ID Application: ...\" \"$APP_DIR\""
echo "Then: xcrun notarytool submit \"$APP_DIR\" --wait --keychain-profile \"notary\""
