//! Shared geometry and painting for compact instrument readouts.

const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const font = @import("font.zig");
const geom = @import("geom.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;

/// The dark plate the readout sits on: black at `plate_alpha`, so the screen
/// stays visible through the labels instead of the plate punching a hole in it.
/// The text is light and the plate dark, so there is contrast to spare; raise
/// this towards 255 for a more solid instrument, lower it for more see-through.
const plate_alpha: u8 = 176;
const plate: u32 = @as(u32, plate_alpha) << 24;

/// Space between the text and the plate edge, in points.
const padding_x_pt: f64 = 7;
const padding_y_pt: f64 = 4;

pub const Metrics = struct {
    padding_x: i32,
    padding_y: i32,
    width: i32,
    height: i32,
};

pub fn metrics(text: []const u8, ui_scale: f64) Metrics {
    const padding_x: i32 = @intFromFloat(@round(padding_x_pt * ui_scale));
    const padding_y: i32 = @intFromFloat(@round(padding_y_pt * ui_scale));
    return .{
        .padding_x = padding_x,
        .padding_y = padding_y,
        .width = font.textWidth(text, ui_scale) + 2 * padding_x,
        .height = font.cellHeight(ui_scale) + 2 * padding_y,
    };
}

/// Draw `text` centred on a filled plate covering `rect`.
pub fn draw(canvas: *Canvas, rect: Rect, text: []const u8, ui_scale: f64) void {
    const text_width = font.textWidth(text, ui_scale);
    const text_height = font.cellHeight(ui_scale);
    canvas.blendRect(rect, plate);
    font.draw(
        canvas,
        rect.x + @divTrunc(rect.w - text_width, 2),
        rect.y + @divTrunc(rect.h - text_height, 2),
        text,
        ui_scale,
        color.solid(color.instrument_light),
    );
}
