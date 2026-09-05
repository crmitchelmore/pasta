"""Failure injection against the real CI entrypoints; no Xcode or network needed.

The subprocess doubles replace only external executables. They deliberately
emit reassuring success text alongside failures to prove the shell cannot
turn a failed build, incomplete test run, or unverified upload into green CI.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CIGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pasta-gates-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "STATE_DIR": str(self.root / "state"),
            "DIAG_DIR": str(self.root / "diagnostics"),
            "RESULT_BUNDLE": str(self.root / "tests.xcresult"),
            "DERIVED_DATA": str(self.root / "derived"),
            "SIM_UDID": "fake-simulator",
            "RUNNER_TEMP": str(self.root),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary.md"),
            "MOCK_RESULT": json.dumps({
                "result": "Passed", "totalTestCount": 2, "passedTests": 2,
                "failedTests": 0, "skippedTests": 0, "testFailures": [],
            }),
        }
        self.executable("xcodebuild", """
import os, sys
from pathlib import Path
if '-onlyUsePackageVersionsFromResolvedFile' not in sys.argv:
    sys.exit('The native gate must preserve strict dependency resolution')
if '-showBuildSettings' in sys.argv:
    print('    SWIFT_ACTIVE_COMPILATION_CONDITIONS = PASTA_IOS_CLOUDKIT_PROVISIONED')
    sys.exit(0)
if '-retry-tests-on-failure' in sys.argv:
    sys.exit('Retries must not conceal a failing gate')
if '-resultBundlePath' in sys.argv:
    Path(sys.argv[sys.argv.index('-resultBundlePath') + 1]).mkdir()
if os.environ.get('MOCK_OMIT_SUCCESS') != '1':
    action = 'BUILD' if 'build-for-testing' in sys.argv else 'EXECUTE'
    print(f'** TEST {action} SUCCEEDED **')
sys.exit(int(os.environ.get('MOCK_XCODE_EXIT', '0')))
""")
        self.executable("xcrun", """
import os, sys
from pathlib import Path
if not Path(sys.argv[sys.argv.index('--path') + 1]).is_dir():
    sys.exit('Missing result bundle')
print(os.environ['MOCK_RESULT'])
sys.exit(int(os.environ.get('MOCK_RESULT_EXIT', '0')))
""")

    def executable(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\n' + body)
        path.chmod(0o755)

    def run_script(self, script, *args, success, **environment):
        result = subprocess.run(
            ['bash', str(ROOT / 'scripts' / script), *args],
            cwd=self.root, env={**self.env, **environment},
            capture_output=True, text=True, timeout=15,
        )
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def test_successful_build_and_nonempty_test_run_pass(self):
        self.run_script('ci-ios-e2e.sh', 'build-for-testing', success=True)
        output = self.run_script('ci-ios-e2e.sh', 'test', success=True)
        self.assertIn('Verified 2 passing XCUITests', output)

    def test_success_banner_cannot_hide_xcodebuild_failure(self):
        for command in ('build-for-testing', 'test'):
            with self.subTest(command=command):
                output = self.run_script('ci-ios-e2e.sh', command, success=False, MOCK_XCODE_EXIT='65')
                self.assertIn('xcodebuild exited 65', output)

    def test_log_write_failure_is_not_ignored(self):
        self.executable('tee', """
import sys
from pathlib import Path
content = sys.stdin.read()
Path(sys.argv[1]).write_text(content)
print(content)
sys.exit(1)
""")
        for command in ('build-for-testing', 'test'):
            with self.subTest(command=command):
                output = self.run_script('ci-ios-e2e.sh', command, success=False)
                self.assertIn('log writer exited 1', output)

    def test_zero_exit_without_expected_operation_success_fails(self):
        for command in ('build-for-testing', 'test'):
            with self.subTest(command=command):
                self.run_script('ci-ios-e2e.sh', command, success=False, MOCK_OMIT_SUCCESS='1')

    def test_unreadable_result_fails_even_with_valid_json(self):
        self.run_script('ci-ios-e2e.sh', 'test', success=False, MOCK_RESULT_EXIT='1')

    def test_incomplete_or_failed_coverage_cannot_pass(self):
        valid = json.loads(self.env['MOCK_RESULT'])
        cases = {
            'zero tests': {**valid, 'totalTestCount': 0, 'passedTests': 0},
            'skipped test': {**valid, 'passedTests': 1, 'skippedTests': 1},
            'failed test': {**valid, 'result': 'Failed', 'passedTests': 1, 'failedTests': 1},
            'inconsistent count': {**valid, 'totalTestCount': 3},
            'failure details with passing counts': {**valid, 'testFailures': [{'testName': 'journey'}]},
            'missing fields': {'result': 'Passed'},
            'noninteger count': {**valid, 'passedTests': '2'},
        }
        for name, summary in cases.items():
            with self.subTest(name=name):
                output = self.run_script('ci-ios-e2e.sh', 'test', success=False, MOCK_RESULT=json.dumps(summary))
                self.assertIn('coverage gate requires', output)

    def test_malformed_result_fails(self):
        self.run_script('ci-ios-e2e.sh', 'test', success=False, MOCK_RESULT='{')

    def prepare_asc(self):
        key = self.root / 'test-only.p8'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt',
                        'ec_paramgen_curve:P-256', '-out', str(key)],
                       check=True, capture_output=True)
        self.env.update({
            'APP_STORE_CONNECT_KEY_ID': 'TESTKEY123',
            'APP_STORE_CONNECT_ISSUER_ID': '00000000-0000-0000-0000-000000000000',
            'ASC_KEY_PATH': str(key),
            'ASC_TIMEOUT_MINUTES': '0', 'ASC_POLL_SECONDS': '0',
        })
        self.executable('curl', """
import json, os, sys
url = sys.argv[-1]
if '/v1/apps?' in url:
    print(json.dumps({'data': [{'id': 'fake-app'}]}))
else:
    state = os.environ.get('MOCK_ASC_STATE', 'VALID')
    if state == 'HTTP_FAILURE':
        print('Service unavailable')
        sys.exit(22)
    data = [] if state == 'NOT_FOUND' else [{'id': 'fake-build', 'attributes': {
        'processingState': state, 'version': '123', 'expired': False,
    }}]
    print(json.dumps({'data': data}))
""")

    def test_asc_confirmed_valid_build_passes(self):
        self.prepare_asc()
        self.run_script('ci-asc-wait-for-build.sh', '1.2.3', '123', success=True)

    def test_asc_rejected_build_fails(self):
        self.prepare_asc()
        for state in ('INVALID', 'FAILED'):
            with self.subTest(state=state):
                output = self.run_script('ci-asc-wait-for-build.sh', '1.2.3', '123',
                                         success=False, MOCK_ASC_STATE=state)
                self.assertIn('rejected build', output)

    def test_asc_unverified_build_or_api_failure_cannot_pass_on_timeout(self):
        self.prepare_asc()
        for state in ('PROCESSING', 'NOT_FOUND', 'UNKNOWN', 'HTTP_FAILURE'):
            with self.subTest(state=state):
                output = self.run_script('ci-asc-wait-for-build.sh', '1.2.3', '123',
                                         success=False, MOCK_ASC_STATE=state)
                self.assertIn('Could not verify App Store Connect acceptance', output)
                self.assertIn('Do not re-upload', output)


if __name__ == '__main__':
    unittest.main()
