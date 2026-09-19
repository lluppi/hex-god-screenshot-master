//! Bitmap text for the loupe badge and the dimension badge. The glyphs come
//! from `font_data.zig`, baked from a monospace TTF by `tools/gen-font.py`, so
//! both frontends draw identical text with no font loading and no dependencies.

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
                const row: u32 = @intCast((@as(u64, @intCast(dy)) * data.cell_height) / @as(u64, @intCast(cell_h)));
                const bits = glyph.rows[row];
                var dx: i32 = 0;
                while (dx < cell_w) : (dx += 1) {
                    const column: u32 = @intCast((@as(u64, @intCast(dx)) * data.cell_width) / @as(u64, @intCast(cell_w)));
                    const mask: u8 = @as(u8, 1) << @intCast(data.cell_width - 1 - column);
                    if (bits & mask != 0) canvas.blend(pen + dx, y + dy, pixel);
                }
            }
        }
        pen += cell_w;
    }
}
