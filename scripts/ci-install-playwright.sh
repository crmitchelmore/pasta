#!/bin/bash
# Playwright downloads its own Chromium; the hosted image's Google Chrome apt
# feed is unrelated and can break apt update while its CDN metadata is syncing.
set -euo pipefail
if [ "$(uname -s)" = Linux ]; then
  source=/etc/apt/sources.list.d/google-chrome.list
  if [ -f "$source" ] && grep -q 'dl.google.com/linux/chrome' "$source"; then
    sudo mv -f "$source" "${source}.disabled-for-playwright"
  fi
fi
exec npx playwright install --with-deps chromium
