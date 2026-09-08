import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('symbols', Path(__file__).resolve().parents[1] / 'ci-verify-symbols.py')
symbols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(symbols)

class SymbolsTests(unittest.TestCase):
    def test_all_architectures_must_match_nonempty_evidence(self):
        arm = 'UUID: AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA (arm64) binary'
        intel = 'UUID: BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB (x86_64) binary'
        symbols.verify(arm + '\n' + intel, intel + '\n' + arm)
        for invalid in ['', 'success', arm, arm + '\n' + arm, arm + '\n' + intel.replace('BBBBBBBB', 'CCCCCCCC')]:
            with self.assertRaises(ValueError):
                symbols.verify(arm + '\n' + intel, invalid)
