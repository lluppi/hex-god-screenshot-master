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
const badge = @import("badge.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const geom = @import("geom.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;

/// Half-width, in device pixels, of the tent-shaped reconstruction filter that
/// every circular edge is drawn through.
///
/// Exact pixel-area coverage (a box filter) is what a ~1px curve looks ropey
/// under: where the stroke lands on one pixel column it renders at full white,
/// where it straddles two it renders as a pair at ~60%, and on the diagonal it
/// becomes a chain of single bright pixels. The total ink per unit of arc is
/// constant, but the *peak* jumps with the sub-pixel phase, and that beading is
/// what reads as jaggedness. Text and 2D renderers low-pass the coverage
/// with a filter wider than a pixel for exactly this reason (FreeType's LCD FIR
/// filter, Skia's two-pixel hairline ramps, the >1px kernels of film
/// renderers). A tent of this radius trades a little crispness for a stroke
/// whose brightness barely changes as it sweeps through the pixel grid.
const filter_radius: f64 = 1.0;

/// Fraction of the pixel filter that lies on the inside of a straight edge
/// passing `inside` pixels from the pixel centre (positive when the centre
/// itself is inside). This is the tent kernel's integral, so it is C1: no
/// kink where the ramp meets full or zero coverage.
fn edgeWeight(inside: f64) f64 {
    if (inside <= -filter_radius) return 0;
    if (inside >= filter_radius) return 1;
    const t = (inside + filter_radius) / (2 * filter_radius);
    return if (t < 0.5) 2 * t * t else 1 - 2 * (1 - t) * (1 - t);
}

/// Filtered coverage of the disc of `radius` for a pixel whose centre is `dist`
/// from the disc centre. The circle is treated as a straight edge across the
/// filter's support: with radii of 90px and up the arc sags less than 0.01px
/// over that span, far below one level of the 8-bit output.
fn discWeight(radius: f64, dist: f64) f64 {
    return edgeWeight(radius - dist);
}

/// Gap between the circle and the window edge on the left, right and top.
const margin: f64 = 3;
/// How far the window extends below the circle, where the hex badge sits.
const below_circle: f64 = 32;

pub const circle_diameter: f64 = 180;
pub const window_width: f64 = circle_diameter + 2 * margin;
pub const window_height: f64 = circle_diameter + margin + below_circle;
/// Distance from the window's top-left corner to the cursor: the loupe centre.
pub const cursor_inset: f64 = circle_diameter / 2 + margin;

/// Physical pixels sampled around the cursor. The circle is `circle_diameter`
/// wide, so a 13x13 sample gives roughly 14 loupe pixels per screen pixel at 1x.
/// Kept odd so the sample has a true centre pixel: that is the colour copied.
pub const sample_side: u32 = 13;

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
/// grid and the ring, stacked.
const Disc = struct {
    sample: Canvas,
    /// Canvas coordinates of the disc's bounding square.
    left: i32,
    top: i32,
    diameter: i32,
    /// Grid line positions, in pixels from the bounding square's edge.
    grid: [sample_side]i32,
    centre_x: f64,
    centre_y: f64,
    radius: f64,
    ring: f64,
    separator: f64,

    const body_colour = color.solid(.{ .r = 0x1e, .g = 0x1e, .b = 0x1e });
    const grid_ink = color.black(40);
    const ring_ink = color.solid(.{ .r = 255, .g = 255, .b = 255 });

    /// The composited colour for a pixel `dx`, `dy` from the square's top left,
    /// whose centre is `dist` from the disc centre and whose filtered disc
    /// coverage is `outer` (> 0).
    fn pixelAt(self: Disc, dx: i32, dy: i32, dist: f64, outer: f64) u32 {
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
            if (dx == offset or dy == offset) pixel = color.overLinear(pixel, grid_ink);
        }

        return self.withRing(pixel, dist, outer);
    }

    /// The ring is part of the same stack as everything else, so the silhouette
    /// is anti-aliased exactly once (see `render`). Only the ring's *inner*
    /// boundaries are softened here; its outer boundary is the disc's edge and
    /// belongs to the single coverage multiply at the end.
    fn withRing(self: Disc, base: u32, dist: f64, outer: f64) u32 {
        const ring_inner = self.radius - self.ring;
        const separator_inner = ring_inner - self.separator;
        // Everything inside the separator's inner edge, less the filter's
        // reach, is plain magnified content: the common case, so leave early.
        if (dist < separator_inner - filter_radius) return base;

        // The three bands are nested discs, so each band's weight is the
        // difference of two disc weights, all through the same filter.
        const white_inner = discWeight(ring_inner, dist);
        const separator_inner_weight = discWeight(separator_inner, dist);

        // Coverage is conditional on being inside the disc. The outer coverage
        // is applied once in `render`; conditioning here avoids multiplying the
        // same edge coverage twice where a thin ring meets the silhouette.
        const white = std.math.clamp((outer - white_inner) / outer, 0, 1);
        const separator = std.math.clamp((white_inner - separator_inner_weight) / outer, 0, 1);

        var pixel = base;
        // The bands are disjoint. Account for the white band's later src-over
        // coverage so the separator retains exactly its filtered weight instead
        // of being faded a second time beneath the white.
        if (separator > 0 and white < 1) {
            const separator_before_white = @min(1, separator / (1 - white));
            pixel = color.overLinear(pixel, color.withCoverage(grid_ink, separator_before_white));
        }
        if (white > 0) pixel = color.overLinear(pixel, color.withCoverage(ring_ink, white));
        return pixel;
    }
};

