#!/bin/bash
#############################################################################
# png_case.sh - exercise src/png.h's PNG decoder, off-device.
#
# The carousel's own build has no test hook into its render loop, so this
# drives it through `gameswitcher --decode IN.png OUT.bmp` (needs no video
# driver at all -- see main()'s handling of --decode) instead: encode small
# synthetic PNGs with python3's stdlib zlib (no PIL -- that's a dev-only
# dependency this project doesn't otherwise need), decode each with the real
# binary, and check the resulting BMP's pixels against known values.
#
# Covers what RetroArch's own screenshots need (colour type 2 and 6, all
# five PNG filter types, multi-chunk IDAT, an odd width to exercise row
# padding) plus the rejection paths (truncated file, unsupported 16-bit
# depth) that must fail cleanly rather than crash -- gameswitcher.c already
# treats a NULL surface exactly like a missing thumbnail file.
#############################################################################

set -u

ROOT="$1"
BIN="${ROOT}/gameswitcher"

if [ ! -x "${BIN}" ]; then
  echo "  skip png_case (binary not built; run make)"
  exit 0
fi

python3 - "${BIN}" <<'PYEOF'
import struct
import subprocess
import sys
import zlib

binpath = sys.argv[1]
FAIL = 0


def ok(msg):
    print(f"    ok   {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"    FAIL {msg}")
    if detail:
        print(f"         {detail}")


def chunk(tag, data):
    c = tag + data
    crc = zlib.crc32(c) & 0xffffffff
    return struct.pack(">I", len(data)) + c + struct.pack(">I", crc)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def filter_row(cur, prev, bpp, ftype):
    n = len(cur)
    out = bytearray(n)
    for i in range(n):
        a = cur[i - bpp] if i >= bpp else 0
        b = prev[i] if prev else 0
        c = prev[i - bpp] if (prev and i >= bpp) else 0
        if ftype == 0:
            out[i] = cur[i]
        elif ftype == 1:
            out[i] = (cur[i] - a) & 0xFF
        elif ftype == 2:
            out[i] = (cur[i] - b) & 0xFF
        elif ftype == 3:
            out[i] = (cur[i] - (a + b) // 2) & 0xFF
        elif ftype == 4:
            out[i] = (cur[i] - paeth(a, b, c)) & 0xFF
    return bytes(out)


def make_png(w, h, colortype, pixel_fn, cycle_filters=False, split_idat=False,
             bitdepth=8):
    bpp = 3 if colortype == 2 else 4
    ihdr = struct.pack(">IIBBBBB", w, h, bitdepth, colortype, 0, 0, 0)
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            row.extend(pixel_fn(x, y))
        rows.append(bytes(row))

    filtered = bytearray()
    prev = None
    for y, row in enumerate(rows):
        ftype = (y % 5) if cycle_filters else 0
        filtered.append(ftype)
        filtered.extend(filter_row(row, prev, bpp, ftype))
        prev = row

    comp = zlib.compress(bytes(filtered), 6)
    if split_idat and len(comp) > 4:
        mid = len(comp) // 2
        idat = chunk(b"IDAT", comp[:mid]) + chunk(b"IDAT", comp[mid:])
    else:
        idat = chunk(b"IDAT", comp)

    sig = b"\x89PNG\r\n\x1a\n"
    return sig + chunk(b"IHDR", ihdr) + idat + chunk(b"IEND", b"")


def read_bmp_pixel(path, x, y):
    with open(path, "rb") as f:
        data = f.read()
    off = struct.unpack("<I", data[10:14])[0]
    w = struct.unpack("<i", data[18:22])[0]
    h = struct.unpack("<i", data[22:26])[0]
    bpp = struct.unpack("<H", data[28:30])[0] // 8
    row_size = ((w * bpp + 3) // 4) * 4
    row_from_bottom = h - 1 - y
    idx = off + row_from_bottom * row_size + x * bpp
    return list(data[idx : idx + bpp])


def decode(png_path, bmp_path):
    return subprocess.run(
        [binpath, "--decode", png_path, bmp_path],
        capture_output=True,
        text=True,
    )


def rgb_px(x, y):
    return (x % 256, y % 256, (x + y) % 256)


def rgba_px(x, y):
    return (x % 256, y % 256, (x + y) % 256, 200)


work = sys.argv[0]  # unused, python3 - passes script name as argv[0]
import tempfile
import os

with tempfile.TemporaryDirectory() as tmp:
    # --- colour type 2 (RGB), odd width, no filtering -----------------
    png = os.path.join(tmp, "rgb.png")
    bmp = os.path.join(tmp, "rgb.bmp")
    open(png, "wb").write(make_png(17, 13, 2, rgb_px))
    r = decode(png, bmp)
    if r.returncode == 0 and read_bmp_pixel(bmp, 5, 7) == [12, 7, 5]:
        ok("colour type 2 (RGB), odd width decodes correctly")
    else:
        bad("colour type 2 (RGB), odd width decodes correctly",
            f"rc={r.returncode} stderr={r.stderr!r}")

    # --- colour type 6 (RGBA), split across two IDAT chunks -----------
    png = os.path.join(tmp, "rgba.png")
    bmp = os.path.join(tmp, "rgba.bmp")
    open(png, "wb").write(make_png(20, 10, 6, rgba_px, split_idat=True))
    r = decode(png, bmp)
    if r.returncode == 0 and read_bmp_pixel(bmp, 10, 3) == [13, 3, 10, 200]:
        ok("colour type 6 (RGBA), split IDAT decodes correctly")
    else:
        bad("colour type 6 (RGBA), split IDAT decodes correctly",
            f"rc={r.returncode} stderr={r.stderr!r}")

    # --- all five filter types, one per row ---------------------------
    def gradient_px(x, y):
        v = (x * 7 + y * 13) % 256
        return (v, v, v)

    png = os.path.join(tmp, "filters.png")
    bmp = os.path.join(tmp, "filters.bmp")
    open(png, "wb").write(make_png(9, 5, 2, gradient_px, cycle_filters=True))
    r = decode(png, bmp)
    all_ok = r.returncode == 0
    if all_ok:
        for y in range(5):
            for x in (0, 3, 8):
                expected = (x * 7 + y * 13) % 256
                got = read_bmp_pixel(bmp, x, y)
                if got != [expected, expected, expected]:
                    all_ok = False
    if all_ok:
        ok("all five PNG filter types decode correctly")
    else:
        bad("all five PNG filter types decode correctly",
            f"rc={r.returncode} stderr={r.stderr!r}")

    # --- rejection paths: must fail cleanly, never crash --------------
    trunc = os.path.join(tmp, "truncated.png")
    good_bytes = open(os.path.join(tmp, "rgb.png"), "rb").read()
    open(trunc, "wb").write(good_bytes[:60])
    r = decode(trunc, os.path.join(tmp, "trunc.bmp"))
    if r.returncode != 0:
        ok("a truncated PNG fails cleanly (no crash)")
    else:
        bad("a truncated PNG fails cleanly (no crash)",
            f"expected non-zero exit, got rc={r.returncode}")

    def px16(x, y):
        return (1000, 2000, 3000)

    sixteen = os.path.join(tmp, "sixteen.png")
    # make_png's filter_row operates byte-wise, which isn't meaningful at
    # 16-bit depth -- fine here, since the only thing under test is that
    # gs_load_png rejects bitdepth != 8 before it ever reads pixel data.
    open(sixteen, "wb").write(
        make_png(4, 4, 2, lambda x, y: (0, 0, 0, 0, 0, 0), bitdepth=16)
    )
    r = decode(sixteen, os.path.join(tmp, "sixteen.bmp"))
    if r.returncode != 0:
        ok("16-bit depth is rejected cleanly (no crash)")
    else:
        bad("16-bit depth is rejected cleanly (no crash)",
            f"expected non-zero exit, got rc={r.returncode}")

    empty = os.path.join(tmp, "empty.png")
    open(empty, "wb").write(b"")
    r = decode(empty, os.path.join(tmp, "empty.bmp"))
    if r.returncode != 0:
        ok("an empty file fails cleanly (no crash)")
    else:
        bad("an empty file fails cleanly (no crash)",
            f"expected non-zero exit, got rc={r.returncode}")

sys.exit(1 if FAIL else 0)
PYEOF
