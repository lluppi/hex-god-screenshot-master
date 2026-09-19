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
const badge_mod = @import("badge.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
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
    if (scene.selection) |selection| paintSelection(canvas, scene, selection, region);
}

fn paintBaseline(canvas: *Canvas, scene: Scene, region: Rect) void {
    canvas.copyFrom(scene.baseline.*, region);
    canvas.dim(region, color.dim_numerator);
}

fn paintSelection(canvas: *Canvas, scene: Scene, selection: Rect, region: Rect) void {
    if (!selection.intersects(region)) return;
    // Undimmed content inside the selection, so the user sees exactly what will
    // be captured.
    canvas.copyFrom(scene.baseline.*, selection.intersection(region));
    canvas.strokeRect(
        selection,
        @max(1, @as(i32, @intFromFloat(@round(scene.ui_scale)))),
        color.solid(.{ .r = 255, .g = 255, .b = 255 }),
    );
    paintSizeBadge(canvas, scene, selection, region);
}

/// The "W x H" pill that follows the cursor while dragging.
pub const SizeBadge = struct {
    rect: Rect,
    text: [32]u8,
    len: usize,

    /// Borrow the label. Takes a pointer on purpose: a by-value receiver would
    /// return a slice into a parameter that dies with the call.
    pub fn label(self: *const SizeBadge) []const u8 {
        return self.text[0..self.len];
    }
};

/// Geometry of the size pill for a selection, in canvas pixels. Frontends use
/// this both to draw it and to damage the area it occupies, which is outside the
/// selection rectangle and therefore easy to forget.
pub fn sizeBadge(
    selection: Rect,
    cursor: Point,
    ui_scale: f64,
    canvas: Rect,
) ?SizeBadge {
    if (selection.w < 2 and selection.h < 2) return null;

    var text_buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_buffer,
        "{d}\xd7{d}",
        .{ selection.w, selection.h },
    ) catch return null;

    const metrics = badge_mod.metrics(text, ui_scale);

    const offset: i32 = @intFromFloat(@round(14 * ui_scale));
    const margin: i32 = @intFromFloat(@round(8 * ui_scale));
    const anchor_x: i32 = @intFromFloat(@floor(cursor.x));
    const anchor_y: i32 = @intFromFloat(@floor(cursor.y));
    const origin_x = std.math.clamp(
        anchor_x + offset,
        margin,
        @max(margin, canvas.w - metrics.width - margin),
    );
    const origin_y = std.math.clamp(
        anchor_y + offset,
        margin,
        @max(margin, canvas.h - metrics.height - margin),
    );

    var badge = SizeBadge{
        .rect = .{ .x = origin_x, .y = origin_y, .w = metrics.width, .h = metrics.height },
        .text = undefined,
        .len = text.len,
    };
    @memcpy(badge.text[0..text.len], text);
    return badge;
}

fn paintSizeBadge(canvas: *Canvas, scene: Scene, selection: Rect, region: Rect) void {
    const cursor = scene.cursor orelse return;
    const badge = sizeBadge(selection, cursor, scene.ui_scale, canvas.rect()) orelse return;
    if (!badge.rect.intersects(region)) return;
    badge_mod.draw(canvas, badge.rect, badge.label(), scene.ui_scale);
}

/// Draw the loupe on top of the overlay content.
pub fn renderMagnifier(canvas: *Canvas, origin: Point, sample: Canvas, ui_scale: f64) void {
    const window = magnifier.windowRect(origin, ui_scale);
    canvas.setClip(window);
    defer canvas.clearClip();
    magnifier.render(canvas, origin, sample, ui_scale);
}
