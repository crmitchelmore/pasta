import ast
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("resources", ROOT / "scripts/ci-stage-macos-resources.py")
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)
slim_spec = importlib.util.spec_from_file_location("slim_icns", ROOT / "scripts/ci-slim-icns.py")
slim = importlib.util.module_from_spec(slim_spec)
slim_spec.loader.exec_module(slim)


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
                self.assertFalse((bundle / "AppIcon.png").exists())
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

    def test_development_png_fallbacks_are_not_required(self):
        icon = self.root / "AppIconAlpha.icns"
        icon.write_bytes(b"icon")
        for name in ("AppIcon.png", "AppIconAlpha.png"):
            (self.build / "Pasta_PastaApp.bundle" / name).unlink()
        resources.stage_resources(self.build, self.app, icon)
        self.assertEqual((self.app / "Contents/Resources/AppIcon.icns").read_bytes(), b"icon")


def sample_icns(*kinds):
    return slim.build_icns([(kind, kind.encode() * 3) for kind in kinds])


class VolumeIconTests(unittest.TestCase):
    def test_slim_drops_only_the_1024_slot_and_keeps_order(self):
        source = sample_icns("ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10", "ic11", "info")
        slimmed = slim.slim_icns(source)
        self.assertEqual([kind for kind, _ in slim.parse_icns(slimmed)],
                         ["ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic11", "info"])
        self.assertEqual(slim.parse_icns(slimmed),
                         [entry for entry in slim.parse_icns(source) if entry[0] != "ic10"])
        self.assertEqual(int.from_bytes(slimmed[4:8], "big"), len(slimmed))

    def test_malformed_or_already_slim_icns_fails(self):
        source = sample_icns("ic09", "ic10")
        for data in (b"PNG" + source[3:], source[:-1], source + b"x", sample_icns("ic09")):
            with self.subTest(data=data[:12]):
                with self.assertRaises(ValueError):
                    slim.slim_icns(data)

    def test_committed_train_icons_keep_every_slot(self):
        for name in ("AppIcon.icns", "AppIconAlpha.icns"):
            with self.subTest(name=name):
                kinds = {kind for kind, _ in slim.parse_icns((ROOT / "Resources/DMG" / name).read_bytes())}
                self.assertTrue({"ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"} <= kinds)

    def test_dmg_background_is_exact_pixel_size_without_density_override(self):
        data = (ROOT / "Resources/DMG/background@2x.png").read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(data[12:16], b"IHDR")
        self.assertEqual((int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")), (1320, 800))
        self.assertNotIn(b"pHYs", data)
        self.assertFalse((ROOT / "Resources/DMG/background.png").exists())


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

    def make_dmg_resources(self, *volume_names):
        resources = self.root / "DMG"
        (resources / "Layout").mkdir(parents=True)
        for name in volume_names:
            (resources / "Layout" / f"{name}.DS_Store").write_bytes(b"layout " + name.encode())
        icon = self.root / "App Icon.icns"
        icon.write_bytes(sample_icns("ic09", "ic10", "ic11"))
        return resources, icon

    def logged_create_dmg_args(self):
        line = self.log.read_text().splitlines()[-1]
        self.assertTrue(line.startswith("create-dmg "), line)
        return ast.literal_eval(line[len("create-dmg "):])

    def test_dmg_applies_committed_layout_without_scripting_finder(self):
        resources, icon = self.make_dmg_resources("Pasta Alpha")
        create_dmg = self.bin / "create-dmg"
        create_dmg.write_text(create_dmg.read_text() + """
args = sys.argv[1:]
volicon = pathlib.Path(args[args.index('--volicon') + 1])
pathlib.Path(os.environ['COMMAND_LOG'] + '.icns').write_bytes(volicon.read_bytes())
""")
        result = self.run_script("ci-create-macos-dmg.sh", "Pasta Alpha", icon, "output.dmg",
                                 "build/Pasta Alpha.app", PASTA_DMG_RESOURCES=str(resources))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.logged_create_dmg_args()
        self.assertEqual(args[:4], ["--format", "ULMO", "--volname", "Pasta Alpha"])
        self.assertEqual(args[args.index("--icon") + 1], "Pasta Alpha.app")
        self.assertIn("--skip-jenkins", args)
        add = args.index("--add-file")
        self.assertEqual(args[add + 1:add + 3], [".DS_Store", str(resources / "Layout/Pasta Alpha.DS_Store")])
        self.assertEqual(args[-2:], ["output.dmg", "build/Pasta Alpha.app"])
        self.assertNotIn(str(icon), args)
        self.assertEqual(Path(str(self.log) + ".icns").read_bytes(), sample_icns("ic09", "ic11"))
        self.assertEqual(icon.read_bytes(), sample_icns("ic09", "ic10", "ic11"))

    def test_finder_layout_mode_lets_finder_write_the_layout(self):
        resources, icon = self.make_dmg_resources()
        result = self.run_script("ci-create-macos-dmg.sh", "--finder-layout", "Pasta", icon, "output.dmg",
                                 "Pasta.app", PASTA_DMG_RESOURCES=str(resources))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.logged_create_dmg_args()
        self.assertNotIn("--skip-jenkins", args)
        self.assertNotIn("--add-file", args)

    def test_dmg_fails_without_a_layout_for_the_volume_name(self):
        resources, icon = self.make_dmg_resources("Pasta")
        result = self.run_script("ci-create-macos-dmg.sh", "Pasta Beta", icon, "output.dmg", "Pasta Beta.app",
                                 PASTA_DMG_RESOURCES=str(resources))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generate-dmg-layout.sh", result.stderr)
        self.assertFalse(self.log.exists())

    def test_dmg_fails_when_volume_icon_cannot_be_slimmed(self):
        resources, _ = self.make_dmg_resources("Pasta")
        icon = self.root / "broken.icns"
        icon.write_bytes(b"not an icon")
        result = self.run_script("ci-create-macos-dmg.sh", "Pasta", icon, "output.dmg", "Pasta.app",
                                 PASTA_DMG_RESOURCES=str(resources))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


class DMGLayoutTemplateTests(unittest.TestCase):
    def test_every_train_has_a_layout_pointing_at_its_own_volume_background(self):
        trains = json.loads((ROOT / "Sources/PastaCore/Resources/ReleaseTrains.json").read_text())
        names = {train["displayName"] for train in (trains.values() if isinstance(trains, dict) else trains)}
        layouts = {path.stem for path in (ROOT / "Resources/DMG/Layout").glob("*.DS_Store")}
        self.assertEqual(layouts, names)
        for name in names:
            with self.subTest(name=name):
                data = (ROOT / "Resources/DMG/Layout" / f"{name}.DS_Store").read_bytes()
                self.assertEqual(data[4:8], b"Bud1")
                self.assertIn(f"{name}:.background:".encode(), data)
                self.assertIn(b"/.background/background@2x.png", data)
                self.assertIn(f"{name}.app".encode("utf-16-be"), data)
                self.assertIn("Applications".encode("utf-16-be"), data)

if __name__ == "__main__":
    unittest.main()
