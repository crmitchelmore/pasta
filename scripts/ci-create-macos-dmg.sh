#!/bin/bash
set -euo pipefail

# Usage: ci-create-macos-dmg.sh [--finder-layout] <volume name> <train icon.icns> <output.dmg> <app bundle>
#
# The window layout (background, icon positions, window size) comes from the
# committed Finder metadata in Resources/DMG/Layout/<volume name>.DS_Store, so
# releases never script Finder: on the headless release runner Finder
# AppleEvents time out (-1712) and the DMG step fails. --finder-layout drives
# Finder instead; scripts/generate-dmg-layout.sh uses it to regenerate the
# templates on a Mac with a logged-in desktop after the layout below changes.
#
# LZMA is lossless and supported since macOS 10.15 (Pasta requires macOS 14).
# The volume icon is the train ICNS without its 1024 px slot.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DMG_RESOURCES="${PASTA_DMG_RESOURCES:-$ROOT/Resources/DMG}"

finder_layout=0
if [[ "${1:-}" == "--finder-layout" ]]; then
    finder_layout=1
    shift
fi
if (($# != 4)); then
    echo "usage: $0 [--finder-layout] <volume name> <train icon.icns> <output.dmg> <app bundle>" >&2
    exit 2
fi
volume_name="$1" icon="$2" output="$3" app="$4"
app_name="$(basename "$app")"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
python3 "$SCRIPT_DIR/ci-slim-icns.py" "$icon" "$WORK_DIR/VolumeIcon.icns"

args=(
    --format ULMO
    --volname "$volume_name"
    --volicon "$WORK_DIR/VolumeIcon.icns"
    --background "$DMG_RESOURCES/background@2x.png"
    --window-pos 200 120
    --window-size 660 400
    --icon-size 100
    --icon "$app_name" 180 200
    --app-drop-link 480 200
    --hide-extension "$app_name"
    --no-internet-enable
)
if ((finder_layout == 0)); then
    template="$DMG_RESOURCES/Layout/$volume_name.DS_Store"
    if [[ ! -s "$template" ]]; then
        echo "::error::Missing DMG layout $template; run scripts/generate-dmg-layout.sh on a Mac with a logged-in desktop." >&2
        exit 1
    fi
    args+=(--skip-jenkins --add-file .DS_Store "$template" 0 0)
fi

create-dmg "${args[@]}" "$output" "$app"
