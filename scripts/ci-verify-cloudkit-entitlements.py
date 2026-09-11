#!/usr/bin/env python3
"""Fail closed unless extracted signed entitlements target Pasta's shared cloud.

Usage: python3 scripts/ci-verify-cloudkit-entitlements.py ENTITLEMENTS.plist
The caller must extract this plist from the signed app with codesign; a source
entitlements file or provisioning profile does not prove the shipped signature.
"""

from pathlib import Path
import plistlib
import os
import sys
from xml.parsers.expat import ExpatError


CONTAINER = os.environ.get("ICLOUD_CONTAINER", "iCloud.com.pasta.ios")
SERVICES_KEY = "com.apple.developer.icloud-services"
CONTAINERS_KEY = "com.apple.developer.icloud-container-identifiers"
ENVIRONMENT_KEY = "com.apple.developer.icloud-container-environment"


class EntitlementError(ValueError):
    pass


def verify(entitlements):
    if not isinstance(entitlements, dict):
        raise EntitlementError("signed entitlements must be a plist dictionary")
    services = entitlements.get(SERVICES_KEY)
    if not isinstance(services, list) or "CloudKit" not in services:
        raise EntitlementError("signed app does not grant the CloudKit service")
    containers = entitlements.get(CONTAINERS_KEY)
    if not isinstance(containers, list) or containers != [CONTAINER]:
        raise EntitlementError(f"signed app does not grant the shared {CONTAINER} container")
    if entitlements.get(ENVIRONMENT_KEY) != "Production":
        raise EntitlementError("signed app must use the Production CloudKit environment")


def main(argv):
    if len(argv) != 2:
        print("usage: ci-verify-cloudkit-entitlements.py ENTITLEMENTS.plist", file=sys.stderr)
        return 2
    try:
        entitlements = plistlib.loads(Path(argv[1]).read_bytes())
        verify(entitlements)
    except EntitlementError as error:
        print(f"::error::CloudKit release gate: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, OverflowError, ExpatError, plistlib.InvalidFileException):
        # Never dump the signed plist or arbitrary parser output into CI logs.
        print("::error::CloudKit release gate: cannot read a valid signed entitlement plist", file=sys.stderr)
        return 1
    print(f"Verified signed CloudKit access: {CONTAINER}, Production")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
