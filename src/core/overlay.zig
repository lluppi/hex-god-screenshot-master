//! Compositor for the full-screen selection overlay, shared by both frontends.
//!
//! The frontends hand us a `baseline`: a snapshot of the whole screen in
//! physical pixels, taken the moment the overlay appeared. Everything the
//! overlay draws is derived from that snapshot plus the live gesture state, and
//! is confined to the dirty region the caller names. That confinement matters:
//! the overlay is double buffered, and a pixel written outside the region the
//! compositor is told about stays stale forever in the other buffer.
//!
//! Layering inside a region:
//!   1. baseline, dimmed 4% (the mac app's `.black.withAlphaComponent(0.04)`)
//!   2. undimmed baseline, clipped to the selection, plus a 1px white border
//!   3. the selection size badge
//!   4. the loupe, which the frontend draws separately on top

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const font = @import("font.zig");
const geom = @import("geom.zig");
const magnifier = @import("magnifier.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const Point = geom.Point;

/// Everything the overlay needs to know about the gesture.
pub const Scene = struct {
    /// Full screen snapshot, physical pixels, sharing the canvas coordinate
    /// space.
    baseline: *const Canvas,
    /// Physical-pixel selection, if the user is dragging.
    selection: ?Rect = null,
    /// Where the cursor is, used to place the size badge.
    cursor: ?Point = null,
    /// Physical pixels per logical pixel, so the badges keep their apparent
    /// size on scaled displays.
    ui_scale: f64 = 1,
};

/// Repaint `region`, combining the scene layers. The caller is responsible for
/// clearing the canvas outside this or using a persistent canvas.
pub fn renderRegion(canvas: *Canvas, scene: Scene, region: Rect) void {
    canvas.setClip(region);
    defer canvas.clearClip();

    paintBaseline(canvas, scene, region);
    if (scene.selection) |selection| paintSelection(canvas, scene, selection, region, scene.ui_scale);
}

fn paintBaseline(canvas: *Canvas, scene: Scene, region: Rect) void {
    canvas.copyFrom(scene.baseline.*, region);
    canvas.dim(region, color.dim_numerator);
}

fn paintSelection(
    canvas: *Canvas,
    scene: Scene,
    selection: Rect,
    region: Rect,
    ui_scale: f64,
) void {
    if (!selection.intersects(region)) return;
    // Undimmed content inside the selection, so the user sees exactly what will
    // be captured.
    canvas.copyFrom(scene.baseline.*, selection.intersection(region));
    canvas.strokeRect(
        selection,
        @max(1, @as(i32, @intFromFloat(@round(ui_scale)))),
        color.solid(.{ .r = 255, .g = 255, .b = 255 }),
    );
    paintSizeBadge(canvas, scene, selection, region, ui_scale);
}

/// "W x H px" pill placed just below the cursor, clamped into the region.
fn paintSizeBadge(
    canvas: *Canvas,
    scene: Scene,
    selection: Rect,
    region: Rect,
    ui_scale: f64,
) void {
    const cursor = scene.cursor orelse return;
    if (selection.w < 2 and selection.h < 2) return;

    const padding_x: i32 = @intFromFloat(@round(7 * ui_scale));
    const padding_y: i32 = @intFromFloat(@round(4 * ui_scale));
    var text_buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_buffer,
        "{d}\xd7{d} px",
        .{ selection.w, selection.h },
    ) catch return;
    const text_w = font.textWidth(text, ui_scale);
    const text_h = font.cellHeight(ui_scale);
    const badge_w = text_w + 2 * padding_x;
    const badge_h = text_h + 2 * padding_y;

    const offset: i32 = @intFromFloat(@round(14 * ui_scale));
    const margin: i32 = @intFromFloat(@round(8 * ui_scale));
    const anchor_x: i32 = @intFromFloat(@floor(cursor.x));
    const anchor_y: i32 = @intFromFloat(@floor(cursor.y));
    const origin_x = std.math.clamp(
        anchor_x + offset,
        margin,
        @as(i32, @intCast(canvas.width)) - badge_w - margin,
    );
    const origin_y = std.math.clamp(
        anchor_y + offset,
        margin,
        @as(i32, @intCast(canvas.height)) - badge_h - margin,
    );
    const badge = Rect{ .x = origin_x, .y = origin_y, .w = badge_w, .h = badge_h };
    if (!badge.intersects(region)) return;

    canvas.fillRoundedRect(badge, 5 * ui_scale, color.black(209));
    font.draw(canvas, badge.x + padding_x, badge.y + padding_y, text, ui_scale, color.solid(.{ .r = 255, .g = 255, .b = 255 }));
}

/// Region of the canvas the loupe touches, so frontends can damage and repaint
/// exactly that much.
pub fn magnifierRegion(origin: Point, ui_scale: f64) Rect {
    return magnifier.windowRect(origin, ui_scale);
}

/// Draw the loupe on top of the overlay content.
pub fn renderMagnifier(canvas: *Canvas, origin: Point, sample: Canvas, ui_scale: f64) void {
    const window = magnifier.windowRect(origin, ui_scale);
    canvas.setClip(window);
    defer canvas.clearClip();
    magnifier.render(canvas, origin, sample, ui_scale);
}
