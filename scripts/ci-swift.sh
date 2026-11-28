#!/bin/bash
set -euo pipefail

# Keep products and pinned binary artifacts in one known, runner-approved root.
if [ -n "${STORAGE_GUARD_BUILD_DIR:-}" ]; then
    scratch="$STORAGE_GUARD_BUILD_DIR/swiftpm"
else
    scratch="$PWD/.build"
fi
previous=""
for argument in "$@"; do
    if [ "$previous" = "--arch" ]; then
        case "$argument" in
            arm64|x86_64) scratch="$scratch/$argument" ;;
            *) echo "Unsupported macOS architecture: $argument" >&2; exit 2 ;;
        esac
    fi
    previous="$argument"
done
if [ "$previous" = "--arch" ]; then
    echo "--arch requires an architecture" >&2
    exit 2
fi

if [ "${1:-}" = "artifacts" ]; then
    printf '%s/artifacts\n' "$scratch"
    exit 0
fi
case "${1:-}" in
    build|test|package) ;;
    *) echo "Usage: $0 build|test|package <arguments> | artifacts" >&2; exit 2 ;;
esac

exec swift "$@" --scratch-path "$scratch" \
    --cache-path "${RUNNER_TEMP:?RUNNER_TEMP must be set}/swiftpm-cache" \
    --force-resolved-versions
