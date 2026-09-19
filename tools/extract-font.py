#!/usr/bin/env python3
"""Extract SVG assets from the supplied 1214x761 specimen using trace-god.

Usage: python3 tools/extract-font.py IMAGE TRACE_GOD_DIRECTORY OUTPUT_DIRECTORY
Requires Pillow, Bun and a local trace-god checkout. Does not change the app font.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

# Character: (ink's horizontal bounds, row cap top). Bounds are exclusive right.
# Use body text, avoiding the faint watermark across the top-left heading.
CROPS = {
    "0": (125, 147, 308), "1": (215, 226, 366),
    "2": (386, 406, 192), "3": (414, 435, 540),
    "4": (241, 263, 308), "5": (560, 580, 250),
    "6": (589, 609, 250), "7": (878, 898, 656),
    "8": (530, 552, 250), "9": (299, 319, 714),
    "A": (37, 61, 308), "B": (212, 233, 192),
    "C": (39, 60, 424), "D": (1138, 1159, 482),
    "E": (127, 146, 192), "F": (329, 348, 308),
}
CHARSET = "#0123456789ABCDEF×"
WIDTH, HEIGHT = 29, 44

# Use the tracing primitives rather than trace()'s independently normalised
# glyph boxes: source-space paths retain the shared cap height and advance.
TRACER = r"""
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [root, input, output] = process.argv.slice(2);
const load = (name) => import(pathToFileURL(`${root}/src/lib/core/${name}.ts`).href);
const { blur } = await load('gray');
const { isoContours } = await load('contour');
const { fitPath } = await load('fit');
// Catmull-Rom tangents can overshoot where a long stem meets a tiny
// antialias contour segment. Keep each cubic inside its endpoint box.
function boundedCurves(path) {
    const tokens = path.match(/[MLCZ]|-?\d+(?:\.\d+)?/g);
    let x = 0, y = 0, at = 0, result = '';
    while (at < tokens.length) {
        const command = tokens[at++];
        if (command === 'Z') { result += 'Z'; continue; }
        const count = command === 'C' ? 6 : 2;
        const values = tokens.slice(at, at + count).map(Number);
        at += count;
        const endX = values[count - 2], endY = values[count - 1];
        if (command === 'C') {
            for (let i = 0; i < 4; i += 2) {
                values[i] = Math.max(Math.min(x, endX), Math.min(Math.max(x, endX), values[i]));
                values[i + 1] = Math.max(Math.min(y, endY), Math.min(Math.max(y, endY), values[i + 1]));
            }
        }
        result += command + values.join(' ');
        x = endX; y = endY;
    }
    return result;
}
const result = {};
for (const [char, crop] of Object.entries(JSON.parse(readFileSync(input, 'utf8')))) {
    const field = blur({ width: 34, height: 44, data: Float64Array.from(crop.data) }, 0.35);
    const loops = isoContours(field, 128);
    if (!loops.length) throw new Error(`No contours for ${char}`);
    const xs = loops.flatMap(loop => loop.map(p => p.x));
    const centre = (Math.min(...xs) + Math.max(...xs)) / 2;
    result[char] = loops.map(loop => boundedCurves(fitPath(loop, {
        simplify: 0.18, cornerDeg: 150, tension: 1 / 6,
        grain: 0, grainScale: 1, seed: 0,
        transform: p => ({ x: p.x - centre + 14.5, y: p.y }),
    }))).join('');
}
writeFileSync(output, JSON.stringify(result));
"""


def bar(x1, y1, x2, y2, width=3.6):
    """Filled stroke with subtly chamfered ends, matching the specimen's cuts."""
    length = math.hypot(x2 - x1, y2 - y1)
    ux, uy = (x2 - x1) / length, (y2 - y1) / length
    nx, ny = -uy, ux
    half, bevel = width / 2, 0.4
    outline = [(0, -half + bevel), (bevel, -half),
               (length - bevel, -half), (length, -half + bevel),
               (length, half - bevel), (length - bevel, half),
               (bevel, half), (0, half - bevel)]
    points = [(x1 + u * ux + v * nx, y1 + u * uy + v * ny) for u, v in outline]
    d = "M" + " L".join(f"{x:.3f},{y:.3f}" for x, y in points) + " Z"
    return f'<path d="{d}"/>'


