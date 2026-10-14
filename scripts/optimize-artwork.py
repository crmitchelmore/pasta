#!/usr/bin/env python3
"""Shrink committed artwork (PNG or ICNS) in place with no visible change.

Every PNG, including each PNG slot inside an ICNS, is recompressed losslessly.
Images at least 256 px wide are also palette-quantised. The palette version is
kept only if it saves at least 25% and stays at or above MIN_PSNR on both black
and white backdrops. Colour metadata (sRGB/iCCP/gAMA/cHRM/cICP/pHYs) is kept.
Re-running is safe: an already-optimised image fails the 25% gate and stays
lossless.

Requires pillow, imagequant and pyoxipng (`python3 -m pip install pillow
imagequant pyoxipng`). Release jobs ship the committed output and do not run this.
"""
import argparse
import importlib.util
import io
import math
from pathlib import Path
import struct
import sys
import zlib

sys.dont_write_bytecode = True

try:
    import imagequant
    import oxipng
    from PIL import Image, ImageChops, ImageStat
except ImportError as error:
    raise SystemExit(f"{error}. Install with: python3 -m pip install pillow imagequant pyoxipng")

_spec = importlib.util.spec_from_file_location("slim_icns", Path(__file__).with_name("ci-slim-icns.py"))
_icns = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_icns)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COLOUR_CHUNKS = (b"iCCP", b"sRGB", b"gAMA", b"cHRM", b"cICP", b"pHYs")
MIN_QUANTISE_WIDTH = 256
MIN_PSNR = 45.0
MIN_SAVING = 0.25


def png_chunks(data):
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Not a PNG")
    chunks, offset = [], len(PNG_SIGNATURE)
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        chunks.append((data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]))
        offset += 12 + length
    return chunks


def encode_png(chunks):
    return PNG_SIGNATURE + b"".join(
        struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        for kind, body in chunks)


def with_colour_metadata(png, source):
    keep = [chunk for chunk in png_chunks(source) if chunk[0] in COLOUR_CHUNKS]
    chunks = [chunk for chunk in png_chunks(png) if chunk[0] not in COLOUR_CHUNKS]
    return encode_png(chunks[:1] + keep + chunks[1:])


def visible_psnr(original, candidate):
    worst = math.inf
    for backdrop in ((0, 0, 0, 255), (255, 255, 255, 255)):
        base = Image.new("RGBA", original.size, backdrop)
        a = Image.alpha_composite(base, original).convert("RGB")
        b = Image.alpha_composite(base, candidate).convert("RGB")
        squares = sum(ImageStat.Stat(ImageChops.difference(a, b)).sum2)
        mse = squares / (original.size[0] * original.size[1] * 3)
        worst = min(worst, math.inf if mse == 0 else 10 * math.log10(255 ** 2 / mse))
    return worst


def lossless(png):
    # StripChunks.safe() drops gAMA/cHRM; keep every colour chunk explicitly.
    return oxipng.optimize_from_memory(png, level=6, strip=oxipng.StripChunks.keep(list(COLOUR_CHUNKS)))


def optimise_png(data):
    best = min((data, lossless(data)), key=len)
    width = struct.unpack(">I", png_chunks(data)[0][1][:4])[0]
    if width < MIN_QUANTISE_WIDTH:
        return best, None
    with Image.open(io.BytesIO(data)) as image:
        rgba = image.convert("RGBA")
    quantised = imagequant.quantize_pil_image(
        rgba, dithering_level=0.5, max_colors=256, min_quality=0, max_quality=100)
    buffer = io.BytesIO()
    quantised.save(buffer, "PNG")
    candidate = lossless(with_colour_metadata(buffer.getvalue(), data))
    with Image.open(io.BytesIO(candidate)) as image:
        psnr = visible_psnr(rgba, image.convert("RGBA"))
    if psnr >= MIN_PSNR and len(candidate) <= (1 - MIN_SAVING) * len(best):
        return candidate, psnr
    return best, None


def optimise_file(path):
    data = path.read_bytes()
    if data.startswith(PNG_SIGNATURE):
        output, psnr = optimise_png(data)
        notes = [] if psnr is None else [f"palette {psnr:.1f} dB"]
    else:
        cache, notes, entries = {}, [], []
        for kind, payload in _icns.parse_icns(data):
            if payload.startswith(PNG_SIGNATURE):
                if payload not in cache:
                    cache[payload] = optimise_png(payload)
                payload, psnr = cache[payload]
                if psnr is not None:
                    notes.append(f"{kind} palette {psnr:.1f} dB")
            entries.append((kind, payload))
        output = _icns.build_icns(entries)
    if len(output) < len(data):
        path.write_bytes(output)
    print(f"{path}: {len(data)} -> {min(len(output), len(data))} bytes"
          + (f" ({', '.join(notes)})" if notes else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", type=Path)
    for file in parser.parse_args().files:
        optimise_file(file)
