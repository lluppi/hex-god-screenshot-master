//! Shared geometry and painting for dark rounded text badges.

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
    const layout = metrics(text, ui_scale);
    canvas.fillRoundedRect(rect, 5 * ui_scale, color.black(209));
    font.draw(
        canvas,
        rect.x + layout.padding_x,
        rect.y + layout.padding_y,
        text,
        ui_scale,
        color.solid(.{ .r = 255, .g = 255, .b = 255 }),
    );
}
