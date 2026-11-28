#!/usr/bin/env python3
"""Stamp a controlled archive checkout from its frozen release manifest."""
import json
import os
import plistlib
import re
from pathlib import Path

train = os.environ['RELEASE_TRAIN']
config = json.loads(Path('Sources/PastaCore/Resources/ReleaseTrains.json').read_text())[train]
version, build = os.environ['RELEASE_VERSION'], os.environ['BUILD_NUMBER']
assert re.fullmatch(r'\d+\.\d+\.\d+', version) and re.fullmatch(r'\d+', build)
# iOS Alpha is a TestFlight build of the main app record (App Review Guideline
# 4.3(a)): it keeps the App Store bundle, profile and Production container.
for filename, container in [('Resources/release.entitlements', config['cloudContainer']),
                            ('PastaIOS/PastaIOS/PastaIOS.entitlements', config['iosCloudContainer'])]:
    path = Path(filename)
    value = plistlib.loads(path.read_bytes())
    value['com.apple.developer.icloud-container-identifiers'] = [container]
    if 'com.apple.application-identifier' in value:
        value['com.apple.application-identifier'] = '8X4ZN58TYH.' + config['macBundleIdentifier']
    path.write_bytes(plistlib.dumps(value))
path = Path('PastaIOS/PastaIOS/Info.plist')
value = plistlib.loads(path.read_bytes())
value.update(PastaReleaseTrain=train, GitCommitSHA=os.environ['RELEASE_SOURCE'])
path.write_bytes(plistlib.dumps(value))
path = Path('PastaIOS/PastaIOS.xcodeproj/project.pbxproj')
s = path.read_text()
s = s.replace('PRODUCT_BUNDLE_IDENTIFIER = com.pasta.ios;', f'PRODUCT_BUNDLE_IDENTIFIER = {config["iosBundleIdentifier"]};')
s = s.replace('INFOPLIST_KEY_CFBundleDisplayName = Pasta;', f'INFOPLIST_KEY_CFBundleDisplayName = "{config["displayName"]}";')
if train == 'alpha':
    s = s.replace('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;', 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIconAlpha;')
# Version settings are app/UITest project settings, never global SwiftPM flags.
s = re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {version};', s)
s = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {build};', s)
path.write_text(s)
