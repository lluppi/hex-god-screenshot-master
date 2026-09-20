//! Shared geometry and painting for compact instrument readouts.

const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const font = @import("font.zig");
const geom = @import("geom.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;

pub const Metrics = struct {
    padding_x: i32,
    padding_y: i32,
    width: i32,
    height: i32,
};

pub fn metrics(text: []const u8, ui_scale: f64) Metrics {
    const padding_x: i32 = @intFromFloat(@round(7 * ui_scale));
    const padding_y: i32 = @intFromFloat(@round(4 * ui_scale));
    return .{
        .padding_x = padding_x,
        .padding_y = padding_y,
        .width = font.textWidth(text, ui_scale) + 2 * padding_x,
        .height = font.cellHeight(ui_scale) + 2 * padding_y,
    };
}

pub fn draw(canvas: *Canvas, rect: Rect, text: []const u8, ui_scale: f64) void {
    drawPlate(canvas, rect, text, ui_scale);
}

fn drawPlate(canvas: *Canvas, rect: Rect, text: []const u8, ui_scale: f64) void {
    const text_width = font.textWidth(text, ui_scale);
    const text_height = font.cellHeight(ui_scale);
    canvas.blendRect(rect, color.black(226));
    font.draw(
        canvas,
        rect.x + @divTrunc(rect.w - text_width, 2),
        rect.y + @divTrunc(rect.h - text_height, 2),
        text,
        ui_scale,
        color.solid(.{ .r = 0xee, .g = 0xec, .b = 0xed }),
    );
}
