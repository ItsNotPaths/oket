#!/usr/bin/env python3
"""BDF bitmap font -> oket's fallback glyph atlas.

The output is COMMITTED to src/gfx/. src/gfx/atlas.odin `#load`s it, and #load resolves at
compile time, so a fresh clone has to build without ever running this. Re-run it only to
change the font or the glyph set.

    tools/gen-atlas.py spleen-8x16.bdf src/gfx/fallback_atlas.bin

Blob layout, little-endian:

    0   4   magic "OKAT"
    4   2   version
    6   1   cell_w          pixels
    7   1   cell_h          pixels
    8   2   range_count
    10  2   reserved        keeps the range table 4-byte aligned
    12  8n  ranges          lo u32, hi u32, both inclusive, sorted
    ..  ..  bitmap          glyph 0 first, then every range in order;
                            cell_h rows per glyph, one byte per 8 pixels, MSB leftmost

Glyph 0 is a synthesized tofu box, drawn for any rune the atlas does not have.
"""
import sys, struct

MAGIC, VERSION = b"OKAT", 1

# The floor a broken machine boots to: a readable command line, accented Latin, and the
# box-drawing a TUI needs for its borders. Geometric shapes, arrows and Braille are left to
# the real font — they are not what you need to fix a config file.
RANGES = [
    (0x20, 0x7E),      # ASCII
    (0xA0, 0xFF),      # Latin-1 supplement
    (0x2500, 0x257F),  # box drawing
    (0x2580, 0x259F),  # block elements
]


def parse_bdf(path):
    """-> (cell_w, cell_h, {codepoint: [row bytes]})"""
    cell_w = cell_h = None
    glyphs, cp, rows, in_bitmap = {}, None, None, False
    for line in open(path, encoding="latin-1"):
        line = line.strip()
        if line.startswith("FONTBOUNDINGBOX"):
            _, w, h, _, _ = line.split()
            cell_w, cell_h = int(w), int(h)
        elif line.startswith("ENCODING"):
            cp = int(line.split()[1])
        elif line.startswith("BBX"):
            _, w, h, xo, yo = line.split()
            if (int(w), int(h)) != (cell_w, cell_h):
                sys.exit(f"glyph {cp}: BBX {w}x{h} is not the cell {cell_w}x{cell_h}; "
                         "this generator only takes uniform bitmap fonts")
        elif line == "BITMAP":
            in_bitmap, rows = True, []
        elif line == "ENDCHAR":
            if cp is not None and cp >= 0:
                glyphs[cp] = rows
            in_bitmap, cp, rows = False, None, None
        elif in_bitmap:
            rows.append(int(line, 16))
    if cell_w is None:
        sys.exit("no FONTBOUNDINGBOX in the BDF")
    return cell_w, cell_h, glyphs


def tofu(cell_w, cell_h):
    """A hollow box, inset by one pixel. Drawn for anything the atlas is missing, because a
    blank cell reads as a space and hides the problem."""
    full = (1 << cell_w) - 2  # every column but the last
    rows = []
    for y in range(cell_h):
        if y in (1, cell_h - 2):
            rows.append(full)
        elif 1 < y < cell_h - 2:
            rows.append((1 << (cell_w - 1)) | 0b10)
        else:
            rows.append(0)
    return rows


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    cell_w, cell_h, glyphs = parse_bdf(src)
    if cell_w % 8:
        sys.exit(f"cell width {cell_w} is not a multiple of 8; the row packing assumes it is")
    stride = cell_w // 8

    out = [tofu(cell_w, cell_h)]
    missing = []
    for lo, hi in RANGES:
        for cp in range(lo, hi + 1):
            if cp not in glyphs:
                missing.append(cp)
                out.append(out[0])
            else:
                out.append(glyphs[cp])
    if missing:
        print(f"  warning: {len(missing)} codepoints not in the font, using tofu: "
              + ", ".join(f"U+{c:04X}" for c in missing[:8])
              + (" ..." if len(missing) > 8 else ""))

    blob = bytearray()
    blob += MAGIC
    blob += struct.pack("<HBBHH", VERSION, cell_w, cell_h, len(RANGES), 0)
    for lo, hi in RANGES:
        blob += struct.pack("<II", lo, hi)
    for rows in out:
        for r in rows:
            blob += r.to_bytes(stride, "big")  # MSB is the leftmost pixel

    open(dst, "wb").write(blob)
    print(f"  {len(out)} glyphs, {cell_w}x{cell_h}, {len(blob)} bytes -> {dst}")


if __name__ == "__main__":
    main()
