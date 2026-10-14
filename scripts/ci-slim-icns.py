#!/usr/bin/env python3
"""Copy an ICNS without its 1024 px slot, for the DMG volume icon.

IconServices draws each size from its exact slot, so the remaining sizes render
unchanged; only a 512 pt Retina volume icon is upscaled from 512 px.
"""
import argparse
from pathlib import Path
import struct

VOLUME_ICON_DROPS = frozenset({"ic10"})


def parse_icns(data):
    if data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data):
        raise ValueError("Not a well-formed ICNS file")
    entries, offset = [], 8
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Truncated ICNS entry header")
        kind = data[offset:offset + 4].decode("latin-1")
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if length < 8 or offset + length > len(data):
            raise ValueError(f"Invalid ICNS entry length for {kind}")
        entries.append((kind, data[offset + 8:offset + length]))
        offset += length
    return entries


def build_icns(entries):
    body = b"".join(kind.encode("latin-1") + struct.pack(">I", len(payload) + 8) + payload
                    for kind, payload in entries)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def slim_icns(data, drop=VOLUME_ICON_DROPS):
    entries = parse_icns(data)
    kept = [entry for entry in entries if entry[0] not in drop]
    if len(kept) == len(entries):
        raise ValueError(f"ICNS has none of {sorted(drop)} to drop")
    return build_icns(kept)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    slimmed = slim_icns(args.source.read_bytes())
    args.destination.write_bytes(slimmed)
    print(f"Slimmed {args.source} to {len(slimmed)} bytes at {args.destination}")
