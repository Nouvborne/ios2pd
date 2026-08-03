#!/usr/bin/env python3
"""Generate simple app icons for ios2pd as PNGs without external deps.

Usage: make_icon.py <app-bundle-dir>
"""
import os
import struct
import sys
import zlib


def _png(path, size, color_fn):
    w = h = size
    rows = []
    for y in range(h):
        row = bytearray([0])  # filter: none
        for x in range(w):
            row += bytes(color_fn(x, y, w, h))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(typ, data):
        return (
            struct.pack(">I", len(data))
            + typ
            + data
            + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def color_fn(x, y, w, h):
    cx, cy = w / 2.0, h / 2.0
    r = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
    R = h * 0.42
    if abs(r - R) < h * 0.055:
        return (0, 216, 255, 255)   # cyan ring
    if r < R * 0.16:
        return (255, 255, 255, 255) # inner dot
    return (26, 26, 46, 255)        # dark navy


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    app_dir = sys.argv[1]
    os.makedirs(app_dir, exist_ok=True)
    sizes = {
        "AppIcon60x60@2x.png": 120,
        "AppIcon60x60@3x.png": 180,
        "AppIcon76x76@2x.png": 152,
    }
    for name, size in sizes.items():
        _png(os.path.join(app_dir, name), size, color_fn)
        print("wrote", name)


if __name__ == "__main__":
    main()
