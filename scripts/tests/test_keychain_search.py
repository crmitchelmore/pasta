"""Release cleanup must restore personal keychains, including paths with spaces."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'ci-keychain-search.py'

class KeychainSearchTests(unittest.TestCase):
    def test_add_restore_and_repeated_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            snapshot = str(Path(folder) / 'original.json')
            original = ['/Users/a/Library/Keychains/login.keychain-db', '/tmp/with spaces.keychain-db']
            with patch('sys.argv', [str(SCRIPT), 'add', snapshot, '/tmp/release.keychain-db']), patch('subprocess.check_output', return_value='\n'.join(json.dumps(p) for p in original)), patch('subprocess.run') as run:
                runpy.run_path(str(SCRIPT), run_name='__main__')
                self.assertEqual(json.loads(Path(snapshot).read_text()), original)
                self.assertEqual(run.call_args.args[0][-3:], ['/tmp/release.keychain-db', *original])
            with patch('sys.argv', [str(SCRIPT), 'restore', snapshot]), patch('subprocess.run') as run:
                runpy.run_path(str(SCRIPT), run_name='__main__')
                self.assertEqual(run.call_args.args[0][-2:], original)
                self.assertFalse(Path(snapshot).exists())
                run.reset_mock()
                runpy.run_path(str(SCRIPT), run_name='__main__')
                run.assert_not_called()

    def test_failed_restore_keeps_recovery_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            snapshot = Path(folder) / 'original.json'
            snapshot.write_text('["/tmp/login.keychain-db"]')
            with patch('sys.argv', [str(SCRIPT), 'restore', str(snapshot)]), patch('subprocess.run', side_effect=RuntimeError('security failed')):
                with self.assertRaises(RuntimeError):
                    runpy.run_path(str(SCRIPT), run_name='__main__')
            self.assertTrue(snapshot.exists())
