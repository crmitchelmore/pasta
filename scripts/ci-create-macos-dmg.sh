#!/bin/bash
set -euo pipefail

# LZMA is lossless and supported since macOS 10.15 (Pasta requires macOS 14).
exec create-dmg --format ULMO "$@"
