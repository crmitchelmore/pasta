#!/bin/bash
# Build the committed, size-optimised ICNS for both trains from their appiconsets.
# Release jobs ship the committed files; rerun this only when the artwork changes.
# iconutil re-encodes every slot with light PNG compression, so optimize-artwork.py
# then shrinks each slot in place (see Resources/Branding/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CATALOG="$REPO_ROOT/Sources/PastaApp/Resources/Assets.xcassets"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

for TRAIN in AppIcon AppIconAlpha; do
    ICONSET_DIR="$WORK_DIR/$TRAIN.iconset"
    mkdir -p "$ICONSET_DIR"
    for SIZE in 16 32 128 256 512; do
        cp "$CATALOG/$TRAIN.appiconset/icon_${SIZE}x${SIZE}.png" "$ICONSET_DIR/"
        cp "$CATALOG/$TRAIN.appiconset/icon_${SIZE}x${SIZE}@2x.png" "$ICONSET_DIR/"
    done
    echo "==> Converting $TRAIN.iconset to icns..."
    iconutil -c icns "$ICONSET_DIR" -o "$SCRIPT_DIR/$TRAIN.icns"
done

"${PYTHON:-python3}" "$REPO_ROOT/scripts/optimize-artwork.py" "$SCRIPT_DIR/AppIcon.icns" "$SCRIPT_DIR/AppIconAlpha.icns"
ls -la "$SCRIPT_DIR"/AppIcon*.icns
