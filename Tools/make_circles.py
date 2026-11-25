"""Writes Media/circleN.tga: white anti-aliased discs used for rounded corners (Skin.lua).
Uncompressed 32-bit TGA, power-of-two sizes, 8x8 supersampling per pixel."""
import os, struct

def disc(n, ss=8):
    r = n / 2
    out = bytearray()
    for y in range(n - 1, -1, -1):  # TGA rows go bottom-up
        for x in range(n):
            hits = 0
            for sy in range(ss):
                for sx in range(ss):
                    px, py = x + (sx + 0.5) / ss - r, y + (sy + 0.5) / ss - r
                    hits += px * px + py * py <= r * r
            out += bytes((255, 255, 255, round(255 * hits / (ss * ss))))
    return struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, n, n, 32, 8) + bytes(out)

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Media")
for n in (8, 16, 32, 64):
    with open(os.path.join(root, f"circle{n}.tga"), "wb") as f:
        f.write(disc(n))
