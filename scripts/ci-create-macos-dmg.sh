#!/bin/bash
set -euo pipefail

# LZMA is lossless and supported since macOS 10.15 (Pasta requires macOS 14).
# --volicon receives the app's ICNS; the volume icon ships without the 1024 px slot.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

args=()
while (($#)); do
    if [[ "$1" == "--volicon" && $# -ge 2 ]]; then
        python3 "$SCRIPT_DIR/ci-slim-icns.py" "$2" "$WORK_DIR/VolumeIcon.icns"
        args+=("--volicon" "$WORK_DIR/VolumeIcon.icns")
        shift 2
    else
        args+=("$1")
        shift
    fi
done

create-dmg --format ULMO ${args[@]+"${args[@]}"}
