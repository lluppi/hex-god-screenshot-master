//! Reading the baseline capture: the pixel under the cursor, and the 21x21
//! physical-pixel neighbourhood the loupe magnifies. Shared by both frontends
//! because both keep a frozen baseline of each display and never capture live
//! pixels for the loupe.

const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");

const Canvas = canvas_mod.Canvas;

/// Colour of a logical point inside one display, converted to that display's
/// physical pixels.
pub fn sampleHex(baseline: *const Canvas, scale: f64, local_logical: geom.Point) ?color.Rgb {
    const x: i32 = @intFromFloat(@floor(local_logical.x * scale));
    const y: i32 = @intFromFloat(@floor(local_logical.y * scale));
    const pixel = baseline.get(x, y) orelse return null;
    return color.rgbOf(pixel);
}

/// Fill a magnifier sample canvas from a baseline: `sample.width` physical
/// pixels centred on the cursor, so the canvas centre is the pixel under it.
pub fn fillSample(
    sample: *Canvas,
    baseline: *const Canvas,
    scale: f64,
    local_logical: geom.Point,
) void {
    const side: i32 = @intCast(sample.width);
    const half = @divTrunc(side, 2);
    const x: i32 = @intFromFloat(@floor(local_logical.x * scale));
    const y: i32 = @intFromFloat(@floor(local_logical.y * scale));
    var row: i32 = 0;
    while (row < side) : (row += 1) {
        var column: i32 = 0;
        while (column < side) : (column += 1) {
            sample.set(column, row, baseline.sample(x - half + column, y - half + row));
        }
    }
}
