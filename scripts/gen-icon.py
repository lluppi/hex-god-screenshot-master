#!/usr/bin/env python3
"""Bake the macOS app icon into assets/icon/icon.icns.

The mark is the tool's own vocabulary: the dark field, and a 3x3 grid of sampled
pixels. It is drawn at 4x and box-filtered down, the same way the interface font
is, because neither PIL's rounded rectangles nor its ellipse strokes are
anti-aliased.

The .icns container is written here rather than with iconutil, which only exists
on macOS: every entry is a PNG, which is what "ic07".."ic14" and "icp4".."icp6"
have meant since 10.7, and nothing older than macOS 13 is supported anyway.
"""

import io
import struct
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICNS = ROOT / "assets" / "icon" / "icon.icns"
PREVIEW = ROOT / "assets" / "icon" / "icon.png"

SIZE = 1024
SUPERSAMPLE = 4
CANVAS = SIZE * SUPERSAMPLE

# macOS 11+ icon geometry: the squircle is inset from the full-bleed canvas.
INSET = 100 * SUPERSAMPLE
RADIUS = 0.2246 * (SIZE - 2 * 100) * SUPERSAMPLE

# Dark appearance surface, top to bottom.
SURFACE_TOP = (28, 28, 30)
SURFACE_BOTTOM = (10, 10, 11)

# 3x3 of sampled pixels, cool through warm on the diagonal.
PIXELS = [
    (139, 92, 246),
    (99, 102, 241),
    (59, 130, 246),
    (14, 165, 233),
    (34, 211, 238),
    (20, 184, 166),
    (34, 197, 94),
    (234, 179, 8),
    (249, 115, 22),
]

GRID = 640 * SUPERSAMPLE
GUTTER = 26 * SUPERSAMPLE
CELL = (GRID - 2 * GUTTER) // 3
CELL_RADIUS = CELL // 6


def rounded_mask(size: int, radius: float, box: tuple[int, int, int, int]) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def surface() -> Image.Image:
    """The squircle: a vertical gradient, clipped to the rounded shape."""
    gradient = Image.new("RGB", (1, CANVAS))
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        gradient.putpixel(
            (0, y),
            tuple(round(a + (b - a) * t) for a, b in zip(SURFACE_TOP, SURFACE_BOTTOM)),
        )
    layer = gradient.resize((CANVAS, CANVAS))
    layer.putalpha(rounded_mask(CANVAS, RADIUS, (INSET, INSET, CANVAS - INSET, CANVAS - INSET)))
    return layer


def pixels() -> Image.Image:
    """The 3x3 grid, centred, each cell a rounded square."""
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    origin = (CANVAS - GRID) // 2
    for index, colour in enumerate(PIXELS):
        column, row = index % 3, index // 3
        x = origin + column * (CELL + GUTTER)
        y = origin + row * (CELL + GUTTER)
        cell = Image.new("RGBA", (CELL, CELL), colour + (255,))
        cell.putalpha(rounded_mask(CELL, CELL_RADIUS, (0, 0, CELL - 1, CELL - 1)))
        layer.alpha_composite(cell, (x, y))
    return layer


def render() -> Image.Image:
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.alpha_composite(surface())
    icon.alpha_composite(pixels())
    return icon.resize((SIZE, SIZE), Image.LANCZOS)


def png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def icns(entries: list[tuple[bytes, bytes]]) -> bytes:
    body = b"".join(
        kind + struct.pack(">I", len(data) + 8) + data for kind, data in entries
    )
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main() -> None:
    icon = render()
    # Every entry is the same picture at a different size; the 16, 32 and 64
    # pixel forms are listed twice because both the legacy and the @2x slots
    # take a PNG of that size.
    sizes = {
        b"icp4": 16,
        b"icp5": 32,
        b"icp6": 64,
        b"ic07": 128,
        b"ic08": 256,
        b"ic09": 512,
        b"ic10": 1024,
        b"ic11": 32,
        b"ic12": 64,
        b"ic13": 256,
        b"ic14": 512,
    }
    entries = [
        (kind, png(icon if size == SIZE else icon.resize((size, size), Image.LANCZOS)))
        for kind, size in sizes.items()
    ]
    ICNS.parent.mkdir(parents=True, exist_ok=True)
    ICNS.write_bytes(icns(entries))
    PREVIEW.write_bytes(png(icon))
    print(f"{ICNS.relative_to(ROOT)}  {ICNS.stat().st_size} bytes")
    print(f"{PREVIEW.relative_to(ROOT)}  {PREVIEW.stat().st_size} bytes")


if __name__ == "__main__":
    main()
