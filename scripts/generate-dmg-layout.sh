#!/bin/bash
set -euo pipefail

# Regenerates Resources/DMG/Layout/<volume name>.DS_Store, the Finder window
# layout that ci-create-macos-dmg.sh copies into every release DMG. Run it on a
# Mac with a logged-in desktop (Finder must answer AppleEvents) whenever the
# layout in ci-create-macos-dmg.sh, the background or a train's display name
# changes, then commit the results. Needs create-dmg on PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAYOUT_DIR="$ROOT/Resources/DMG/Layout"
WORK_DIR="$(mktemp -d)"
mount_point=""
cleanup() {
    [[ -n "$mount_point" ]] && hdiutil detach -quiet "$mount_point" || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$LAYOUT_DIR"

generate() {
    local volume_name="$1" icon="$2"
    local app="$WORK_DIR/$volume_name/$volume_name.app"
    local dmg="$WORK_DIR/$volume_name.dmg"
    mkdir -p "$app/Contents/MacOS"
    echo "==> Laying out $volume_name in Finder"
    bash "$SCRIPT_DIR/ci-create-macos-dmg.sh" --finder-layout "$volume_name" "$icon" "$dmg" "$app"
    mount_point="$(mktemp -d)"
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg"
    cp -f "$mount_point/.DS_Store" "$LAYOUT_DIR/$volume_name.DS_Store"
    hdiutil detach -quiet "$mount_point"
    rmdir "$mount_point"
    mount_point=""
    echo "    wrote Resources/DMG/Layout/$volume_name.DS_Store"
}

generate "Pasta" "$ROOT/Resources/DMG/AppIcon.icns"
generate "Pasta Alpha" "$ROOT/Resources/DMG/AppIconAlpha.icns"
