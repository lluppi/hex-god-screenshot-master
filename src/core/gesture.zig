//! The one gesture, state-machine half. Port of the original Swift
//! `SelectionCoordinator` so both frontends resolve a gesture identically:
//!
//!  * hover  -> live loupe at the cursor
//!  * click  -> copy the pixel's hex (release closer than `click_threshold`)
//!  * drag   -> copy the selection as a screenshot
//!  * escape / right click -> cancel
//!
//! Everything here is in logical coordinates; frontends convert to physical
//! pixels only when they sample or crop.

const geom = @import("geom.zig");

pub const Point = geom.Point;
pub const FRect = geom.FRect;

/// Releases closer than this many logical pixels count as a click, not a drag.
pub const click_threshold: f64 = 4;

pub const Result = union(enum) {
    color: Point,
    screenshot: FRect,
};

pub const Coordinator = struct {
    start: ?Point = null,
    selection: ?FRect = null,
    finished: bool = false,

    pub fn isSelecting(self: Coordinator) bool {
        return self.start != null;
    }

    pub fn begin(self: *Coordinator, point: Point) void {
        if (self.finished) return;
        self.start = point;
        self.selection = .{ .x = point.x, .y = point.y, .w = 0, .h = 0 };
    }

    pub fn move(self: *Coordinator, point: Point) void {
        if (self.start == null or self.finished) return;
        self.selection = FRect.between(self.start.?, point);
    }

    /// Resolve the gesture. Null unless this call is the one that finishes it.
    pub fn end(self: *Coordinator, point: Point) ?Result {
        const start = self.start orelse return null;
        if (self.finished) return null;
        self.move(point);
        self.finished = true;

        if (start.distance(point) < click_threshold) return .{ .color = start };
        if (self.selection) |rect| return .{ .screenshot = rect };
        return .{ .color = start };
    }

    pub fn cancel(self: *Coordinator) bool {
        if (self.finished) return false;
        self.finished = true;
        return true;
    }
};
