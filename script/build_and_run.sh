#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
APP_DIR="$ROOT_DIR/.build/development/Pasta Development.app"
BINARY="$APP_DIR/Contents/MacOS/PastaDevelopment"
# Only stop this checkout's development bundle, never the installed release.
if [ -d "$APP_DIR/Contents/MacOS" ]; then
  RUNNING_BINARY="$(cd "$APP_DIR/Contents/MacOS" && pwd -P)/PastaDevelopment"
  pkill -f "$RUNNING_BINARY" >/dev/null 2>&1 || true
fi
swift build --force-resolved-versions
BUILD_DIR="$(swift build --show-bin-path)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"
cp -f "$BUILD_DIR/PastaApp" "$BINARY"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP_DIR/Contents/Frameworks/Sparkle.framework"
for resource in "$BUILD_DIR"/*.bundle; do
  [ ! -d "$resource" ] || cp -rf "$resource" "$APP_DIR/Contents/Resources/"
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$BINARY"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pasta.clipboard.development</string>
<key>CFBundleName</key><string>Pasta Development</string>
<key>CFBundleExecutable</key><string>PastaDevelopment</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>SUEnableAutomaticChecks</key><false/>
</dict></plist>
PLIST
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# SwiftPM build caches may be redirected through a symlink on this machine.
RUNNING_BINARY="$(cd "$APP_DIR/Contents/MacOS" && pwd -P)/PastaDevelopment"
case "$MODE" in
  --build-only) echo "$APP_DIR" ;;
  --debug) lldb -- "$BINARY" ;;
  run|--verify|--logs|--telemetry)
    open -n "$APP_DIR"
    if [ "$MODE" = --verify ]; then
      for _ in {1..20}; do pgrep -f "$RUNNING_BINARY" >/dev/null && exit 0; sleep 0.25; done
      echo 'Development app did not stay running' >&2; exit 1
    elif [ "$MODE" = --logs ] || [ "$MODE" = --telemetry ]; then
      log stream --info --style compact --predicate 'process == "PastaDevelopment"'
    fi ;;
  *) echo "Usage: $0 [run|--verify|--build-only|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
