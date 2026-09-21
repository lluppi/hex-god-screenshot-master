//! The drawing surface both frontends render into. Premultiplied ARGB8888,
//! top-left origin, one `u32` per pixel.

const std = @import("std");
const geom = @import("geom.zig");
const color = @import("color.zig");

const Rect = geom.Rect;

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

    /// Allocate an owned, zeroed canvas; release it with `deinit`.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const canvas = try initUninitialized(allocator, width, height);
        @memset(canvas.pixels, 0);
        return canvas;
    }

    /// Allocate an owned canvas for callers that immediately overwrite every
    /// pixel. Reading it before that overwrite is invalid.
    pub fn initUninitialized(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        return .{
            .width = width,
            .height = height,
            .pixels = try allocator.alloc(u32, @as(usize, width) * @as(usize, height)),
            .allocator = allocator,
        };
    }

    /// Only for canvases from `init` or `initUninitialized`. A borrowed view
    /// over memory someone else owns (an shm buffer) must never reach here.
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

    pub fn fill(self: Canvas, area: Rect, pixel: u32) void {
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

    /// Copy and dim a rectangle in one pass. This avoids writing the baseline
    /// once for the copy and a second time for the dimming operation.
    pub fn copyDimmedFrom(self: Canvas, src: Canvas, area: Rect) void {
        const r = self.work(area).intersection(src.rect());
        if (r.isEmpty()) return;
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            var dst = self.index(r.x, y);
            const end = dst + @as(usize, @intCast(r.w));
            var source = src.index(r.x, y);
            while (dst < end) : ({
                dst += 1;
                source += 1;
            }) {
                self.pixels[dst] = color.dimPixel(src.pixels[source]);
            }
        }
    }

    /// Nearest-neighbour blit: map `src_rect` of `src` onto `dest_rect`. Used to
    /// composite captures from displays with different scales into one
    /// screenshot, and to draw a sample grid into a scope cell.
    pub fn blitNearest(self: *Canvas, src: Canvas, src_rect: Rect, dest_rect: Rect) void {
        if (src_rect.isEmpty() or dest_rect.isEmpty()) return;
        const dest = self.work(dest_rect);
        if (dest.isEmpty()) return;
        const span_w: u64 = @intCast(src_rect.w);
        const span_h: u64 = @intCast(src_rect.h);
        var y = dest.y;
        while (y < dest.maxY()) : (y += 1) {
            const sy: i32 = @intCast(
                @as(u64, @intCast(y - dest_rect.y)) * span_h / @as(u64, @intCast(dest_rect.h)),
            );
            const row = (@as(usize, @intCast(src_rect.y)) + @as(usize, @intCast(sy))) * src.width;
            var x = dest.x;
            while (x < dest.maxX()) : (x += 1) {
                const sx: i32 = @intCast(
                    @as(u64, @intCast(x - dest_rect.x)) * span_w / @as(u64, @intCast(dest_rect.w)),
                );
                self.pixels[self.index(x, y)] = src.pixels[row + @as(usize, @intCast(src_rect.x + sx))];
            }
        }
    }

    pub fn dim(self: Canvas, area: Rect) void {
        const r = self.work(area);
        if (r.isEmpty()) return;
        var y = r.y;
        while (y < r.maxY()) : (y += 1) {
            var x = r.x;
            while (x < r.maxX()) : (x += 1) {
                const i = self.index(x, y);
                self.pixels[i] = color.dimPixel(self.pixels[i]);
            }
        }
    }

    pub fn strokeRect(self: *Canvas, area: Rect, thickness: i32, pixel: u32) void {
        if (thickness <= 0) return;
        const r = area.clamped(self.width, self.height);
        if (r.isEmpty()) return;
        self.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = thickness }, pixel);
        self.fill(.{ .x = r.x, .y = r.maxY() - thickness, .w = r.w, .h = thickness }, pixel);
        self.fill(.{ .x = r.x, .y = r.y, .w = thickness, .h = r.h }, pixel);
        self.fill(.{ .x = r.maxX() - thickness, .y = r.y, .w = thickness, .h = r.h }, pixel);
    }

    /// Blend `pixel` at a fraction of its own alpha. Every anti-aliased shape
    /// goes through here.
    pub fn blendCoverage(self: *Canvas, x: i32, y: i32, pixel: u32, coverage: f64) void {
        if (coverage <= 0) return;
        if (coverage >= 1) {
            self.blend(x, y, pixel);
            return;
        }
        const scaled = color.withCoverage(pixel, coverage);
        if (scaled == 0) return;
        self.blend(x, y, scaled);
    }

    /// `blendCoverage`, mixing in linear light. Text edges use this because a
    /// light glyph on a dark plate is where sRGB-space blending is visibly
    /// wrong: the partial pixels come out too thin and the ramp reads as a
    /// stair rather than a ramp.
    pub fn blendCoverageLinear(self: *Canvas, x: i32, y: i32, pixel: u32, coverage: f64) void {
        if (coverage <= 0) return;
        if (!self.writable(x, y)) return;
        const scaled = if (coverage >= 1) pixel else color.withCoverage(pixel, coverage);
        if (scaled == 0) return;
        const i = self.index(x, y);
        self.pixels[i] = color.overLinear(self.pixels[i], scaled);
    }
};
