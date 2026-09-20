//! Bitmap text for the loupe badge and the dimension badge.
//!
//! The glyph masks in `font_data.zig` are baked by `scripts/gen-font.py` at
//! `supersample` times the cell size they are drawn at. Drawing box filters the
//! mask down to the requested size, so every stroke gets a proportional
//! anti-aliased edge. Scaling a 1x ink mask with nearest neighbour - what this
//! did before - gives each stroke a different width whenever the scale is not a
//! whole number, which is what made the text look jagged.

const std = @import("std");
const data = @import("font_data.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");

const Canvas = canvas_mod.Canvas;

/// Advance width of one glyph cell at the given scale, in pixels.
pub fn advance(scale: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(data.cell_width)) * scale))));
}

pub fn cellHeight(scale: f64) i32 {
    return @max(
        1,
        @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(data.cell_height)) * scale))),
    );
}

pub fn textWidth(text: []const u8, scale: f64) i32 {
    return advance(scale) * @as(i32, @intCast(text.len));
}

/// Draw `text` with its top-left corner at (x, y). Unknown characters render as
/// blanks, which keeps the badges from ever looking broken.
pub fn draw(
    canvas: *Canvas,
    x: i32,
    y: i32,
    text: []const u8,
    scale: f64,
    pixel: u32,
) void {
    const cell_w = advance(scale);
    const cell_h = cellHeight(scale);
    var pen = x;
    for (text) |char| {
        if (data.find(char)) |glyph| {
            var dy: i32 = 0;
            while (dy < cell_h) : (dy += 1) {
                var dx: i32 = 0;
                while (dx < cell_w) : (dx += 1) {
                    const ink = coverage(glyph, dx, dy, cell_w, cell_h);
                    if (ink <= 0) continue;
                    canvas.blendCoverage(pen + dx, y + dy, pixel, ink);
                }
            }
        }
        pen += cell_w;
    }
}

/// How much of the destination pixel at (dx, dy) inside a `cell_w` x `cell_h`
/// cell is covered by ink, box filtering the supersampled mask: the mask
/// rectangle the pixel maps onto is summed, each sample weighted by how much of
/// it actually overlaps.
fn coverage(glyph: *const data.Glyph, dx: i32, dy: i32, cell_w: i32, cell_h: i32) f64 {
    const mask_w: f64 = @floatFromInt(data.mask_width);
    const mask_h: f64 = @floatFromInt(data.mask_height);
    const width: f64 = @floatFromInt(cell_w);
    const height: f64 = @floatFromInt(cell_h);

    const left = @as(f64, @floatFromInt(dx)) * mask_w / width;
    const right = @as(f64, @floatFromInt(dx + 1)) * mask_w / width;
    const top = @as(f64, @floatFromInt(dy)) * mask_h / height;
    const bottom = @as(f64, @floatFromInt(dy + 1)) * mask_h / height;

    var ink: f64 = 0;
    var sample_y: i32 = @intFromFloat(@floor(top));
    const last_y: i32 = @intFromFloat(@ceil(bottom));
    while (sample_y < last_y) : (sample_y += 1) {
        if (sample_y < 0 or sample_y >= data.mask_height) continue;
        const span_y = @min(bottom, @as(f64, @floatFromInt(sample_y + 1))) -
            @max(top, @as(f64, @floatFromInt(sample_y)));
        if (span_y <= 0) continue;

        const row = glyph.rows[@intCast(sample_y)];
        var sample_x: i32 = @intFromFloat(@floor(left));
        const last_x: i32 = @intFromFloat(@ceil(right));
        while (sample_x < last_x) : (sample_x += 1) {
            if (sample_x < 0 or sample_x >= data.mask_width) continue;
            const span_x = @min(right, @as(f64, @floatFromInt(sample_x + 1))) -
                @max(left, @as(f64, @floatFromInt(sample_x)));
            if (span_x <= 0) continue;
            const shift: u5 = @intCast(@as(i64, data.mask_width) - 1 - sample_x);
            if (row >> shift & 1 != 0) ink += span_x * span_y;
        }
    }

    return ink / ((right - left) * (bottom - top));
}
