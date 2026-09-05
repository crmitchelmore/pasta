#!/bin/bash
# Run inside the tap checkout after writing Casks/pasta.rb. Safe to retry when
# the previous run pushed successfully but a later release step failed.
set -euo pipefail
VERSION="${1:?usage: ci-commit-homebrew.sh <version>}"
git add -- Casks/pasta.rb
if git diff --cached --quiet -- Casks/pasta.rb; then
  echo "Homebrew tap already matches v$VERSION; nothing to publish"
  exit 0
fi
git commit -m "Update Pasta to v$VERSION"
git push
