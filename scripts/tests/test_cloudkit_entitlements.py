"""Exercise the signed-cloud gate with the plist bytes its callers extract."""

from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ci-verify-cloudkit-entitlements.py"
SERVICE = "com.apple.developer.icloud-services"
CONTAINERS = "com.apple.developer.icloud-container-identifiers"
ENVIRONMENT = "com.apple.developer.icloud-container-environment"


class CloudKitEntitlementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pasta-cloudkit-entitlements-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "signed-entitlements.plist"
        self.valid = {
            SERVICE: ["CloudKit"],
            CONTAINERS: ["iCloud.com.pasta.ios"],
            ENVIRONMENT: "Production",
        }

    def run_gate(self, value, *, success, fmt=plistlib.FMT_XML):
        self.path.write_bytes(plistlib.dumps(value, fmt=fmt))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.path)],
            capture_output=True, text=True, timeout=10,
        )
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("iCloud.com.pasta.ios, Production", output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("::error::CloudKit release gate:", output)
        return output

    def test_valid_xml_and_binary_signed_entitlements_pass(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=fmt):
                self.run_gate(self.valid, success=True, fmt=fmt)

    def test_each_missing_cloud_entitlement_fails(self):
        for key in self.valid:
            with self.subTest(missing=key):
                self.run_gate({k: v for k, v in self.valid.items() if k != key}, success=False)

    def test_development_environment_cannot_publish_as_production(self):
        output = self.run_gate({**self.valid, ENVIRONMENT: "Development"}, success=False)
        self.assertIn("must use the Production CloudKit environment", output)

    def test_other_container_or_icloud_service_does_not_authorize_pasta_sync(self):
        for key, value in (
            (CONTAINERS, ["iCloud.com.pasta.clipboard"]),
            (SERVICE, ["CloudDocuments"]),
            (SERVICE, "CloudKit"),
            (CONTAINERS, "iCloud.com.pasta.ios"),
            (ENVIRONMENT, ["Production"]),
            (ENVIRONMENT, "production"),
        ):
            with self.subTest(key=key, value=value):
                self.run_gate({**self.valid, key: value}, success=False)

    def test_provisioning_profile_wrapper_does_not_count_as_signed_entitlements(self):
        self.run_gate({"Entitlements": self.valid}, success=False)

    def test_wrong_root_type_fails(self):
        self.run_gate([self.valid], success=False)

    def test_invalid_and_missing_plist_fail_without_dumping_contents(self):
        for data in (
            b"private-plist-parser-canary",
            b"<plist><dict><bad>private-plist-parser-canary</bad></dict></plist>",
            b"<plist><integer>private-plist-parser-canary</integer></plist>",
            b"<plist><dict>private-plist-parser-canary",
            None,
        ):
            with self.subTest(data=data):
                if data is None:
                    self.path.unlink(missing_ok=True)
                else:
                    self.path.write_bytes(data)
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), str(self.path)],
                    capture_output=True, text=True, timeout=10,
                )
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assertIn("::error::CloudKit release gate:", output)
                self.assertNotIn("private-plist-parser-canary", output)


if __name__ == "__main__":
    unittest.main()
