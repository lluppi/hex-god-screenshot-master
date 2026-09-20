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
//!   1. baseline, lightly dimmed
//!   2. undimmed baseline, clipped to the selection, plus a difference edge
//!   3. the selection size readout
//!   4. the pixel scope, which the frontend draws separately on top

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
    /// Where the cursor is, used to place the endpoint instrument.
    cursor: ?Point = null,
    /// Live physical-pixel sample around the drag endpoint.
    endpoint_sample: ?Canvas = null,
    /// Physical pixels per logical pixel, so the readouts keep their apparent
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
    paintSizeBadge(canvas, scene, selection, region);
    const edge: i32 = @max(1, @as(i32, @intFromFloat(@round(scene.ui_scale))));
    paintDifferenceFrame(canvas, selection, region, edge);
}

fn paintDifferenceFrame(canvas: *Canvas, rect: Rect, region: Rect, thickness: i32) void {
    const edge = @min(thickness, @min(rect.w, rect.h));
    if (edge <= 0) return;

    paintDifferenceRect(canvas, (Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = edge }).intersection(region));
    if (rect.h > edge) {
        paintDifferenceRect(canvas, (Rect{ .x = rect.x, .y = rect.maxY() - edge, .w = rect.w, .h = edge }).intersection(region));
    }

    const middle_height = rect.h - 2 * edge;
    if (middle_height <= 0) return;
    paintDifferenceRect(canvas, (Rect{ .x = rect.x, .y = rect.y + edge, .w = edge, .h = middle_height }).intersection(region));
    if (rect.w > edge) {
        paintDifferenceRect(canvas, (Rect{ .x = rect.maxX() - edge, .y = rect.y + edge, .w = edge, .h = middle_height }).intersection(region));
    }
}

fn paintDifferenceRect(canvas: *Canvas, rect: Rect) void {
    var y = rect.y;
    while (y < rect.maxY()) : (y += 1) {
        var x = rect.x;
        while (x < rect.maxX()) : (x += 1) {
            const pixel = canvas.get(x, y) orelse continue;
            canvas.set(x, y, differenceInk(pixel));
        }
    }
}

fn differenceInk(pixel: u32) u32 {
    const rgb = color.rgbOf(pixel);
    const luma = @as(u32, rgb.r) * 299 + @as(u32, rgb.g) * 587 + @as(u32, rgb.b) * 114;
    const inverse_delta = if (luma >= 127_500) 2 * luma - 255_000 else 255_000 - 2 * luma;

    // Mid-greys barely move when inverted, so snap only that dead zone to the
    // higher-contrast neutral. Everywhere else keeps a true difference colour.
    if (inverse_delta < 64_000) {
        return if (luma >= 127_500)
            color.solid(.{ .r = 0x00, .g = 0x00, .b = 0x00 })
        else
            color.solid(.{ .r = 0xff, .g = 0xff, .b = 0xff });
    }
    return color.solid(.{ .r = 0xff - rgb.r, .g = 0xff - rgb.g, .b = 0xff - rgb.b });
}

/// The endpoint instrument: dimensions plus an optional external pixel scope.
pub const SizeBadge = struct {
    rect: Rect,
    scope: ?Rect = null,
    scope_column: u32 = 0,
    scope_row: u32 = 0,
    text_scale: f64 = 1,
    text: [32]u8,
    len: usize,

    /// Borrow the label. Takes a pointer on purpose: a by-value receiver would
    /// return a slice into a parameter that dies with the call.
    pub fn label(self: *const SizeBadge) []const u8 {
        return self.text[0..self.len];
    }

    pub fn bounds(self: *const SizeBadge) Rect {
        return if (self.scope) |scope|
            self.rect.unionWith(magnifier.endpointBounds(scope, self.scope_column, self.scope_row))
        else
            self.rect;
    }
};

