//! Bitmap text for the loupe badge and the dimension badge.
//!
//! The glyph masks in `font_data.bin` are baked by `scripts/gen-font.py` at
//! `supersample` times the cell size they are drawn at, one byte of area
//! coverage per sample. Drawing resamples that mask onto the destination grid:
//! each destination pixel maps to a rectangle of the mask and takes the exact
//! area-weighted mean of the samples it covers, or a bilinear read when the
//! rectangle is smaller than one sample. Glyphs advance by a fractional pen so
//! spacing stays even at any scale, and edge pixels are blended in linear light
//! so the ramps read as ramps rather than beading.

const data = @import("font_data.zig");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;

const mask_w: f64 = @floatFromInt(data.mask_width);
const mask_h: f64 = @floatFromInt(data.mask_height);

/// Advance width of one glyph cell at the given scale, in pixels. Fractional
/// on purpose: rounding it would drift the text off-centre at odd scales.
pub fn advance(scale: f64) f64 {
    return @as(f64, @floatFromInt(data.cell_width)) * scale;
}

pub fn cellHeight(scale: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(data.cell_height)) * scale))));
}

pub fn textWidth(text: []const u8, scale: f64) i32 {
    return @intFromFloat(@ceil(advance(scale) * @as(f64, @floatFromInt(text.len))));
}

/// Draw `text` with its top-left corner at (x, y). Unknown characters render as
/// blanks, which keeps the badges from ever looking broken.
pub fn draw(canvas: *Canvas, x: i32, y: i32, text: []const u8, scale: f64, pixel: u32) void {
    const cell_w = advance(scale);
    const cell_h = @as(f64, @floatFromInt(data.cell_height)) * scale;
    const top: f64 = @floatFromInt(y);
    const first_row = y;
    const last_row: i32 = @intFromFloat(@ceil(top + cell_h));

    var pen: f64 = @floatFromInt(x);
    for (text) |char| {
        defer pen += cell_w;
        const glyph = data.find(char) orelse continue;
        const first_col: i32 = @intFromFloat(@floor(pen));
        const last_col: i32 = @intFromFloat(@ceil(pen + cell_w));

        var row = first_row;
        while (row < last_row) : (row += 1) {
            const py: f64 = @floatFromInt(row);
            const t = (py - top) * mask_h / cell_h;
            const b = (py + 1 - top) * mask_h / cell_h;
            var col = first_col;
            while (col < last_col) : (col += 1) {
                const px: f64 = @floatFromInt(col);
                const l = (px - pen) * mask_w / cell_w;
                const r = (px + 1 - pen) * mask_w / cell_w;
                const ink = coverage(glyph, l, r, t, b);
                if (ink <= 0) continue;
                canvas.blendCoverageLinear(col, row, pixel, ink);
            }
        }
    }
}

/// Mean coverage of the mask over the rectangle [l, r) x [t, b) in mask
/// sample units. Area-weighted when the rectangle spans at least one sample on
/// both axes, bilinear at its centre otherwise, so magnified text keeps smooth
/// ramps instead of stepping sample by sample.
fn coverage(glyph: *const [data.glyph_bytes]u8, l: f64, r: f64, t: f64, b: f64) f64 {
    if (r - l < 1 or b - t < 1) return bilinear(glyph, (l + r) / 2, (t + b) / 2);

    var ink: f64 = 0;
    var sy: i32 = @intFromFloat(@floor(t));
    const end_y: i32 = @intFromFloat(@ceil(b));
    while (sy < end_y) : (sy += 1) {
        if (sy < 0 or sy >= data.mask_height) continue;
        const fy: f64 = @floatFromInt(sy);
        const span_y = @min(b, fy + 1) - @max(t, fy);
        if (span_y <= 0) continue;
        const row = glyph[@as(usize, @intCast(sy)) * data.mask_width ..][0..data.mask_width];

        var sx: i32 = @intFromFloat(@floor(l));
        const end_x: i32 = @intFromFloat(@ceil(r));
        while (sx < end_x) : (sx += 1) {
            if (sx < 0 or sx >= data.mask_width) continue;
            const fx: f64 = @floatFromInt(sx);
            const span_x = @min(r, fx + 1) - @max(l, fx);
            if (span_x <= 0) continue;
            ink += span_x * span_y * @as(f64, @floatFromInt(row[@intCast(sx)]));
        }
    }
    return ink / (255.0 * (r - l) * (b - t));
}

/// Bilinear coverage at a mask position, samples centred on half-integers and
/// zero outside the mask.
fn bilinear(glyph: *const [data.glyph_bytes]u8, x: f64, y: f64) f64 {
    const gx = x - 0.5;
    const gy = y - 0.5;
    const x0: i32 = @intFromFloat(@floor(gx));
    const y0: i32 = @intFromFloat(@floor(gy));
    const fx = gx - @as(f64, @floatFromInt(x0));
    const fy = gy - @as(f64, @floatFromInt(y0));
    const top = sample(glyph, x0, y0) * (1 - fx) + sample(glyph, x0 + 1, y0) * fx;
    const bottom = sample(glyph, x0, y0 + 1) * (1 - fx) + sample(glyph, x0 + 1, y0 + 1) * fx;
    return (top * (1 - fy) + bottom * fy) / 255.0;
}

fn sample(glyph: *const [data.glyph_bytes]u8, x: i32, y: i32) f64 {
    if (x < 0 or y < 0 or x >= data.mask_width or y >= data.mask_height) return 0;
    return @floatFromInt(glyph[@as(usize, @intCast(y)) * data.mask_width + @as(usize, @intCast(x))]);
}
