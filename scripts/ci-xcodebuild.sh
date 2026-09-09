#!/bin/bash
# A permanent runner must not depend on personal caches on removable storage.
set -euo pipefail
if [ -n "${RUNNER_TEMP:-}" ]; then
  exec xcodebuild -packageCachePath "$RUNNER_TEMP/xcode-package-cache" "$@"
fi
exec xcodebuild "$@"
