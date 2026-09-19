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

/// Draw the whole loupe: body, scaled sample, grid, centre target, ring, badge.
pub fn render(canvas: *Canvas, origin: geom.Point, sample: Canvas, ui_scale: f64) void {
    const window = windowRect(origin, ui_scale);
    if (!window.intersects(canvas.rect())) return;

    const centre_x = @as(f64, @floatFromInt(window.x)) + cursor_inset * ui_scale;
    const centre_y = @as(f64, @floatFromInt(window.y)) + cursor_inset * ui_scale;

    canvas.fillCircle(centre_x, centre_y, ringRadius(ui_scale), color.solid(.{ .r = 0x1e, .g = 0x1e, .b = 0x1e }));
    drawSample(canvas, window, sample, ui_scale);
    drawGrid(canvas, window, ui_scale);
    drawTarget(canvas, window, ui_scale);
    drawRing(canvas, centre_x, centre_y, ui_scale);
    drawHexBadge(canvas, window, sample, ui_scale);
}

fn drawSample(canvas: *Canvas, window: Rect, sample: Canvas, ui_scale: f64) void {
    if (sample.width == 0 or sample.height == 0) return;
    const diameter: i32 = @intFromFloat(@round(circle_diameter * ui_scale));
    const left = window.x + @as(i32, @intFromFloat(@round(cursor_inset * ui_scale))) - @divTrunc(diameter, 2);
    const top = window.y + @as(i32, @intFromFloat(@round(cursor_inset * ui_scale))) - @divTrunc(diameter, 2);
    const centre_x = @as(f64, @floatFromInt(left)) + @as(f64, @floatFromInt(diameter)) / 2.0;
    const centre_y = @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(diameter)) / 2.0;
    const radius2 = ringRadius(ui_scale) * ringRadius(ui_scale);

    var dy: i32 = 0;
    while (dy < diameter) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < diameter) : (dx += 1) {
            const px = @as(f64, @floatFromInt(left + dx)) + 0.5 - centre_x;
            const py = @as(f64, @floatFromInt(top + dy)) + 0.5 - centre_y;
            if (px * px + py * py > radius2) continue;
            const sx: u32 = @intCast(@as(u64, @intCast(dx)) * sample.width / @as(u64, @intCast(diameter)));
            const sy: u32 = @intCast(@as(u64, @intCast(dy)) * sample.height / @as(u64, @intCast(diameter)));
            const pixel = sample.get(@intCast(@min(sx, sample.width - 1)), @intCast(@min(sy, sample.height - 1))) orelse continue;
            canvas.set(left + dx, top + dy, pixel);
        }
    }
}

/// Faint cell boundaries, one per sampled pixel.
fn drawGrid(canvas: *Canvas, window: Rect, ui_scale: f64) void {
    const diameter: i32 = @intFromFloat(@round(circle_diameter * ui_scale));
    const inset: i32 = @intFromFloat(@round(cursor_inset * ui_scale));
    const left = window.x + inset - @divTrunc(diameter, 2);
    const top = window.y + inset - @divTrunc(diameter, 2);
    const line = color.black(40);
    var step: i32 = 1;
    while (step < sample_side) : (step += 1) {
        const offset: i32 = @intCast(@as(u64, @intCast(step)) * @as(u64, @intCast(diameter)) / sample_side);
        var i: i32 = 0;
        while (i < diameter) : (i += 1) {
            canvas.blend(left + offset, top + i, line);
            canvas.blend(left + i, top + offset, line);
        }
    }
}

/// The square highlighting the pixel under the cursor.
fn drawTarget(canvas: *Canvas, window: Rect, ui_scale: f64) void {
    const diameter: i32 = @intFromFloat(@round(circle_diameter * ui_scale));
    const inset: i32 = @intFromFloat(@round(cursor_inset * ui_scale));
    const left = window.x + inset - @divTrunc(diameter, 2);
    const top = window.y + inset - @divTrunc(diameter, 2);
    const cell: i32 = @intCast(@as(u64, @intCast(diameter)) / sample_side);
    const centre: i32 = @intCast(@as(u64, sample_side / 2) * @as(u64, @intCast(diameter)) / sample_side);
    const rect = Rect{ .x = left + centre, .y = top + centre, .w = cell, .h = cell };
    const outline: i32 = @max(1, @as(i32, @intFromFloat(@round(2 * ui_scale))));
    canvas.strokeRect(rect.expand(outline), outline * 2, color.solid(.{ .r = 0, .g = 0, .b = 0 }));
    canvas.strokeRect(rect, outline, color.solid(.{ .r = 255, .g = 255, .b = 255 }));
}

fn drawRing(canvas: *Canvas, centre_x: f64, centre_y: f64, ui_scale: f64) void {
    const radius = ringRadius(ui_scale);
    canvas.strokeCircle(centre_x, centre_y, radius, 1.25 * ui_scale, color.solid(.{ .r = 255, .g = 255, .b = 255 }));
    canvas.strokeCircle(centre_x, centre_y, radius - ui_scale, ui_scale, color.black(184));
}

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
