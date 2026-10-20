"""PNG (8-bit RGB/RGBA, non-interlaced) -> 24-bit bottom-up BMP, flattened on a background colour.

Inno Setup's wizard images are safest as classic 24-bit BMPs. Stdlib only.
usage: png2bmp.py in.png out.bmp R,G,B
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat = 8, b""
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0 and ctype in (2, 6), "unsupported PNG"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(line); prev = line
    return w, h, bpp, rows


def main():
    src, dst, bg = sys.argv[1], sys.argv[2], [int(v) for v in sys.argv[3].split(",")]
    w, h, bpp, rows = read_png(src)
    pad = (4 - (w * 3) % 4) % 4
    pixels = bytearray()
    for line in reversed(rows):            # BMP is bottom-up
        for x in range(w):
            r, g, b = line[x * bpp:x * bpp + 3]
            a = line[x * bpp + 3] if bpp == 4 else 255
            mix = lambda c, k: (c * a + k * (255 - a)) // 255
            pixels += bytes((mix(b, bg[2]), mix(g, bg[1]), mix(r, bg[0])))
        pixels += b"\0" * pad
    header = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    open(dst, "wb").write(header + info + pixels)


if __name__ == "__main__":
    main()