def reconstruct():
    return {
        "#": bar(12, 5, 7, 38) + bar(22, 5, 17, 38)
             + bar(4, 16, 26, 16) + bar(3, 27, 25, 27),
        "×": bar(5.5, 12.5, 23.5, 30.5) + bar(5.5, 30.5, 23.5, 12.5),
    }


def svg(body, width=WIDTH, height=HEIGHT):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">'
            f'{body}</svg>\n')


def preview(glyphs):
    parts = ['<rect width="960" height="480" fill="#11151b"/>']
    for index, char in enumerate(CHARSET):
        col, row = index % 9, index // 9
        x, y = 28 + col * 103, 20 + row * 135
        parts.append(f'<g transform="translate({x},{y}) scale(2)" fill="white">{glyphs[char]}</g>')
        label = f'{char}' + (' *' if char in '#×' else '')
        parts.append(f'<text x="{x + 29}" y="{y + 112}" text-anchor="middle" '
                     f'font-family="monospace" font-size="16" fill="#a8b4c5">{label}</text>')
    for text, scale, y in [("#1D4ED8", 1, 310), ("625×500", 1, 370),
                           ("#ABCDEF", 0.3, 435), ("1920×1080", 0.375, 435)]:
        origin = 420 if text == '1920×1080' else 30
        for index, char in enumerate(text):
            parts.append(f'<g transform="translate({origin + index * WIDTH * scale},{y}) '
                         f'scale({scale})" fill="white">{glyphs[char]}</g>')
    parts.append('<text x="420" y="330" font-family="monospace" font-size="16" '
                 'fill="#a8b4c5">* drawn to match, not present in source</text>')
    return svg(''.join(parts), 960, 480)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('trace_god', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    with Image.open(args.image) as original:
        if original.size != (1214, 761):
            parser.error('crop map requires the original 1214x761 glyphs.png')
        image = original.convert('L')
    crops = {}
    provenance = {}
    for char, (left, right, cap_top) in CROPS.items():
        x, y = math.floor((left + right) / 2 - 17), cap_top - 5
        box = (x, y, x + 34, y + HEIGHT)
        crop = image.crop(box)
        # Suppress neighbouring characters' faint antialias fringes.
        for column in range(34):
            if not left - 1 <= x + column < right + 1:
                crop.paste(0, (column, 0, column + 1, HEIGHT))
        crops[char] = {'data': list(crop.tobytes())}
        provenance[char] = {'kind': 'extracted', 'crop': list(box)}
    with tempfile.TemporaryDirectory(prefix='extract-font-') as temp:
        directory = Path(temp)
        (directory / 'trace.ts').write_text(TRACER)
        (directory / 'input.json').write_text(json.dumps(crops))
        subprocess.run(['bun', str(directory / 'trace.ts'), str(args.trace_god.resolve()),
                        str(directory / 'input.json'), str(directory / 'paths.json')], check=True)
        try:
            paths = json.loads((directory / 'paths.json').read_text())
        except (OSError, json.JSONDecodeError) as error:
            parser.error(f'could not read traced paths: {error}')
    glyphs = {char: f'<path fill-rule="evenodd" d="{d}"/>' for char, d in paths.items()}
    glyphs.update(reconstruct())
    for char in '#×':
        provenance[char] = {'kind': 'reconstructed'}
    args.output.mkdir(parents=True, exist_ok=True)
    for char in CHARSET:
        filename = {'#': 'hash', '×': 'times'}.get(char, char) + '.svg'
        provenance[char]['file'] = filename
        (args.output / filename).write_text(svg(f'<g fill="currentColor">{glyphs[char]}</g>'))
    manifest = {
        'source': args.image.name,
        'sha256': hashlib.sha256(args.image.read_bytes()).hexdigest(),
        'viewBox': [0, 0, WIDTH, HEIGHT], 'advance': WIDTH,
        'tracing': {'blur': 0.35, 'iso': 128, 'simplify': 0.18, 'cornerDeg': 150, 'grain': 0},
        'glyphs': provenance,
    }
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (args.output / 'preview.svg').write_text(preview(glyphs))
    print(f'Wrote 16 extracted and 2 reconstructed glyphs to {args.output}')


if __name__ == '__main__':
    main()
