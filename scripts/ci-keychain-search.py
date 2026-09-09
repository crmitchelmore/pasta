#!/usr/bin/env python3
"""Preserve the user's keychain search list around a release job."""
import json
import pathlib
import shlex
import subprocess
import sys

mode, snapshot, *extra = sys.argv[1:]
path = pathlib.Path(snapshot)
if mode == 'add':
    original = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
    if path.exists():
        raise SystemExit('Keychain snapshot already exists; refusing to overwrite')
    path.write_text(json.dumps(original))
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', extra[0], *original], check=True)
elif mode == 'restore':
    if path.exists():
        subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *json.loads(path.read_text())], check=True)
        path.unlink()
else:
    raise SystemExit('Expected add or restore')
