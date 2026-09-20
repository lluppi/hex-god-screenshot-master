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

/// The faint lines between sample cells.
const grid_ink: u32 = @as(u32, 48) << 24;

fn gridWidth(ui_scale: f64) i32 {
    return geom.px(ui_scale, 1);
}

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

/// First destination pixel at or beyond a boundary between `cells` equal cells
/// spanning `size` pixels.
fn gridOffset(step: u32, size: i32, cells: u32) i32 {
    const scaled = @as(u64, step) * @as(u64, @intCast(size));
    return @intCast((scaled + cells - 1) / cells);
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
    const line = gridWidth(ui_scale);
    renderGrid(canvas, scope, sample, line, geom.px(ui_scale, 2));
    renderTarget(canvas, scope, sample, line);
    renderPlate(canvas, window, side, sample, ui_scale);
}

/// The magnified sample, its cell grid, and the structural outer rail.
fn renderGrid(canvas: *Canvas, scope: Rect, sample: Canvas, line: i32, rail: i32) void {
    canvas.blitNearest(sample, sample.rect(), scope);

    var step: u32 = 1;
    while (step < sample_side) : (step += 1) {
        const offset = gridOffset(step, scope.w, sample_side);
        canvas.blendRect(.{ .x = scope.x + offset, .y = scope.y, .w = line, .h = scope.h }, grid_ink);
        canvas.blendRect(.{ .x = scope.x, .y = scope.y + offset, .w = scope.w, .h = line }, grid_ink);
    }

    // The outer rail is structural; its inner edge is exactly one grid line.
    canvas.strokeRect(scope, rail, color.solid(color.instrument_light));
    blendFrame(
        canvas,
        .{
            .x = scope.x + rail,
            .y = scope.y + rail,
            .w = scope.w - 2 * rail,
            .h = scope.h - 2 * rail,
        },
        line,
        grid_ink,
    );
}

/// The outline around the cell that will be copied on click.
fn renderTarget(canvas: *Canvas, scope: Rect, sample: Canvas, line: i32) void {
    const rgb = hexAt(sample) orelse return;
    const centre = sample_side / 2;
    const start = gridOffset(centre, scope.w, sample_side);
    const end = gridOffset(centre + 1, scope.w, sample_side);
    canvas.strokeRect(
        .{
            .x = scope.x + start,
            .y = scope.y + start,
            // Include the far grid line so every edge replaces a line instead of
            // consuming space inside the hovered pixel.
            .w = end - start + line,
            .h = end - start + line,
        },
        line,
        color.solid(color.contrasting(rgb)),
    );
}

/// The hex plate under the scope, with the sampled colour as its only chromatic
/// accent. The plate is only as wide as the code itself (plus its own padding),
/// centred under the scope, rather than spanning the scope's width: the code is
/// the content, the plate just backs it.
fn renderPlate(canvas: *Canvas, window: Rect, side: i32, sample: Canvas, ui_scale: f64) void {
    const rgb = hexAt(sample) orelse return;
    const hex = color.hexString(rgb);
    const metrics = badge.metrics(&hex, ui_scale);
    const height: i32 = @intFromFloat(@round(plate_height * ui_scale));
    const plate = Rect{
        .x = window.x + @divTrunc(window.w - metrics.width, 2),
        .y = window.y + side,
        .w = metrics.width,
        .h = height,
    };
    badge.draw(canvas, plate, &hex, ui_scale);

    const signal_height: i32 = @max(2, @as(i32, @intFromFloat(@round(3 * ui_scale))));
    canvas.fill(
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
    const cells: i32 = @intCast(endpoint_sample_side);

    const horizontal = horizontalCompanion(rect, target_column);
    const vertical = verticalCompanion(rect, target_row);
    const line = gridWidth(ui_scale);
    renderEndpointTile(canvas, rect, sample, line, source_x, source_y);
    renderEndpointTile(canvas, horizontal, sample, line, source_x - outward_x * cells, source_y);
    renderEndpointTile(canvas, vertical, sample, line, source_x, source_y - outward_y * cells);

    blendFrame(canvas, rect, line, grid_ink);
    blendFrameEdges(canvas, horizontal, line, grid_ink, true, true, target_column == 0, target_column != 0);
    blendFrameEdges(canvas, vertical, line, grid_ink, target_row == 0, target_row != 0, true, true);

    const rgb = hexAt(sample) orelse return;
    const target_x = gridOffset(target_column, rect.w, endpoint_sample_side);
    const target_y = gridOffset(target_row, rect.h, endpoint_sample_side);
    const target_max_x = gridOffset(target_column + 1, rect.w, endpoint_sample_side);
    const target_max_y = gridOffset(target_row + 1, rect.h, endpoint_sample_side);
    canvas.strokeRect(
        .{
            .x = rect.x + target_x,
            .y = rect.y + target_y,
            .w = target_max_x - target_x + line,
            .h = target_max_y - target_y + line,
        },
        line,
        color.solid(color.contrasting(rgb)),
    );
}

/// Draw one `endpoint_sample_side`-square cell of the sample, magnified to fill
/// `rect`, with its own grid lines.
fn renderEndpointTile(
    canvas: *Canvas,
    rect: Rect,
    sample: Canvas,
    line: i32,
    source_x: i32,
    source_y: i32,
) void {
    canvas.blitNearest(sample, .{
        .x = source_x,
        .y = source_y,
        .w = @intCast(endpoint_sample_side),
        .h = @intCast(endpoint_sample_side),
    }, rect);

    var step: u32 = 1;
    while (step < endpoint_sample_side) : (step += 1) {
        const offset = gridOffset(step, rect.w, endpoint_sample_side);
        canvas.blendRect(.{ .x = rect.x + offset, .y = rect.y, .w = line, .h = rect.h }, grid_ink);
        canvas.blendRect(.{ .x = rect.x, .y = rect.y + offset, .w = rect.w, .h = line }, grid_ink);
    }
}
