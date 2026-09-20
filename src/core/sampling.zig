//! Reading the baseline capture: the pixel under the cursor, and the
//! neighbourhood the loupe magnifies. Shared by both frontends because both
//! keep a frozen baseline of each display and never capture live pixels for the
//! loupe.

const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");

const Canvas = canvas_mod.Canvas;

/// Logical point -> physical pixels on a display of this scale.
pub fn toPhysical(scale: f64, local: geom.Point) geom.Point {
    return .{ .x = local.x * scale, .y = local.y * scale };
}

/// Colour at a physical pixel of one display's baseline.
pub fn sampleHex(baseline: *const Canvas, physical: geom.Point) ?color.Rgb {
    const x: i32 = @intFromFloat(@floor(physical.x));
    const y: i32 = @intFromFloat(@floor(physical.y));
    const pixel = baseline.get(x, y) orelse return null;
    return color.rgbOf(pixel);
}

/// Fill a magnifier sample canvas from a baseline: `sample.width` physical
/// pixels centred on `physical`, so the canvas centre is the pixel under it.
pub fn fillSample(sample: *Canvas, baseline: *const Canvas, physical: geom.Point) void {
    const side: i32 = @intCast(sample.width);
    const half = @divTrunc(side, 2);
    const x: i32 = @intFromFloat(@floor(physical.x));
    const y: i32 = @intFromFloat(@floor(physical.y));
    var row: i32 = 0;
    while (row < side) : (row += 1) {
        var column: i32 = 0;
        while (column < side) : (column += 1) {
            sample.set(column, row, baseline.sample(x - half + column, y - half + row));
        }
    }
}
