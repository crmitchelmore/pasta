#!/bin/bash
# Playwright downloads its own Chromium; the hosted image's Google Chrome apt
# feed is unrelated and can break apt update while its CDN metadata is syncing.
set -euo pipefail
if [ "$(uname -s)" = Linux ]; then
  sudo python3 - <<'PY'
from pathlib import Path
import re

chrome = re.compile(r'https?://dl\.google\.com/linux/chrome(?:-stable)?/deb')
for path in Path('/etc/apt/sources.list.d').iterdir():
    if path.suffix not in ('.list', '.sources'):
        continue
    original = path.read_text()
    if not chrome.search(original):
        continue
    if path.suffix == '.list':
        updated = ''.join('# Disabled for Playwright: ' + line if chrome.search(line) and not line.lstrip().startswith('#') else line for line in original.splitlines(keepends=True))
    else:
        blocks = re.split(r'(\n\s*\n)', original)
        for index, block in enumerate(blocks):
            if chrome.search(block):
                uris = re.findall(r'https?://\S+', block)
                if any(not chrome.match(uri) for uri in uris):
                    raise SystemExit('Unexpected mixed repository stanza: ' + str(path))
                block = re.sub(r'^Enabled:.*\n?', '', block, flags=re.MULTILINE)
                blocks[index] = block.rstrip('\n') + '\nEnabled: no\n'
        updated = ''.join(blocks)
    path.write_text(updated)
    print('Excluded unused Chrome apt feed from', path.name)
PY
fi
exec npx playwright install --with-deps chromium
