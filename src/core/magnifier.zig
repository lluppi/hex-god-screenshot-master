//! The circular loupe and its live hex badge. A port of the original AppKit
//! `MagnifierView`, except that the drawing is done by hand so the identical
//! pixels come out on Wayland and on macOS.
//!
//! All measurements are the original AppKit point values multiplied by
//! `ui_scale`, the physical pixels per logical pixel of the output being drawn
//! on, so the loupe looks the same size on a 1x and a 1.25x display. The sample
//! itself is always 21 *physical* pixels, which is what makes the centre of the
//! loupe the exact pixel under the cursor.
//!
//! Coordinates here are y-down (screen convention), so this is the Swift view
//! flipped.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const font = @import("font.zig");
const geom = @import("geom.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;

pub const window_width: f64 = 116;
pub const window_height: f64 = 145;
pub const circle_diameter: f64 = 110;
/// Distance from the window's top-left corner to the cursor: the loupe centre.
pub const cursor_inset: f64 = 58;

/// Physical pixels sampled around the cursor: the loupe is 110px wide, so a
/// 21x21 sample gives roughly 5 screen pixels per loupe pixel at 1x.
pub const sample_side: u32 = 21;

pub fn ringRadius(ui_scale: f64) f64 {
    return circle_diameter * ui_scale / 2.0;
}

/// Top-left corner of the magnifier window for a cursor at `point`.
pub fn windowOrigin(cursor: geom.Point, ui_scale: f64) geom.Point {
    return .{
        .x = cursor.x - cursor_inset * ui_scale,
        .y = cursor.y - cursor_inset * ui_scale,
    };
}

/// The colour under the cursor: the centre pixel of the sample.
pub fn hexAt(sample: Canvas) ?color.Rgb {
    if (sample.width == 0 or sample.height == 0) return null;
    const x: i32 = @intCast(sample.width / 2);
    const y: i32 = @intCast(sample.height / 2);
    const pixel = sample.get(x, y) orelse return null;
    return color.rgbOf(pixel);
}

pub fn windowRect(origin: geom.Point, ui_scale: f64) Rect {
    return .{
        .x = @as(i32, @intFromFloat(@floor(origin.x))),
        .y = @as(i32, @intFromFloat(@floor(origin.y))),
        .w = @intFromFloat(@round(window_width * ui_scale)),
        .h = @intFromFloat(@round(window_height * ui_scale)),
    };
}

/// Everything inside the disc for one pixel: the magnified sample, the cell
/// grid and the centre target, stacked.
const Disc = struct {
    sample: Canvas,
    /// Canvas coordinates of the disc's bounding square.
    left: i32,
    top: i32,
    diameter: i32,
    /// Grid line positions, in pixels from the bounding square's edge.
    grid: [sample_side]i32,
    target: Rect,
    target_outline: i32,

    const body_colour = color.solid(.{ .r = 0x1e, .g = 0x1e, .b = 0x1e });
    const grid_ink = color.black(40);
    const target_ink = color.solid(.{ .r = 0, .g = 0, .b = 0 });
    const target_highlight = color.solid(.{ .r = 255, .g = 255, .b = 255 });

    /// The composited colour for a pixel `dx`, `dy` from the square's top left.
    fn pixelAt(self: Disc, dx: i32, dy: i32) u32 {
        var pixel = body_colour;
        if (self.sample.width > 0 and self.sample.height > 0) {
            if (dx >= 0 and dy >= 0 and dx < self.diameter and dy < self.diameter) {
                const sx: u32 = @intCast(@as(u64, @intCast(dx)) * self.sample.width / @as(u64, @intCast(self.diameter)));
                const sy: u32 = @intCast(@as(u64, @intCast(dy)) * self.sample.height / @as(u64, @intCast(self.diameter)));
                if (self.sample.get(@intCast(@min(sx, self.sample.width - 1)), @intCast(@min(sy, self.sample.height - 1)))) |sampled| {
                    pixel = sampled;
                }
            }
        }

        for (self.grid) |offset| {
            if (offset == 0) continue;
            if (dx == offset or dy == offset) pixel = color.over(pixel, grid_ink);
        }

        const x = self.left + dx;
        const y = self.top + dy;
        if (inStroke(x, y, self.target.expand(self.target_outline), self.target_outline * 2)) {
            pixel = color.over(pixel, target_ink);
        }
        if (inStroke(x, y, self.target, self.target_outline)) {
            pixel = color.over(pixel, target_highlight);
        }
        return pixel;
    }
};

/// True when (x, y) is in the `thickness` wide border of `rect`.
fn inStroke(x: i32, y: i32, rect: Rect, thickness: i32) bool {
    if (thickness <= 0) return false;
    if (x < rect.x or y < rect.y or x >= rect.maxX() or y >= rect.maxY()) return false;
    return x < rect.x + thickness or
        x >= rect.maxX() - thickness or
        y < rect.y + thickness or
        y >= rect.maxY() - thickness;
}

/// Draw the whole loupe: disc, ring, badge.
///
/// The disc is composited in a single pass, because the edge has to be
/// anti-aliased *after* every layer is stacked: filling the body anti-aliased
/// and then stamping the sample over it with a hard circular clip undoes the
/// edge, which is what left the circle looking rough. Grid lines are part of the
/// same pass and are clipped by the disc's coverage, so they cannot bleed into
/// the corners of the bounding square.
pub fn render(canvas: *Canvas, origin: geom.Point, sample: Canvas, ui_scale: f64) void {
    const window = windowRect(origin, ui_scale);
    if (!window.intersects(canvas.rect())) return;

    const radius = ringRadius(ui_scale);
    const inset: i32 = @intFromFloat(@round(cursor_inset * ui_scale));
    const diameter: i32 = @intFromFloat(@round(circle_diameter * ui_scale));
    const left = window.x + inset - @divTrunc(diameter, 2);
    const top = window.y + inset - @divTrunc(diameter, 2);
    const centre_x = @as(f64, @floatFromInt(left)) + @as(f64, @floatFromInt(diameter)) / 2.0;
    const centre_y = @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(diameter)) / 2.0;

    var grid: [sample_side]i32 = @splat(0);
    var step: i32 = 1;
    while (step < sample_side) : (step += 1) {
        grid[@intCast(step)] = @intCast(@as(u64, @intCast(step)) * @as(u64, @intCast(diameter)) / sample_side);
    }

    const cell: i32 = @intCast(@as(u64, @intCast(diameter)) / sample_side);
    const centre_cell: i32 = @intCast(@as(u64, sample_side / 2) * @as(u64, @intCast(diameter)) / sample_side);
    const disc = Disc{
        .sample = sample,
        .left = left,
        .top = top,
        .diameter = diameter,
        .grid = grid,
        .target = .{ .x = left + centre_cell, .y = top + centre_cell, .w = cell, .h = cell },
        .target_outline = @max(1, @as(i32, @intFromFloat(@round(2 * ui_scale)))),
    };

    // One pixel of margin so the outer half of the coverage ramp is covered.
    var dy: i32 = -1;
    while (dy <= diameter) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= diameter) : (dx += 1) {
            const px = @as(f64, @floatFromInt(left + dx)) + 0.5 - centre_x;
            const py = @as(f64, @floatFromInt(top + dy)) + 0.5 - centre_y;
            const coverage = std.math.clamp(radius - @sqrt(px * px + py * py) + 0.5, 0, 1);
            if (coverage <= 0) continue;
            canvas.blendCoverage(left + dx, top + dy, disc.pixelAt(dx, dy), coverage);
        }
    }

    drawRing(canvas, centre_x, centre_y, ui_scale);
    drawHexBadge(canvas, window, sample, ui_scale);
}

