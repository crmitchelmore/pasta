import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "scripts/ci-swift.sh"


class SwiftBuildPathTests(unittest.TestCase):
    def test_native_runner_override_preserves_untrusted_pr_routing(self):
        workflows = ROOT / ".github/workflows"
        ci = (workflows / "ci.yml").read_text()
        trusted = "(github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)"
        route = f"{trusted} && (vars.PASTA_NATIVE_RUNNER || 'pasta-local') || 'macos-15'"
        self.assertEqual(ci.count(route), 2)
        for name in ("release.yml", "release-ios.yml"):
            self.assertIn("runs-on: ${{ vars.PASTA_NATIVE_RUNNER || 'pasta-local' }}",
                          (workflows / name).read_text())

    def test_commands_preserve_pins_cache_architecture_and_guarded_scratch(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            swift = root / "swift"
            swift.write_text("#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
            swift.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       RUNNER_TEMP=str(root / "runner temp"),
                       STORAGE_GUARD_BUILD_DIR=str(root / "guarded build"))
            for arguments in (["package", "resolve"], ["test", "--parallel"],
                              ["build", "-c", "release", "--arch", "x86_64", "--show-bin-path"]):
                result = subprocess.run(["bash", str(DRIVER), *arguments], cwd=root,
                                        env=env, text=True, capture_output=True, check=True)
                self.assertEqual(json.loads(result.stdout), arguments + [
                    "--scratch-path", str(root / ("guarded build/swiftpm/x86_64"
                                                 if "--arch" in arguments else "guarded build/swiftpm")),
                    "--cache-path", str(root / "runner temp/swiftpm-cache"),
                    "--force-resolved-versions"])
            result = subprocess.run(["bash", str(DRIVER), "artifacts"], cwd=root,
                                    env=env, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), str(root / "guarded build/swiftpm/artifacts"))
            for architecture in ("arm64", "x86_64"):
                result = subprocess.run(["bash", str(DRIVER), "artifacts", "--arch", architecture],
                                        cwd=root, env=env, text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.strip(),
                                 str(root / f"guarded build/swiftpm/{architecture}/artifacts"))
            del env["STORAGE_GUARD_BUILD_DIR"]
            result = subprocess.run(["bash", str(DRIVER), "artifacts"], cwd=root,
                                    env=env, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), str(root / ".build/artifacts"))

    def test_unknown_command_fails_instead_of_invoking_swift(self):
        result = subprocess.run(["bash", str(DRIVER), "unexpected"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)

    def test_configured_missing_signing_tool_does_not_download_a_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            dmg = Path(folder) / "sample.dmg"
            dmg.write_bytes(b"sample")
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/generate-appcast.sh"), "1.11.0", "123", str(dmg), "test-key"],
                env=dict(os.environ, SPARKLE_SIGN_UPDATE=str(Path(folder) / "missing-sign-update")),
                text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("configured Sparkle sign_update is missing", result.stderr)
            self.assertNotIn("downloading", result.stderr)

    def test_downloaded_signing_tool_must_match_pinned_checksum(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            dmg = folder / "sample.dmg"
            dmg.write_bytes(b"sample")
            bin_dir = folder / "bin"
            bin_dir.mkdir()
            fake_curl = bin_dir / "curl"
            fake_curl.write_text('#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { printf tampered > "$2"; shift; }; shift; done\n')
            fake_curl.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if k != "SPARKLE_SIGN_UPDATE"}
            env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/generate-appcast.sh"), "1.11.0", "123", str(dmg), "test-key"],
                cwd=folder, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum mismatch", result.stderr)
            self.assertNotIn("Running sign_update", result.stderr)
