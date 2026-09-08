#!/usr/bin/env python3
"""Require a matching nonempty dSYM UUID for every architecture of a binary."""
import re
import subprocess
import sys


def parse_uuids(output):
    matches = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', output, re.MULTILINE)
    result = {arch: uuid.upper() for uuid, arch in matches}
    if not result or len(result) != len(matches):
        raise ValueError('Missing or ambiguous Mach-O UUID evidence')
    return result


def verify(binary_output, symbol_output):
    if parse_uuids(binary_output) != parse_uuids(symbol_output):
        raise ValueError('dSYM UUIDs do not match every binary architecture')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: ci-verify-symbols.py <binary> <dSYM>')
    outputs = [subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', path], text=True) for path in sys.argv[1:]]
    verify(*outputs)
    print('Verified matching binary/dSYM UUIDs on every architecture')
