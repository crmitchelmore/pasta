#!/usr/bin/env python3
"""Reject missing, invalid or divergent application dependency pins.

Native SwiftPM/Xcode resolution remains the authority for graph validity;
this check ensures both entrypoints receive the same reviewed lock.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
IOS_LOCK = "PastaIOS/PastaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def read_pins(path):
    data = json.loads(path.read_text())
    if data.get("version") not in (2, 3) or not data.get("pins"):
        raise ValueError(f"{path}: missing pins or unsupported lock schema")
    pins = {}
    for pin in data["pins"]:
        identity = pin["identity"]
        state = pin["state"]
        if identity in pins or pin["kind"] != "remoteSourceControl":
            raise ValueError(f"{path}: duplicate or unsupported pin {identity}")
        if not re.fullmatch(r"[0-9a-f]{40}", state.get("revision", "")):
            raise ValueError(f"{path}: {identity} requires an exact commit revision")
        if not re.fullmatch(r"\d+\.\d+\.\d+", state.get("version", "")) or "branch" in state:
            raise ValueError(f"{path}: {identity} requires a release version")
        pins[identity] = (pin["kind"], pin["location"], state)
    return pins


def verify(root=ROOT):
    package = read_pins(root / "Package.resolved")
    xcode = read_pins(root / IOS_LOCK)
    if package != xcode:
        raise ValueError("SwiftPM and Xcode dependency pins differ; run "
                         "`python3 scripts/ci-verify-dependency-locks.py --sync`, then validate the iOS "
                         "lock with `scripts/ci-ios-e2e.sh resolve` and commit both locks together")
    return package


def sync(root=ROOT):
    """Copy the reviewed SwiftPM pins (e.g. a Dependabot update) to the iOS lock."""
    read_pins(root / "Package.resolved")
    package = json.loads((root / "Package.resolved").read_text())
    target = root / IOS_LOCK
    xcode = json.loads(target.read_text())
    xcode["pins"] = package["pins"]
    target.write_text(json.dumps(xcode, indent=2) + "\n")


if __name__ == "__main__":
    try:
        if "--sync" in sys.argv[1:]:
            sync()
        pins = verify()
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"::error::Dependency lock verification failed: {error}") from error
    for identity, (_, _, state) in sorted(pins.items()):
        print(f"{identity}: {state['version']} ({state['revision']})")
