//! The live pixel scope and its hex readout. The scope is deliberately a hard,
//! square instrument: the sampled pixels are the interface, not decoration.
//!
//! Measurements are points multiplied by `ui_scale`, so the instrument keeps
//! the same apparent size on every display. The source sample always remains
//! physical pixels and is enlarged with nearest-neighbour sampling.

const badge = @import("badge.zig");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const geom = @import("geom.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;

pub const scope_size: f64 = 180;
pub const endpoint_scope_size: f64 = 30;
pub const endpoint_sample_side: u32 = 3;
const plate_height: f64 = 28;
pub const window_width: f64 = scope_size;
pub const window_height: f64 = scope_size + plate_height;
/// Distance from the window's top-left corner to the cursor: the centre cell.
pub const cursor_inset: f64 = scope_size / 2;

/// Physical pixels sampled around the cursor. Kept odd so there is one exact
/// centre pixel: that is both the target and the colour copied on click.
pub const sample_side: u32 = 13;

/// Top-left corner of the scope window for a cursor at `point`.
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

/// First destination pixel at or beyond a sample-cell boundary.
fn gridOffset(step: u32, size: i32) i32 {
    const scaled = @as(u64, step) * @as(u64, @intCast(size));
    return @intCast((scaled + sample_side - 1) / sample_side);
}

fn endpointGridOffset(step: u32, size: i32) i32 {
    const scaled = @as(u64, step) * @as(u64, @intCast(size));
    return @intCast((scaled + endpoint_sample_side - 1) / endpoint_sample_side);
}

fn targetInk(rgb: color.Rgb) u32 {
    const perceived_light = @as(u32, rgb.r) * 299 + @as(u32, rgb.g) * 587 + @as(u32, rgb.b) * 114;
    return if (perceived_light >= 128_000)
        color.solid(.{ .r = 0x00, .g = 0x00, .b = 0x00 })
    else
        color.solid(.{ .r = 0xff, .g = 0xff, .b = 0xff });
}

fn blendFrame(canvas: *Canvas, rect: Rect, thickness: i32, pixel: u32) void {
    blendFrameEdges(canvas, rect, thickness, pixel, true, true, true, true);
}

fn blendFrameEdges(
    canvas: *Canvas,
    rect: Rect,
    thickness: i32,
    pixel: u32,
    top: bool,
    bottom: bool,
    left: bool,
    right: bool,
) void {
    if (top) canvas.blendRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, pixel);
    if (bottom) canvas.blendRect(.{ .x = rect.x, .y = rect.maxY() - thickness, .w = rect.w, .h = thickness }, pixel);
    if (left) canvas.blendRect(.{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, pixel);
    if (right) canvas.blendRect(.{ .x = rect.maxX() - thickness, .y = rect.y, .w = thickness, .h = rect.h }, pixel);
}

/// Draw the scope, target cell and attached colour plate.
pub fn render(canvas: *Canvas, origin: geom.Point, sample: Canvas, ui_scale: f64) void {
    const window = windowRect(origin, ui_scale);
    if (!window.intersects(canvas.rect())) return;

    const side: i32 = @intFromFloat(@round(scope_size * ui_scale));
    const scope = Rect{ .x = window.x, .y = window.y, .w = side, .h = side };
    canvas.blitNearest(sample, scope);

    const grid_ink = color.black(48);
    const grid_width: i32 = @max(1, @as(i32, @intFromFloat(@round(ui_scale))));
    var step: u32 = 1;
    while (step < sample_side) : (step += 1) {
        const offset = gridOffset(step, side);
        canvas.blendRect(.{ .x = scope.x + offset, .y = scope.y, .w = grid_width, .h = scope.h }, grid_ink);
        canvas.blendRect(.{ .x = scope.x, .y = scope.y + offset, .w = scope.w, .h = grid_width }, grid_ink);
    }

    // The outer rail is structural; its inner edge is exactly one grid line.
    const light = color.solid(.{ .r = 0xee, .g = 0xec, .b = 0xed });
    const outer_light: i32 = @max(1, @as(i32, @intFromFloat(@round(2 * ui_scale))));
    canvas.strokeRect(scope, outer_light, light);
    blendFrame(
        canvas,
        .{
            .x = scope.x + outer_light,
            .y = scope.y + outer_light,
            .w = scope.w - 2 * outer_light,
            .h = scope.h - 2 * outer_light,
        },
        grid_width,
        grid_ink,
    );

    const rgb = hexAt(sample) orelse return;
    const centre = sample_side / 2;
    const target_width: i32 = @max(1, @as(i32, @intFromFloat(@round(ui_scale))));
    const target_start = gridOffset(centre, side);
    const target_end = gridOffset(centre + 1, side);
    const target = Rect{
        .x = scope.x + target_start,
        .y = scope.y + target_start,
        // Include the far grid line so every edge replaces a line instead of
        // consuming space inside the hovered pixel.
        .w = target_end - target_start + target_width,
        .h = target_end - target_start + target_width,
    };
    canvas.strokeRect(target, target_width, targetInk(rgb));

    const text = color.hexString(rgb);
    const height: i32 = @intFromFloat(@round(plate_height * ui_scale));
    const plate = Rect{ .x = window.x, .y = window.y + side, .w = side, .h = height };
    badge.draw(canvas, plate, &text, ui_scale);

    // The sampled colour is the only chromatic accent in the instrument.
    const signal_height: i32 = @max(2, @as(i32, @intFromFloat(@round(3 * ui_scale))));
    canvas.fillRect(
        .{ .x = plate.x, .y = plate.maxY() - signal_height, .w = plate.w, .h = signal_height },
        color.solid(rgb),
    );
}

fn horizontalCompanion(rect: Rect, target_column: u32) Rect {
    return .{
        .x = if (target_column == 0) rect.x - rect.w else rect.maxX(),
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    };
}

fn verticalCompanion(rect: Rect, target_row: u32) Rect {
    return .{
        .x = rect.x,
        .y = if (target_row == 0) rect.y - rect.h else rect.maxY(),
        .w = rect.w,
        .h = rect.h,
    };
}

pub fn endpointBounds(rect: Rect, target_column: u32, target_row: u32) Rect {
    return rect
        .unionWith(horizontalCompanion(rect, target_column))
        .unionWith(verticalCompanion(rect, target_row));
}

/// Draw an L-shaped endpoint scope outside the selection. The sampled endpoint
/// occupies the cell that physically touches the active box corner; companion
/// grids extend along both outer edges without covering the capture.
pub fn renderEndpoint(
    canvas: *Canvas,
    rect: Rect,
    sample: Canvas,
    ui_scale: f64,
    target_column: u32,
    target_row: u32,
) void {
    if (rect.isEmpty() or sample.width < endpoint_sample_side or sample.height < endpoint_sample_side) return;
    if (target_column >= endpoint_sample_side or target_row >= endpoint_sample_side) return;

    const source_x: i32 = @as(i32, @intCast(sample.width / 2)) - @as(i32, @intCast(target_column));
    const source_y: i32 = @as(i32, @intCast(sample.height / 2)) - @as(i32, @intCast(target_row));
    const outward_x: i32 = if (target_column == 0) 1 else -1;
    const outward_y: i32 = if (target_row == 0) 1 else -1;

    const horizontal = horizontalCompanion(rect, target_column);
    const vertical = verticalCompanion(rect, target_row);
    renderEndpointTile(canvas, rect, sample, ui_scale, source_x, source_y);
    renderEndpointTile(
        canvas,
        horizontal,
        sample,
        ui_scale,
        source_x - outward_x * @as(i32, @intCast(endpoint_sample_side)),
        source_y,
    );
    renderEndpointTile(
        canvas,
        vertical,
        sample,
        ui_scale,
        source_x,
        source_y - outward_y * @as(i32, @intCast(endpoint_sample_side)),
    );

    const grid_ink = color.black(48);
    const grid_width: i32 = @max(1, @as(i32, @intFromFloat(@round(ui_scale))));
    blendFrame(canvas, rect, grid_width, grid_ink);
    blendFrameEdges(
        canvas,
        horizontal,
        grid_width,
        grid_ink,
        true,
        true,
        target_column == 0,
        target_column != 0,
    );
    blendFrameEdges(
        canvas,
        vertical,
        grid_width,
        grid_ink,
        target_row == 0,
        target_row != 0,
        true,
        true,
    );

    const rgb = hexAt(sample) orelse return;
    const target_x = endpointGridOffset(target_column, rect.w);
    const target_y = endpointGridOffset(target_row, rect.h);
    const target_max_x = endpointGridOffset(target_column + 1, rect.w);
    const target_max_y = endpointGridOffset(target_row + 1, rect.h);
    canvas.strokeRect(
        .{
            .x = rect.x + target_x,
            .y = rect.y + target_y,
            .w = target_max_x - target_x + grid_width,
            .h = target_max_y - target_y + grid_width,
        },
        grid_width,
        targetInk(rgb),
    );
}

fn renderEndpointTile(
    canvas: *Canvas,
    rect: Rect,
    sample: Canvas,
    ui_scale: f64,
    source_x: i32,
    source_y: i32,
) void {
    var y = rect.y;
    while (y < rect.maxY()) : (y += 1) {
        const sy = source_y + @divTrunc((y - rect.y) * @as(i32, @intCast(endpoint_sample_side)), rect.h);
        var x = rect.x;
        while (x < rect.maxX()) : (x += 1) {
            const sx = source_x + @divTrunc((x - rect.x) * @as(i32, @intCast(endpoint_sample_side)), rect.w);
            if (sample.get(sx, sy)) |pixel| canvas.set(x, y, pixel);
        }
    }

    const grid_ink = color.black(48);
    const grid_width: i32 = @max(1, @as(i32, @intFromFloat(@round(ui_scale))));
    var step: u32 = 1;
    while (step < endpoint_sample_side) : (step += 1) {
        const offset = endpointGridOffset(step, rect.w);
        canvas.blendRect(.{ .x = rect.x + offset, .y = rect.y, .w = grid_width, .h = rect.h }, grid_ink);
        canvas.blendRect(.{ .x = rect.x, .y = rect.y + offset, .w = rect.w, .h = grid_width }, grid_ink);
    }
}
