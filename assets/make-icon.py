#!/usr/bin/env python3
"""Draw ferry's app icon once: a white ferry on blue water in a rounded
square, 512x512 RGBA. Standard library only; the output is deterministic.

    python3 assets/make-icon.py            # writes assets/ferry.png
    python3 assets/make-icon.py out.png

The PNG is committed; install.sh copies it and never runs this script.
"""
import math
import os
import struct
import sys
import zlib

SIZE = 512
SS = 3  # supersamples per axis, for anti-aliased edges


def rgb(hexstr):
    return tuple(int(hexstr[i:i + 2], 16) for i in (1, 3, 5))


SKY_TOP, SKY_BOTTOM = rgb("#2E86C1"), rgb("#0B3C5D")
WATER, WAVE = rgb("#0F5E8C"), rgb("#7FC8EE")
WHITE, STRIPE = rgb("#F7F4EC"), rgb("#D9483B")
WINDOW, FUNNEL = rgb("#123A57"), rgb("#F2B33D")

MARGIN, RADIUS = 0.08, 0.19  # icon square inset and corner radius (units of SIZE)


def in_rounded_square(x, y):
    lo, hi = MARGIN, 1 - MARGIN
    if not (lo <= x <= hi and lo <= y <= hi):
        return False
    cx = min(max(x, lo + RADIUS), hi - RADIUS)
    cy = min(max(y, lo + RADIUS), hi - RADIUS)
    return (x - cx) ** 2 + (y - cy) ** 2 <= RADIUS ** 2


def in_rect(x, y, x0, y0, x1, y1):
    return x0 <= x <= x1 and y0 <= y <= y1


def in_hull(x, y):
    # Deck from 0.18 to 0.84; the bow (right) slopes in more than the stern.
    top, bottom = 0.555, 0.70
    if not top <= y <= bottom:
        return False
    t = (y - top) / (bottom - top)
    return 0.18 + 0.07 * t <= x <= 0.84 - 0.12 * t


def wave_top(x, base, amp, waves, phase):
    return base + amp * math.sin(2 * math.pi * (waves * x + phase))


def color_at(x, y):
    """Colour of the point (x, y) in [0,1]^2, or None outside the icon."""
    if not in_rounded_square(x, y):
        return None
    t = (y - MARGIN) / (1 - 2 * MARGIN)
    c = tuple(round(a + (b - a) * t) for a, b in zip(SKY_TOP, SKY_BOTTOM))
    if y >= wave_top(x, 0.665, 0.012, 2.5, 0.0):
        c = WATER
    # The boat: funnel, bridge, cabin with windows, hull with a stripe.
    if in_rect(x, y, 0.53, 0.27, 0.60, 0.37):
        c = STRIPE if y < 0.30 else FUNNEL
    if in_rect(x, y, 0.37, 0.36, 0.64, 0.45):
        c = WHITE
        if in_rect(x, y, 0.40, 0.385, 0.61, 0.42):
            c = WINDOW
    if in_rect(x, y, 0.27, 0.45, 0.76, 0.56):
        c = WHITE
        for i in range(6):
            wx = 0.30 + i * 0.075
            if in_rect(x, y, wx, 0.48, wx + 0.045, 0.52):
                c = WINDOW
    if in_hull(x, y):
        c = STRIPE if 0.595 <= y <= 0.625 else WHITE
    # Foreground water over the hull's foot, with a light crest line.
    crest = wave_top(x, 0.70, 0.014, 3.0, 0.25)
    if y >= crest:
        c = WAVE if y < crest + 0.018 else WATER
    if y >= wave_top(x, 0.78, 0.012, 3.5, 0.6) and y < wave_top(x, 0.78, 0.012, 3.5, 0.6) + 0.016:
        c = WAVE
    return c


def render():
    rows = []
    for py in range(SIZE):
        row = bytearray([0])  # filter: none
        for px in range(SIZE):
            r = g = b = a = 0
            for sy in range(SS):
                for sx in range(SS):
                    c = color_at((px + (sx + 0.5) / SS) / SIZE, (py + (sy + 0.5) / SS) / SIZE)
                    if c is not None:
                        r += c[0]; g += c[1]; b += c[2]; a += 1
            n = SS * SS
            if a:
                row += bytes((round(r / a), round(g / a), round(b / a), round(255 * a / n)))
            else:
                row += b"\0\0\0\0"
        rows.append(bytes(row))
    return b"".join(rows)


def png(raw):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "ferry.png")
    with open(out, "wb") as f:
        f.write(png(render()))
    print(out)


if __name__ == "__main__":
    main()
