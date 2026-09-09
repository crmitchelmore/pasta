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
    def test_alpha_stamps_own_bundle_profile_and_cloud_without_changing_stable_source(self):
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
            for name in files[1:3]:
                entitlements = plistlib.loads((root/name).read_bytes())
                self.assertEqual(entitlements['com.apple.developer.icloud-container-identifiers'], ['iCloud.com.pasta.ios.alpha'])
            project = (root/files[-1]).read_text()
            self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = com.pasta.ios.alpha;', project)
            self.assertIn('Pasta Alpha iOS AppStore CI', project)
            self.assertNotIn('PRODUCT_BUNDLE_IDENTIFIER = com.pasta.ios;', project)
            for name in files:
                self.assertEqual((ROOT/name).read_bytes(), original[name])

if __name__ == '__main__': unittest.main()