/// Draw the whole loupe: disc, ring, badge.
///
/// The disc is composited in a single pass, because the edge has to be
/// anti-aliased *after* every layer is stacked: filling the body anti-aliased
/// and then stamping the sample over it with a hard circular clip undoes the
/// edge, which is what left the circle looking rough. Grid lines are part of the
/// same pass and are clipped by the disc's coverage, so they cannot bleed into
/// the corners of the bounding square.
///
/// The ring is in that pass too. Stroking it as a separate anti-aliased circle
/// applied a second coverage ramp on top of the disc's, so the silhouette came
/// out as `2c - c^2` instead of `c`: a half-covered edge pixel was drawn at 75%
/// and the whole ramp collapsed into roughly one hard pixel. One stack, one
/// coverage multiply, one edge.
pub fn render(canvas: *Canvas, origin: geom.Point, sample: Canvas, ui_scale: f64) void {
    const window = windowRect(origin, ui_scale);
    if (!window.intersects(canvas.rect())) return;

    const radius = ringRadius(ui_scale);
    const inset: i32 = @intFromFloat(@round(cursor_inset * ui_scale));
    const diameter: i32 = @intFromFloat(@round(circle_diameter * ui_scale));
    const left = window.x + inset - @divTrunc(diameter, 2);
    const top = window.y + inset - @divTrunc(diameter, 2);
    // The centre sits at the centre of the cursor's pixel, not on its top-left
    // corner. Half a pixel sounds like nothing, but with an integer radius a
    // corner-centred circle puts all four of its extremes exactly on a pixel
    // boundary: the left and right flanks then have *no* partial pixel at all
    // for a dozen rows, so they read as a dead straight run that suddenly jogs
    // a whole pixel. Centred on the pixel, those flanks get a real half-covered
    // column instead. It also matches how the sample below is indexed, by pixel
    // centre, so the magnified content and the circle share one origin.
    const centre_x = @as(f64, @floatFromInt(left)) + @as(f64, @floatFromInt(diameter)) / 2.0 + 0.5;
    const centre_y = @as(f64, @floatFromInt(top)) + @as(f64, @floatFromInt(diameter)) / 2.0 + 0.5;

    // A cell boundary lands at `step * diameter / sample_side`; the first pixel
    // *of* the next cell is the one at or past it, so this rounds up. Rounding
    // down drew every grid line one pixel to the left of the cell it divides.
    var grid: [sample_side]i32 = @splat(0);
    var step: i32 = 1;
    while (step < sample_side) : (step += 1) {
        const scaled = @as(u64, @intCast(step)) * @as(u64, @intCast(diameter));
        grid[@intCast(step)] = @intCast((scaled + sample_side - 1) / sample_side);
    }

    const disc = Disc{
        .sample = sample,
        .left = left,
        .top = top,
        .diameter = diameter,
        .grid = grid,
        .centre_x = centre_x,
        .centre_y = centre_y,
        .radius = radius,
        .ring = ring_thickness * ui_scale,
        .separator = separator_thickness * ui_scale,
    };

    // Walk the radius rather than the rounded bounding square, with the
    // filter's reach plus a pixel of margin, so the outer half of the coverage
    // ramp is always inside the loop even when rounding leaves the square a
    // little tight or lopsided.
    const reach = radius + filter_radius + 1;
    const first_x: i32 = @as(i32, @intFromFloat(@floor(centre_x - reach))) - left;
    const last_x: i32 = @as(i32, @intFromFloat(@ceil(centre_x + reach))) - left;
    const first_y: i32 = @as(i32, @intFromFloat(@floor(centre_y - reach))) - top;
    const last_y: i32 = @as(i32, @intFromFloat(@ceil(centre_y + reach))) - top;

    var dy: i32 = first_y;
    while (dy <= last_y) : (dy += 1) {
        const py = @as(f64, @floatFromInt(top + dy)) + 0.5 - centre_y;
        var dx: i32 = first_x;
        while (dx <= last_x) : (dx += 1) {
            const px = @as(f64, @floatFromInt(left + dx)) + 0.5 - centre_x;
            const dist = @sqrt(px * px + py * py);
            const coverage = discWeight(radius, dist);
            if (coverage <= 0) continue;
            canvas.blendCoverageLinear(left + dx, top + dy, disc.pixelAt(dx, dy, dist, coverage), coverage);
        }
    }

    drawHexBadge(canvas, window, sample, ui_scale);
}

/// Ring width in points. Subpixel coverage keeps this hairline smooth at 1x
/// while higher-density displays naturally give it more physical pixels.
pub const ring_thickness: f64 = 1.0;
/// Inner separator uses the same ink and width as the sample grid.
pub const separator_thickness: f64 = 1.0;

fn drawHexBadge(canvas: *Canvas, window: Rect, sample: Canvas, ui_scale: f64) void {
    const rgb = hexAt(sample) orelse return;
    const text = color.hexString(rgb);
    drawBadge(canvas, window, &text, ui_scale);
}

/// Rounded dark pill with white monospace text, horizontally centred in the
/// window and sitting near its bottom edge.
fn drawBadge(canvas: *Canvas, window: Rect, text: []const u8, ui_scale: f64) void {
    const metrics = badge.metrics(text, ui_scale);
    const width: i32 = @intFromFloat(@round(window_width * ui_scale));
    const height: i32 = @intFromFloat(@round(window_height * ui_scale));
    const rect = Rect{
        .x = window.x + @divTrunc(width - metrics.width, 2),
        .y = window.y + height - metrics.height - @as(i32, @intFromFloat(@round(2 * ui_scale))),
        .w = metrics.width,
        .h = metrics.height,
    };
    badge.draw(canvas, rect, text, ui_scale);
}
