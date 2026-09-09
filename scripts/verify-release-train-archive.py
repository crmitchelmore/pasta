#!/usr/bin/env python3
"""Inspect actual signed archive identity, isolated cloud and frozen notes."""
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path
app, manifest_path, surface = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
m = json.loads(manifest_path.read_text())
c = json.loads(Path('Sources/PastaCore/Resources/ReleaseTrains.json').read_text())[m['train']]
i = m['surfaces'][surface]
info = plistlib.loads((app / ('Contents/Info.plist' if surface == 'mac-direct' else 'Info.plist')).read_bytes())
for key, value in {'CFBundleIdentifier':c['macBundleIdentifier' if surface == 'mac-direct' else 'iosBundleIdentifier'],
                   'PastaReleaseTrain':m['train'], 'GitCommitSHA':m['source'],
                   'CFBundleShortVersionString':i['version'],'CFBundleVersion':i['build']}.items():
    if info.get(key) != value: raise SystemExit(f'Archive {key} mismatch')
if surface == 'mac-direct' and info.get('SUFeedURL') != c['feedURL']: raise SystemExit('Wrong Sparkle feed')
e = plistlib.loads(subprocess.run(['codesign','-d','--entitlements',':-',str(app)],check=True,capture_output=True).stdout)
if e.get('com.apple.developer.icloud-container-identifiers') != [c['cloudContainer']]: raise SystemExit('Cloud identity mismatch')
if e.get('com.apple.developer.icloud-container-environment') != 'Production': raise SystemExit('Cloud environment mismatch')
paths = list(app.rglob('IOSReleaseNotes.json'))
if not paths: raise SystemExit('Missing frozen release notes')
for path in paths:
    entries=json.loads(path.read_text())['entries']
    entry=next((x for x in entries if x.get('train','stable')==m['train'] and x.get('build')==i['build'] and x['version']==i['version']),None)
    if not entry or hashlib.sha256(entry.get('markdown','').encode()).hexdigest()!=i['notesHash']: raise SystemExit('Frozen notes mismatch')
print(f"Verified {surface} {m['train']} archive identity, cloud and notes")