/// Geometry of the endpoint instrument in canvas pixels. When the external
/// L-shaped scope fits, the dimensions span its six-cell width above or below;
/// near screen edges they fall back to a floating plate.
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

    const readout_scale = ui_scale * 0.85;
    const metrics = badge_mod.metrics(text, readout_scale);
    const scope_side: i32 = @intFromFloat(@round(magnifier.endpoint_scope_size * ui_scale));
    const anchor_x: i32 = @intFromFloat(@floor(cursor.x));
    const anchor_y: i32 = @intFromFloat(@floor(cursor.y));

    const active_right = anchor_x >= selection.x + @divTrunc(selection.w, 2);
    const active_bottom = anchor_y >= selection.y + @divTrunc(selection.h, 2);
    const corner_x = if (active_right) selection.maxX() else selection.x;
    const corner_y = if (active_bottom) selection.maxY() else selection.y;

    const cluster = Rect{
        .x = corner_x - scope_side,
        .y = corner_y - scope_side,
        .w = scope_side * 2,
        .h = scope_side * 2,
    };
    const attached_badge = Rect{
        .x = cluster.x,
        .y = if (active_bottom) cluster.maxY() else cluster.y - metrics.height,
        .w = cluster.w,
        .h = metrics.height,
    };
    const attached_bounds = cluster.unionWith(attached_badge);
    const cluster_fits = attached_bounds.x >= canvas.x and attached_bounds.y >= canvas.y and
        attached_bounds.maxX() <= canvas.maxX() and attached_bounds.maxY() <= canvas.maxY();

    var badge_rect: Rect = undefined;
    var scope_rect: ?Rect = null;
    var scope_column: u32 = 0;
    var scope_row: u32 = 0;
    var text_scale = readout_scale;
    if (cluster_fits) {
        badge_rect = attached_badge;
        const inset: i32 = @max(1, @as(i32, @intFromFloat(@round(2 * readout_scale))));
        const available = @max(1, attached_badge.w - 2 * inset);
        const text_width = @max(1, metrics.width - 2 * metrics.padding_x);
        if (text_width > available) {
            text_scale *= @as(f64, @floatFromInt(available)) / @as(f64, @floatFromInt(text_width));
        }
        scope_rect = .{
            .x = if (active_right) corner_x else corner_x - scope_side,
            .y = if (active_bottom) corner_y else corner_y - scope_side,
            .w = scope_side,
            .h = scope_side,
        };
        scope_column = if (active_right) 0 else magnifier.endpoint_sample_side - 1;
        scope_row = if (active_bottom) 0 else magnifier.endpoint_sample_side - 1;
    } else {
        const offset: i32 = @intFromFloat(@round(8 * ui_scale));
        const margin: i32 = @intFromFloat(@round(8 * ui_scale));
        badge_rect = .{
            .x = std.math.clamp(anchor_x + offset, margin, @max(margin, canvas.w - metrics.width - margin)),
            .y = std.math.clamp(anchor_y + offset, margin, @max(margin, canvas.h - metrics.height - margin)),
            .w = metrics.width,
            .h = metrics.height,
        };
    }

    var badge = SizeBadge{
        .rect = badge_rect,
        .scope = scope_rect,
        .scope_column = scope_column,
        .scope_row = scope_row,
        .text_scale = text_scale,
        .text = undefined,
        .len = text.len,
    };
    @memcpy(badge.text[0..text.len], text);
    return badge;
}

fn paintSizeBadge(canvas: *Canvas, scene: Scene, selection: Rect, region: Rect) void {
    const cursor = scene.cursor orelse return;
    const endpoint = sizeBadge(selection, cursor, scene.ui_scale, canvas.rect()) orelse return;
    if (!endpoint.bounds().intersects(region)) return;
    if (endpoint.scope) |scope| {
        if (scene.endpoint_sample) |sample| {
            magnifier.renderEndpoint(
                canvas,
                scope,
                sample,
                scene.ui_scale,
                endpoint.scope_column,
                endpoint.scope_row,
            );
        }
    }
    badge_mod.draw(canvas, endpoint.rect, endpoint.label(), endpoint.text_scale);
}

/// Draw the loupe on top of the overlay content.
pub fn renderMagnifier(canvas: *Canvas, origin: Point, sample: Canvas, ui_scale: f64) void {
    const window = magnifier.windowRect(origin, ui_scale);
    canvas.setClip(window);
    defer canvas.clearClip();
    magnifier.render(canvas, origin, sample, ui_scale);
}
