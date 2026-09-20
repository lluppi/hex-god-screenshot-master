# Specimen glyphs

18 standalone SVGs: `0.svg`–`9.svg`, `A.svg`–`F.svg`, `hash.svg`, `times.svg`.
Open `preview.svg` for the set, sample labels and small-size previews.

- Digits and letters are traced from `glyphs.png`; `#` and `×` are drawn to match.
- Shared `viewBox="0 0 29 44"` and 29-unit advance; no per-glyph stretching.
- Filled vector outlines use `currentColor`; counters use even-odd filling.
- Tracing preserves clipped corners, adds no grain and bounds curve overshoot.
- `manifest.json` records source checksum, crops and reconstructed symbols.

Regenerate from the original 1214×761 image with Pillow, Bun and trace-god:

```sh
python3 tools/extract-font.py ~/Downloads/glyphs.png ../trace-god assets/font
```

These SVGs are the app font's source: `tools/gen-font.py` rasterises them into
`src/core/font_data.zig`. Re-run both when the glyphs change. Source font
licensing is unknown: confirm permission before distributing derived glyphs.
