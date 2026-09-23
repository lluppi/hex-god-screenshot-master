//! Geometry shared by every frontend.
//!
//! Two coordinate spaces are in play everywhere:
//!
//!  * logical: what a compositor or window server reports for the cursor and
//!    for window geometry. This is what the user perceives as "pixels" in the
//!    dimension badge, and what the gesture state machine works in.
//!  * physical: real device pixels. A 4096x1728 logical 1.25x output is
//!    5120x2160 physical pixels. Sampling, cropping and encoding all happen
//!    here so the colour picked is a real screen pixel.

const std = @import("std");

/// A length in points, scaled to physical pixels and never less than one pixel.
pub fn px(scale: f64, points: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(points * scale))));
}

/// Overlap of two rectangles of the same numeric type; empty when they do not
/// touch. Shared by `Rect` and `FRect` so one definition serves both spaces.
fn intersect(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.maxX(), b.maxX());
    const y1 = @min(a.maxY(), b.maxY());
    if (x1 <= x0 or y1 <= y0) return .{};
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn distance(self: Point, other: Point) f64 {
        return @sqrt(
            (self.x - other.x) * (self.x - other.x) +
                (self.y - other.y) * (self.y - other.y),
        );
    }
};

/// A rectangle in logical space. The gesture machine only ever deals in these.
pub const FRect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn maxX(self: FRect) f64 {
        return self.x + self.w;
    }

    pub fn maxY(self: FRect) f64 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: FRect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn intersection(self: FRect, other: FRect) FRect {
        return intersect(self, other);
    }

    /// Normalised rectangle from two corner points, in any order.
    pub fn between(a: Point, b: Point) FRect {
        return .{
            .x = @min(a.x, b.x),
            .y = @min(a.y, b.y),
            .w = @abs(b.x - a.x),
            .h = @abs(b.y - a.y),
        };
    }
};

/// A rectangle in physical pixels.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn maxX(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn maxY(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return !self.intersection(other).isEmpty();
    }

    pub fn intersection(self: Rect, other: Rect) Rect {
        return intersect(self, other);
    }

    pub fn unionWith(self: Rect, other: Rect) Rect {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        const x0 = @min(self.x, other.x);
        const y0 = @min(self.y, other.y);
        const x1 = @max(self.maxX(), other.maxX());
        const y1 = @max(self.maxY(), other.maxY());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn expand(self: Rect, amount: i32) Rect {
        return .{
            .x = self.x - amount,
            .y = self.y - amount,
            .w = self.w + 2 * amount,
            .h = self.h + 2 * amount,
        };
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and x < self.maxX() and y >= self.y and y < self.maxY();
    }

    /// Clamp to a canvas of the given size, keeping the rectangle valid.
    pub fn clamped(self: Rect, width: u32, height: u32) Rect {
        const x0 = std.math.clamp(self.x, 0, @as(i32, @intCast(width)));
        const y0 = std.math.clamp(self.y, 0, @as(i32, @intCast(height)));
        const x1 = std.math.clamp(self.maxX(), 0, @as(i32, @intCast(width)));
        const y1 = std.math.clamp(self.maxY(), 0, @as(i32, @intCast(height)));
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn roundF(rect: FRect) Rect {
        const x0 = @floor(rect.x);
        const y0 = @floor(rect.y);
        const x1 = @ceil(rect.maxX());
        const y1 = @ceil(rect.maxY());
        return .{
            .x = @intFromFloat(x0),
            .y = @intFromFloat(y0),
            .w = @intFromFloat(x1 - x0),
            .h = @intFromFloat(y1 - y0),
        };
    }
};
