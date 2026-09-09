#!/usr/bin/env bash
# Local Alpha preview. Distribution still goes through the manifest/CI workers.
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift build --force-resolved-versions
BIN_DIR="$(xcrun swift build --show-bin-path)"
APP_DIR="${PASTA_ALPHA_OUTPUT:-$PWD/.build/alpha/Pasta Alpha.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"
cp -f "$BIN_DIR/PastaApp" "$APP_DIR/Contents/MacOS/PastaApp"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP_DIR/Contents/Frameworks/Sparkle.framework"
for resource in "$BIN_DIR"/*.bundle; do
  [ ! -d "$resource" ] || ditto "$resource" "$APP_DIR/Contents/Resources/$(basename "$resource")"
done
cp -f Resources/DMG/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_DIR/Contents/MacOS/PastaApp"
export APP_DIR
python3 - <<'PY'
import os,plistlib,json,subprocess
from pathlib import Path
app=Path(os.environ['APP_DIR']);c=json.loads(Path('Sources/PastaCore/Resources/ReleaseTrains.json').read_text())['alpha']
info={'CFBundleIdentifier':c['macBundleIdentifier'],'CFBundleName':c['displayName'],'CFBundleDisplayName':c['displayName'],'CFBundleExecutable':'PastaApp','CFBundleIconFile':'AppIcon','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.0.0','LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication','PastaReleaseTrain':'alpha','SUEnableAutomaticChecks':False,'GitCommitSHA':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
if [ -n "${PASTA_ALPHA_PROFILE:-}" ]; then
  : "${CODE_SIGN_IDENTITY:?A matching Developer ID identity is required}"
  cp -f "$PASTA_ALPHA_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$(mktemp)"
  export ENTITLEMENTS
  python3 - <<'PY'
import os,plistlib
from pathlib import Path
p=plistlib.loads(Path('Resources/release.entitlements').read_bytes())
p['com.apple.application-identifier']='8X4ZN58TYH.com.pasta.clipboard.alpha'
p['com.apple.developer.icloud-container-identifiers']=['iCloud.com.pasta.ios.alpha']
Path(os.environ['ENTITLEMENTS']).write_bytes(plistlib.dumps(p))
PY
  codesign --force --deep --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
  rm -f "$ENTITLEMENTS"
else
  codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
if [ "${1:-}" != --build-only ]; then open -n "$APP_DIR"; fi
printf '%s\n' "$APP_DIR"
