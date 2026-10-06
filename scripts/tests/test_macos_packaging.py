import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("resources", ROOT / "scripts/ci-stage-macos-resources.py")
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)


class ResourcePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / "release"
        self.app = self.root / "Pasta Alpha.app"
        for bundle, files in {
            "Pasta_PastaApp.bundle": {
                "AppIcon.png": b"stable pixels",
                "AppIconAlpha.png": b"alpha pixels",
                "Assets.xcassets/AppIcon.appiconset/icon.png": b"source artwork",
                "Info.plist": b"bundle metadata",
                "FutureResource.json": b"runtime resource",
            },
            "Pasta_PastaCore.bundle": {"ReleaseTrains.json": b"trains", "ReleaseNotes.md": b"notes"},
            "ThirdParty.bundle": {"PrivacyInfo.xcprivacy": b"privacy manifest"},
        }.items():
            for name, data in files.items():
                path = self.build / bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)

    def test_each_train_keeps_exact_artwork_notes_and_other_runtime_resources(self):
        for train in ("AppIcon", "AppIconAlpha"):
            with self.subTest(train=train):
                icon = self.root / f"{train}.icns"
                icon.write_bytes(b"full resolution icon " + train.encode())
                resources.stage_resources(self.build, self.app, icon)
                output = self.app / "Contents/Resources"
                bundle = output / "Pasta_PastaApp.bundle"
                self.assertEqual((output / "AppIcon.icns").read_bytes(), icon.read_bytes())
                self.assertEqual((bundle / "AppIcon.png").read_bytes(),
                                 (self.build / "Pasta_PastaApp.bundle" / f"{train}.png").read_bytes())
                self.assertFalse((bundle / "AppIconAlpha.png").exists())
                self.assertFalse((bundle / "Assets.xcassets").exists())
                self.assertFalse((output / "AppIcon.png").exists())
                for name in ("Info.plist", "FutureResource.json"):
                    self.assertEqual((bundle / name).read_bytes(),
                                     (self.build / "Pasta_PastaApp.bundle" / name).read_bytes())
                for name in ("ReleaseTrains.json", "ReleaseNotes.md"):
                    self.assertEqual((output / "Pasta_PastaCore.bundle" / name).read_bytes(),
                                     (self.build / "Pasta_PastaCore.bundle" / name).read_bytes())
                self.assertEqual((output / "ThirdParty.bundle/PrivacyInfo.xcprivacy").read_bytes(),
                                 b"privacy manifest")
                self.assertTrue((self.build / "Pasta_PastaApp.bundle/Assets.xcassets").exists())

    def test_missing_bundle_or_artwork_fails(self):
        with self.assertRaisesRegex(ValueError, "Missing app icon"):
            resources.stage_resources(self.build, self.app, self.root / "missing.icns")
        (self.build / "Pasta_PastaCore.bundle").rename(self.build / "missing-core")
        with self.assertRaisesRegex(ValueError, "Missing required"):
            resources.stage_resources(self.build, self.app, self.root / "missing.icns")

    def test_missing_selected_fallback_fails(self):
        icon = self.root / "AppIconAlpha.icns"
        icon.write_bytes(b"icon")
        (self.build / "Pasta_PastaApp.bundle/AppIconAlpha.png").unlink()
        with self.assertRaises(FileNotFoundError):
            resources.stage_resources(self.build, self.app, icon)


class PackagingCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        COMMAND_LOG=str(self.log))
        self.binary = self.root / "Pasta App"
        self.binary.write_bytes(b"binary")
        for tool in ("dsymutil", "ditto", "strip", "create-dmg", "xcrun"):
            path = self.bin / tool
            path.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(tool + ' ' + repr(sys.argv[1:]) + '\\n')
if os.environ.get('FAIL_TOOL') == tool:
    sys.exit(1)
if tool == 'dsymutil':
    pathlib.Path(sys.argv[-1]).mkdir(exist_ok=True)
if tool == 'ditto':
    pathlib.Path(sys.argv[-1]).write_bytes(b'symbol archive')
if tool == 'xcrun':
    print('UUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE (arm64)')
""")
            path.chmod(0o755)

    def run_script(self, name, *args, **env):
        return subprocess.run(["bash", str(ROOT / "scripts" / name), *map(str, args)],
                              env={**self.env, **env}, capture_output=True, text=True)

    def test_strip_preserves_dynamic_symbols_and_verifies_dsym_before_and_after(self):
        result = self.run_script("ci-prepare-macos-executable.sh", self.binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text().splitlines()
        self.assertEqual([line.split()[0] for line in commands],
                         ["dsymutil", "xcrun", "xcrun", "ditto", "strip", "xcrun", "xcrun"])
        self.assertIn("['-u', '-r',", commands[4])

    def test_symbol_capture_or_verification_failure_prevents_stripping(self):
        for tool in ("dsymutil", "xcrun", "ditto"):
            with self.subTest(tool=tool):
                self.log.unlink(missing_ok=True)
                result = self.run_script("ci-prepare-macos-executable.sh", self.binary, FAIL_TOOL=tool)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("strip ", self.log.read_text())

    def test_strip_failure_is_not_ignored(self):
        result = self.run_script("ci-prepare-macos-executable.sh", self.binary, FAIL_TOOL="strip")
        self.assertNotEqual(result.returncode, 0)

    def test_dmg_uses_lossless_lzma_and_preserves_layout_arguments(self):
        result = self.run_script("ci-create-macos-dmg.sh", "--volname", "Pasta Alpha",
                                 "--background", "background.png", "output.dmg", "Pasta Alpha.app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("['--format', 'ULMO', '--volname', 'Pasta Alpha', '--background', "
                      "'background.png', 'output.dmg', 'Pasta Alpha.app']", self.log.read_text())


if __name__ == "__main__":
    unittest.main()