/// A white ring with a dark separator just inside it, so the ring reads against
/// both light and dark content underneath.
fn drawRing(canvas: *Canvas, centre_x: f64, centre_y: f64, ui_scale: f64) void {
    const radius = ringRadius(ui_scale);
    const thickness = ring_thickness * ui_scale;
    canvas.strokeCircleAA(centre_x, centre_y, radius, thickness, color.solid(.{ .r = 255, .g = 255, .b = 255 }));
    canvas.strokeCircleAA(centre_x, centre_y, radius - thickness, separator_thickness * ui_scale, color.black(184));
}

/// Ring width in points. Wider than a hairline on purpose: a ~1px curve has no
/// pixel area to anti-alias, so it reads as a stair-stepped line however good the
/// coverage maths is.
pub const ring_thickness: f64 = 2.0;
pub const separator_thickness: f64 = 1.0;

fn drawHexBadge(canvas: *Canvas, window: Rect, sample: Canvas, ui_scale: f64) void {
    const rgb = hexAt(sample) orelse return;
    const text = color.hexString(rgb);
    drawBadge(canvas, window, &text, ui_scale);
}

/// Rounded dark pill with white monospace text, horizontally centred in the
/// window and sitting near its bottom edge.
pub fn drawBadge(canvas: *Canvas, window: Rect, text: []const u8, ui_scale: f64) void {
    const padding_x: i32 = @intFromFloat(@round(7 * ui_scale));
    const padding_y: i32 = @intFromFloat(@round(4 * ui_scale));
    const text_w = font.textWidth(text, ui_scale);
    const text_h = font.cellHeight(ui_scale);
    const width: i32 = @intFromFloat(@round(window_width * ui_scale));
    const height: i32 = @intFromFloat(@round(window_height * ui_scale));
    const badge = Rect{
        .x = window.x + @divTrunc(width - text_w - 2 * padding_x, 2),
        .y = window.y + height - text_h - 2 * padding_y - @as(i32, @intFromFloat(@round(2 * ui_scale))),
        .w = text_w + 2 * padding_x,
        .h = text_h + 2 * padding_y,
    };
    canvas.fillRoundedRect(badge, 5 * ui_scale, color.black(209));
    font.draw(canvas, badge.x + padding_x, badge.y + padding_y, text, ui_scale, color.solid(.{ .r = 255, .g = 255, .b = 255 }));
}
