import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("locks", ROOT / "scripts/ci-verify-dependency-locks.py")
locks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(locks)


class DependencyLocksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = json.loads((ROOT / "Package.resolved").read_text())
        self.write("Package.resolved", self.data)
        self.write(locks.IOS_LOCK, self.data)

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))

    def test_equal_reviewed_pins_pass(self):
        self.assertEqual(len(locks.verify(self.root)), 3)

    def test_schema_or_order_change_does_not_change_pins(self):
        self.data["version"] = 3
        self.data["originHash"] = "toolchain-owned"
        self.data["pins"].reverse()
        self.write(locks.IOS_LOCK, self.data)
        locks.verify(self.root)

    def test_different_version_revision_url_or_missing_pin_fails(self):
        mutations = [
            lambda d: d["pins"][0]["state"].update(version="6.29.4"),
            lambda d: d["pins"][0]["state"].update(revision="f" * 40),
            lambda d: d["pins"][0].update(location="https://example.invalid/replacement.git"),
            lambda d: d["pins"].pop(),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                data = json.loads(json.dumps(self.data))
                mutate(data)
                self.write(locks.IOS_LOCK, data)
                with self.assertRaisesRegex(ValueError, "pins differ"):
                    locks.verify(self.root)

    def test_missing_corrupt_empty_or_duplicate_lock_fails(self):
        path = self.root / locks.IOS_LOCK
        path.unlink()
        with self.assertRaises(OSError):
            locks.verify(self.root)
        path.write_text("not json")
        with self.assertRaises(ValueError):
            locks.verify(self.root)
        self.write(locks.IOS_LOCK, {"version": 2, "pins": []})
        with self.assertRaises(ValueError):
            locks.verify(self.root)
        self.data["pins"].append(self.data["pins"][0])
        self.write(locks.IOS_LOCK, self.data)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            locks.verify(self.root)

    def test_branch_or_unpinned_revision_fails(self):
        for state in ({"branch": "main", "revision": "a" * 40},
                      {"version": "6.29.3", "revision": "main"}):
            self.data["pins"][0]["state"] = state
            self.write(locks.IOS_LOCK, self.data)
            with self.assertRaises(ValueError):
                locks.verify(self.root)


if __name__ == "__main__":
    unittest.main()
