//! The drawing surface both frontends render into. Premultiplied ARGB8888,
//! top-left origin, one `u32` per pixel.

const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");

const Rect = geom.Rect;
const Point = geom.Point;

pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u32,
    allocator: std.mem.Allocator,
    /// When set, every write is confined to this rectangle. The overlay
    /// renderer recomposes the screen one dirty rectangle at a time and must
    /// never touch a pixel outside the region it is about to damage, otherwise
    /// the other swapchain buffer keeps stale content there.
    clip: ?Rect = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const pixels = try allocator.alloc(u32, @as(usize, width) * @as(usize, height));
        @memset(pixels, 0);
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn rect(self: Canvas) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    pub fn index(self: Canvas, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
    }

    pub fn contains(self: Canvas, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height;
    }

    pub fn setClip(self: *Canvas, region: Rect) void {
        self.clip = region;
    }

    pub fn clearClip(self: *Canvas) void {
        self.clip = null;
    }

    /// True when a write at (x, y) is allowed by both the canvas bounds and the
    /// active clip.
    fn writable(self: Canvas, x: i32, y: i32) bool {
        if (!self.contains(x, y)) return false;
        if (self.clip) |clip| return clip.contains(x, y);
        return true;
    }

    /// Intersect a requested area with the canvas bounds and the active clip.
    fn work(self: Canvas, area: Rect) Rect {
        const bounded = area.clamped(self.width, self.height);
        if (self.clip) |clip| return bounded.intersection(clip);
        return bounded;
    }

    /// Nearest sample, clamped at the edges so the loupe stays sane when the
    /// cursor sits in a corner.
    pub fn sample(self: Canvas, x: i32, y: i32) u32 {
        const cx = std.math.clamp(x, 0, @as(i32, @intCast(self.width - 1)));
        const cy = std.math.clamp(y, 0, @as(i32, @intCast(self.height - 1)));
        return self.pixels[self.index(cx, cy)];
    }

    pub fn get(self: Canvas, x: i32, y: i32) ?u32 {
        if (!self.contains(x, y)) return null;
        return self.pixels[self.index(x, y)];
    }

    pub fn set(self: Canvas, x: i32, y: i32, pixel: u32) void {
        if (!self.writable(x, y)) return;
        self.pixels[self.index(x, y)] = pixel;
    }

    pub fn blend(self: Canvas, x: i32, y: i32, pixel: u32) void {
        if (!self.writable(x, y)) return;
        const i = self.index(x, y);
        self.pixels[i] = color.over(self.pixels[i], pixel);
    }

    pub fn fillRect(self: Canvas, area: Rect, pixel: u32) void {
        const r = self.work(area);
        if (r.isEmpty()) return;
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            const start = self.index(r.x, y);
            @memset(self.pixels[start .. start + @as(usize, @intCast(r.w))], pixel);
        }
    }

    pub fn blendRect(self: Canvas, area: Rect, pixel: u32) void {
        const r = self.work(area);
        if (r.isEmpty()) return;
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            var x = r.x;
            while (x < r.maxX()) : (x += 1) self.blend(x, y, pixel);
        }
    }

    /// Copy a rectangle out of `src` at the same coordinates (used to restore
    /// the undimmed screen inside the selection, and to seed the baseline).
    pub fn copyFrom(self: Canvas, src: Canvas, area: Rect) void {
        const r = self.work(area).intersection(src.rect());
        if (r.isEmpty()) return;
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            const dst_start = self.index(r.x, y);
            const src_start = src.index(r.x, y);
            @memcpy(
                self.pixels[dst_start .. dst_start + @as(usize, @intCast(r.w))],
                src.pixels[src_start .. src_start + @as(usize, @intCast(r.w))],
            );
        }
    }

    /// Nearest-neighbour scale of a whole source canvas into `dest_rect`. Used
    /// to composite captures from displays with different scales into a single
    /// screenshot.
    pub fn blitNearest(self: *Canvas, src: Canvas, dest_rect: Rect) void {
        if (dest_rect.isEmpty() or src.width == 0 or src.height == 0) return;
        const dest = self.work(dest_rect);
        if (dest.isEmpty()) return;
        var y = dest.y;
        while (y < dest.maxY()) : (y += 1) {
            const sy: u32 = @intCast(
                @as(u64, @intCast(y - dest_rect.y)) * src.height / @as(u64, @intCast(dest_rect.h)),
            );
            const row = @as(usize, @min(sy, src.height - 1)) * src.width;
            var x = dest.x;
            while (x < dest.maxX()) : (x += 1) {
                const sx: u32 = @intCast(
                    @as(u64, @intCast(x - dest_rect.x)) * src.width / @as(u64, @intCast(dest_rect.w)),
                );
                self.pixels[self.index(x, y)] = src.pixels[row + @min(sx, src.width - 1)];
            }
        }
    }

    pub fn dim(self: Canvas, area: Rect, numerator: u32) void {
        const r = self.work(area);
        if (r.isEmpty()) return;
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            var x = r.x;
            while (x < r.maxX()) : (x += 1) {
                const i = self.index(x, y);
                self.pixels[i] = color.dimPixel(self.pixels[i], numerator);
            }
        }
    }

    pub fn strokeRect(self: Canvas, area: Rect, thickness: i32, pixel: u32) void {
        if (thickness <= 0) return;
        const r = area.clamped(self.width, self.height);
        if (r.isEmpty()) return;
        self.fillRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = thickness }, pixel);
        self.fillRect(.{ .x = r.x, .y = r.maxY() - thickness, .w = r.w, .h = thickness }, pixel);
        self.fillRect(.{ .x = r.x, .y = r.y, .w = thickness, .h = r.h }, pixel);
        self.fillRect(.{ .x = r.maxX() - thickness, .y = r.y, .w = thickness, .h = r.h }, pixel);
    }

    /// Filled circle, used for the loupe body and for the rounded badge corners.
    pub fn fillCircle(self: Canvas, center_x: f64, center_y: f64, radius: f64, pixel: u32) void {
        const x0: i32 = @intFromFloat(@floor(center_x - radius));
        const x1: i32 = @intFromFloat(@ceil(center_x + radius));
        const y0: i32 = @intFromFloat(@floor(center_y - radius));
        const y1: i32 = @intFromFloat(@ceil(center_y + radius));
        const r2 = radius * radius;
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - center_x;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - center_y;
                if (dx * dx + dy * dy <= r2) self.set(x, y, pixel);
            }
        }
    }

    /// Circle outline of the given thickness, used for the loupe ring.
    pub fn strokeCircle(
        self: Canvas,
        center_x: f64,
        center_y: f64,
        radius: f64,
        thickness: f64,
        pixel: u32,
    ) void {
        const inner = @max(0.0, radius - thickness);
        const outer2 = radius * radius;
        const inner2 = inner * inner;
        const x0: i32 = @intFromFloat(@floor(center_x - radius));
        const x1: i32 = @intFromFloat(@ceil(center_x + radius));
        const y0: i32 = @intFromFloat(@floor(center_y - radius));
        const y1: i32 = @intFromFloat(@ceil(center_y + radius));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - center_x;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - center_y;
                const d2 = dx * dx + dy * dy;
                if (d2 <= outer2 and d2 >= inner2) self.blend(x, y, pixel);
            }
        }
    }

    pub fn fillRoundedRect(self: Canvas, area: Rect, radius: f64, pixel: u32) void {
        const r = area.clamped(self.width, self.height);
        if (r.isEmpty()) return;
        if (radius <= 0.5) {
            self.blendRect(r, pixel);
            return;
        }
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            const dy_top = @as(f64, @floatFromInt(y)) + 0.5 - (@as(f64, @floatFromInt(r.y)) + radius);
            const dy_bottom = @as(f64, @floatFromInt(y)) + 0.5 -
                (@as(f64, @floatFromInt(r.maxY())) - radius);
            var inset: f64 = 0;
            if (dy_top < 0) {
                inset = radius - @sqrt(@max(0.0, radius * radius - dy_top * dy_top));
            } else if (dy_bottom > 0) {
                inset = radius - @sqrt(@max(0.0, radius * radius - dy_bottom * dy_bottom));
            }
            const x0 = r.x + @as(i32, @intFromFloat(@floor(inset)));
            const x1 = r.maxX() - @as(i32, @intFromFloat(@floor(inset)));
            self.blendRect(.{ .x = x0, .y = y, .w = x1 - x0, .h = 1 }, pixel);
        }
    }
};