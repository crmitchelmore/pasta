import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ReleaseStampingTests(unittest.TestCase):
    def test_alpha_isolates_mac_cloud_but_ships_ios_as_the_main_app_without_changing_stable_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = ['Sources/PastaCore/Resources/ReleaseTrains.json', 'Resources/release.entitlements',
                     'PastaIOS/PastaIOS/PastaIOS.entitlements', 'PastaIOS/PastaIOS/Info.plist',
                     'PastaIOS/PastaIOS.xcodeproj/project.pbxproj']
            original = {name: (ROOT / name).read_bytes() for name in files}
            for name in files:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(original[name])
            env = dict(os.environ, RELEASE_TRAIN='alpha', RELEASE_VERSION='1.9.0', BUILD_NUMBER='1001', RELEASE_SOURCE='a'*40)
            subprocess.run(['python3', str(ROOT/'scripts/configure-release-train.py')], cwd=root, env=env, check=True)
            containers = {name: plistlib.loads((root/name).read_bytes())['com.apple.developer.icloud-container-identifiers']
                          for name in files[1:3]}
            self.assertEqual(containers, {'Resources/release.entitlements': ['iCloud.com.pasta.ios.alpha'],
                                          'PastaIOS/PastaIOS/PastaIOS.entitlements': ['iCloud.com.pasta.ios']})
            info = plistlib.loads((root/'PastaIOS/PastaIOS/Info.plist').read_bytes())
            self.assertEqual(info['PastaReleaseTrain'], 'alpha')
            project = (root/files[-1]).read_text()
            # One App Store Connect record (Guideline 4.3(a)): main bundle and profile.
            self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.pasta.ios;', project)
            self.assertNotIn('com.pasta.ios.alpha', project)
            self.assertIn('PROVISIONING_PROFILE_SPECIFIER = "PastaIOS AppStore CI";', project)
            self.assertNotIn('Pasta Alpha iOS AppStore CI', project)
            self.assertIn('ASSETCATALOG_COMPILER_APPICON_NAME = AppIconAlpha;', project)
            self.assertIn('INFOPLIST_KEY_CFBundleDisplayName = "Pasta Alpha";', project)
            for name in files:
                self.assertEqual((ROOT/name).read_bytes(), original[name])

if __name__ == '__main__': unittest.main()
