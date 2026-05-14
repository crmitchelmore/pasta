#!/usr/bin/env bash
# Local development build of Pasta.app — useful for smoke-testing a release
# binary outside of CI. The official signed/notarized build is produced by
# .github/workflows/release.yml off a v* tag.
#
# Override version metadata via env vars (defaults are obviously a dev build):
#   PASTA_VERSION=1.0.0 PASTA_BUILD=42 ./build_release.sh
set -euo pipefail

EXECUTABLE_NAME="PastaApp"
APP_NAME="Pasta"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

PASTA_VERSION="${PASTA_VERSION:-0.0.0-dev}"
PASTA_BUILD="${PASTA_BUILD:-0}"

echo "==> Building release binary (version=$PASTA_VERSION build=$PASTA_BUILD)"
swift build -c release

echo "==> Staging app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp -R "$ROOT_DIR/Sources/PastaApp/Resources/" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Resources/DMG/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Creating Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>${PASTA_BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${PASTA_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>PastaApp</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Chris Mitchelmore</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> Done: $APP_DIR"
echo "Next: codesign --deep --force --options runtime --sign \"Developer ID Application: ...\" \"$APP_DIR\""
echo "Then: xcrun notarytool submit \"$APP_DIR\" --wait --keychain-profile \"notary\""
