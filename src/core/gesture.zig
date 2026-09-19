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

pub const Event = union(enum) {
    none,
    hovered: Point,
    selection_changed,
    finished: Result,
    cancelled,
};

pub const Coordinator = struct {
    start: ?Point = null,
    current: ?Point = null,
    selection: ?FRect = null,
    finished: bool = false,

    pub fn isSelecting(self: Coordinator) bool {
        return self.start != null;
    }

    pub fn hover(self: *Coordinator, point: Point) Event {
        if (self.isSelecting() or self.finished) return .none;
        self.current = point;
        return .{ .hovered = point };
    }

    pub fn begin(self: *Coordinator, point: Point) Event {
        if (self.finished) return .none;
        self.start = point;
        self.current = point;
        self.selection = .{ .x = point.x, .y = point.y, .w = 0, .h = 0 };
        return .selection_changed;
    }

    pub fn move(self: *Coordinator, point: Point) Event {
        if (self.start == null or self.finished) return .none;
        self.current = point;
        self.selection = FRect.between(self.start.?, point);
        return .selection_changed;
    }

    pub fn end(self: *Coordinator, point: Point) Event {
        const start = self.start orelse return .none;
        if (self.finished) return .none;
        _ = self.move(point);
        self.finished = true;

        if (start.distance(point) < click_threshold) {
            return .{ .finished = .{ .color = start } };
        }
        if (self.selection) |rect| {
            return .{ .finished = .{ .screenshot = rect } };
        }
        return .{ .finished = .{ .color = start } };
    }

    pub fn cancel(self: *Coordinator) Event {
        if (self.finished) return .none;
        self.finished = true;
        return .cancelled;
    }
};
