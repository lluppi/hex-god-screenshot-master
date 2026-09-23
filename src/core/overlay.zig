//! Compositor for the full-screen selection overlay, shared by every frontend.
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
    canvas.copyDimmedFrom(scene.baseline.*, region);
}

fn paintSelection(canvas: *Canvas, scene: Scene, selection: Rect, region: Rect) void {
    if (!selection.intersects(region)) return;
    // Undimmed content inside the selection, so the user sees exactly what will
    // be captured.
    canvas.copyFrom(scene.baseline.*, selection.intersection(region));
    paintSizeBadge(canvas, scene, selection, region);
    paintDifferenceFrame(canvas, selection, region, geom.px(scene.ui_scale, 1));
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

/// luma is 0..255000, so mid grey is half that. Around mid grey an inverted
/// colour barely moves, which is the one band where the difference edge needs a
/// higher-contrast neutral instead.
const luma_mid = 127_500;
const luma_full = 255_000;
const luma_dead_zone = 64_000;

/// The dimensions readout is drawn a touch smaller than the loupe's, so it reads
/// as a secondary instrument.
const readout_scale_factor: f64 = 0.85;

/// Where the floating fallback plate sits relative to the cursor, and how close
/// it may come to the screen edge, in points.
const fallback_offset_pt: f64 = 8;
const fallback_margin_pt: f64 = 8;

fn differenceInk(pixel: u32) u32 {
    const rgb = color.rgbOf(pixel);
    const luma = color.luma(rgb);
    const inverse_delta = if (luma >= luma_mid) 2 * luma - luma_full else luma_full - 2 * luma;

    if (inverse_delta < luma_dead_zone) {
        return color.solid(if (luma >= luma_mid) color.black_rgb else color.white);
    }
    return color.solid(.{ .r = 0xff - rgb.r, .g = 0xff - rgb.g, .b = 0xff - rgb.b });
}

/// The endpoint instrument's geometry: where the dimensions plate goes, and the
/// external pixel scope attached to the active corner when it fits.
pub const SizeBadge = struct {
    rect: Rect,
    text_scale: f64 = 1,
    scope: ?Rect = null,
    scope_column: u32 = 0,
    scope_row: u32 = 0,

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
    const text = std.fmt.bufPrint(&text_buffer, "{d}\xd7{d}", .{ selection.w, selection.h }) catch return null;
    const readout_scale = ui_scale * readout_scale_factor;
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
        const inset = geom.px(readout_scale, 2);
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
        const offset: i32 = @intFromFloat(@round(fallback_offset_pt * ui_scale));
        const margin: i32 = @intFromFloat(@round(fallback_margin_pt * ui_scale));
        badge_rect = .{
            .x = std.math.clamp(anchor_x + offset, margin, @max(margin, canvas.w - metrics.width - margin)),
            .y = std.math.clamp(anchor_y + offset, margin, @max(margin, canvas.h - metrics.height - margin)),
            .w = metrics.width,
            .h = metrics.height,
        };
    }

    return .{
        .rect = badge_rect,
        .text_scale = text_scale,
        .scope = scope_rect,
        .scope_column = scope_column,
        .scope_row = scope_row,
    };
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
    var text_buffer: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&text_buffer, "{d}\xd7{d}", .{ selection.w, selection.h }) catch return;
    badge_mod.draw(canvas, endpoint.rect, label, endpoint.text_scale);
}

/// Draw the loupe on top of the overlay content.
pub fn renderMagnifier(canvas: *Canvas, origin: Point, sample: Canvas, ui_scale: f64) void {
    const window = magnifier.windowRect(origin, ui_scale);
    canvas.setClip(window);
    defer canvas.clearClip();
    magnifier.render(canvas, origin, sample, ui_scale);
}
