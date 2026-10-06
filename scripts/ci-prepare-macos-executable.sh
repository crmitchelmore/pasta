#!/bin/bash
# Retain crash symbols before removing executable symbols not needed by dyld.
set -euo pipefail

BINARY="${1:?Usage: ci-prepare-macos-executable.sh <PastaApp>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DSYM="${BINARY}.dSYM"

dsymutil "$BINARY" -o "$DSYM"
python3 "$SCRIPT_DIR/ci-verify-symbols.py" "$BINARY" "$DSYM"
ditto -c -k --keepParent "$DSYM" "${DSYM}.zip"

# Keep imports and dynamically referenced exports. Swift reflection and ObjC
# runtime metadata live in Mach-O sections, not the stripped symbol table.
strip -u -r "$BINARY"
python3 "$SCRIPT_DIR/ci-verify-symbols.py" "$BINARY" "$DSYM"
echo "==> Prepared release executable (matching dSYM retained)"
ls -lh "$BINARY" "${DSYM}.zip"
