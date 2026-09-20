//! Platform-independent interaction state for the screenshot overlay.
//!
//! Frontends translate native events into surface-local cursor movement, apply
//! the returned physical-pixel damage, and own capture/clipboard operations.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const geom = @import("geom.zig");
const gesture = @import("gesture.zig");
const magnifier = @import("magnifier.zig");
const overlay = @import("overlay.zig");
const sampling = @import("sampling.zig");

const Canvas = canvas_mod.Canvas;
const FRect = geom.FRect;
const Point = geom.Point;
const Rect = geom.Rect;

pub const SurfaceId = usize;
pub const Result = gesture.Result;

/// Immutable surface data. The baseline pointer and geometry must remain valid
/// for the lifetime of the interaction.
pub const Surface = struct {
    logical: FRect,
    scale: f64,
    baseline: *const Canvas,
};

pub const Damage = struct {
    surface: SurfaceId,
    rect: Rect,
};

/// Repaint one physical-pixel region of one surface. The one thing a frontend
/// has to implement to apply the damage the shared state produces.
pub const PaintFn = *const fn (ctx: *anyopaque, surface: SurfaceId, rect: Rect) void;

/// The surface-local point for a global logical point, or null when the point
/// lies outside that surface.
pub fn localOf(logical: FRect, global: Point) ?Point {
    const local = Point{ .x = global.x - logical.x, .y = global.y - logical.y };
    if (local.x < 0 or local.y < 0) return null;
    if (local.x >= logical.w or local.y >= logical.h) return null;
    return local;
}

/// The surface containing a global logical point, and the point local to it.
/// Also usable before any interaction exists (`--pick`, the dev gestures).
pub fn hitTest(surfaces: []const Surface, global: Point) ?struct { surface: SurfaceId, local: Point } {
    for (surfaces, 0..) |surface, index| {
        if (localOf(surface.logical, global)) |local| return .{ .surface = index, .local = local };
    }
    return null;
}

/// The colour of a global logical point, from the baseline of the surface under
/// it.
pub fn colorAt(surfaces: []const Surface, global: Point) ?color.Rgb {
    for (surfaces) |surface| {
        const local = localOf(surface.logical, global) orelse continue;
        return sampling.sampleHex(surface.baseline, sampling.toPhysical(surface.scale, local));
    }
    return null;
}

pub fn paintDamages(damages: []const Damage, ctx: *anyopaque, paint: PaintFn) void {
    for (damages) |damage| paint(ctx, damage.surface, damage.rect);
}

/// Capture a global logical rectangle into one canvas.
///
/// The common case - the rectangle on a single surface - returns that surface's
/// capture untouched, so the pixels stay exactly as the platform produced them.
/// Only a rectangle spanning surfaces is composited, into the highest scale in
/// play. `capture` returns one surface's share, in global logical coordinates.
pub fn captureScreenshot(
    allocator: std.mem.Allocator,
    surfaces: []const Surface,
    rect: FRect,
    ctx: anytype,
    comptime capture: fn (@TypeOf(ctx), SurfaceId, FRect) anyerror!Canvas,
) !Canvas {
    var single: ?SurfaceId = null;
    var count: usize = 0;
    for (surfaces, 0..) |surface, index| {
        if (rect.intersection(surface.logical).isEmpty()) continue;
        single = index;
        count += 1;
    }
    if (count == 1) {
        const id = single.?;
        return capture(ctx, id, rect.intersection(surfaces[id].logical));
    }

    var scale: f64 = 1;
    for (surfaces) |surface| scale = @max(scale, surface.scale);

    const width: u32 = @intFromFloat(@max(1, @round(rect.w * scale)));
    const height: u32 = @intFromFloat(@max(1, @round(rect.h * scale)));
    var composite = try Canvas.init(allocator, width, height);
    errdefer composite.deinit();

    for (surfaces, 0..) |surface, index| {
        const intersection = rect.intersection(surface.logical);
        if (intersection.isEmpty()) continue;
        var captured = try capture(ctx, index, intersection);
        defer captured.deinit();

        const destination = Rect.roundF(.{
            .x = (intersection.x - rect.x) * scale,
            .y = (intersection.y - rect.y) * scale,
            .w = intersection.w * scale,
            .h = intersection.h * scale,
        });
        composite.blitNearest(captured, captured.rect(), destination);
    }
    return composite;
}

const Cursor = struct {
    surface: SurfaceId,
    local: Point,
    global: Point,
};

const Loupe = struct {
    surface: SurfaceId,
    origin: Point,
    rgb: color.Rgb,
};

const SurfaceState = struct {
    config: Surface,
    last_badge: ?Rect = null,
};

pub const Interaction = struct {
    allocator: std.mem.Allocator,
    surfaces: []SurfaceState,
    coordinator: gesture.Coordinator = .{},
    cursor: ?Cursor = null,
    loupe: ?Loupe = null,
    sample: Canvas,
    damages: std.ArrayList(Damage) = .empty,

    pub fn init(allocator: std.mem.Allocator, surfaces: []const Surface) !Interaction {
        const states = try allocator.alloc(SurfaceState, surfaces.len);
        errdefer allocator.free(states);
        for (surfaces, states) |surface, *state| state.* = .{ .config = surface };

        var sample = try Canvas.init(allocator, magnifier.sample_side, magnifier.sample_side);
        errdefer sample.deinit();

        var damages: std.ArrayList(Damage) = .empty;
        errdefer damages.deinit(allocator);
        try damages.ensureTotalCapacity(allocator, @max(surfaces.len, 2));

        return .{
            .allocator = allocator,
            .surfaces = states,
            .sample = sample,
            .damages = damages,
        };
    }

    pub fn deinit(self: *Interaction) void {
        self.sample.deinit();
        self.damages.deinit(self.allocator);
        self.allocator.free(self.surfaces);
        self.* = undefined;
    }

    /// Move the cursor and update either the loupe or the active selection.
    /// The returned slice is borrowed until the next mutating call.
    pub fn moveCursor(self: *Interaction, surface: SurfaceId, local: Point) []const Damage {
        self.damages.clearRetainingCapacity();
        if (surface >= self.surfaces.len or self.coordinator.finished) return self.damages.items;

        const config = self.surfaces[surface].config;
        const physical = sampling.toPhysical(config.scale, local);
        const global = Point{ .x = config.logical.x + local.x, .y = config.logical.y + local.y };
        self.cursor = .{ .surface = surface, .local = local, .global = global };

        if (self.coordinator.isSelecting()) {
            sampling.fillSample(&self.sample, config.baseline, physical);
            const previous = self.coordinator.selection;
            self.coordinator.move(global);
            self.planSelectionDamage(previous, self.coordinator.selection);
        } else {
            self.updateLoupe(surface, physical);
        }
        return self.damages.items;
    }

    /// Forget a cursor that left a surface and erase its loupe.
    pub fn leaveSurface(self: *Interaction, surface: SurfaceId) []const Damage {
        self.damages.clearRetainingCapacity();
        if (self.cursor) |cursor| {
            if (cursor.surface == surface) self.cursor = null;
        }
        self.planLoupeRemoval();
        return self.damages.items;
    }

    /// Hide the loupe and begin a click-or-drag gesture at the current cursor.
    pub fn beginSelection(self: *Interaction) []const Damage {
        self.damages.clearRetainingCapacity();
        self.planLoupeRemoval();
        const cursor = self.cursor orelse return self.damages.items;
        const previous = self.coordinator.selection;
        self.coordinator.begin(cursor.global);
        self.planSelectionDamage(previous, self.coordinator.selection);
        return self.damages.items;
    }

    /// Resolve the current gesture. Capture and clipboard side effects remain
    /// the frontend's responsibility.
    pub fn endSelection(self: *Interaction) ?Result {
        const cursor = self.cursor orelse return null;
        return self.coordinator.end(cursor.global);
    }

    pub fn cancel(self: *Interaction) bool {
        return self.coordinator.cancel();
    }

    pub fn isSelecting(self: *const Interaction) bool {
        return self.coordinator.isSelecting();
    }

    /// Render the shared scene for one physical-pixel damage region.
    pub fn render(self: *const Interaction, surface: SurfaceId, canvas: *Canvas, region: Rect) void {
        if (surface >= self.surfaces.len) return;
        const config = self.surfaces[surface].config;
        overlay.renderRegion(canvas, .{
            .baseline = config.baseline,
            .selection = self.selectionPhysical(surface, self.coordinator.selection),
            .cursor = self.cursorPhysical(surface),
            .endpoint_sample = if (self.coordinator.isSelecting()) self.sample else null,
            .ui_scale = config.scale,
        }, region);

        if (self.loupe) |loupe| {
            if (loupe.surface == surface) {
                overlay.renderMagnifier(canvas, loupe.origin, self.sample, config.scale);
            }
        }
    }

    fn appendDamage(self: *Interaction, surface: SurfaceId, rect: Rect) void {
        if (rect.isEmpty()) return;
        self.damages.appendAssumeCapacity(.{ .surface = surface, .rect = rect });
    }

    fn updateLoupe(self: *Interaction, surface: SurfaceId, physical: Point) void {
        const scale = self.surfaces[surface].config.scale;
        sampling.fillSample(&self.sample, self.surfaces[surface].config.baseline, physical);
        const rgb = magnifier.hexAt(self.sample) orelse return;
        const origin = magnifier.windowOrigin(physical, scale);

        if (self.loupe) |previous| {
            if (previous.surface == surface and
                std.meta.eql(previous.rgb, rgb) and
                @abs(previous.origin.x - origin.x) < 0.5 and
                @abs(previous.origin.y - origin.y) < 0.5)
            {
                return;
            }

            const previous_scale = self.surfaces[previous.surface].config.scale;
            const old_rect = magnifier.windowRect(previous.origin, previous_scale).expand(2);
            const new_rect = magnifier.windowRect(origin, scale).expand(2);
            if (previous.surface == surface) {
                self.appendDamage(surface, old_rect.unionWith(new_rect));
            } else {
                self.appendDamage(previous.surface, old_rect);
                self.appendDamage(surface, new_rect);
            }
        } else {
            self.appendDamage(surface, magnifier.windowRect(origin, scale).expand(2));
        }

        self.loupe = .{ .surface = surface, .origin = origin, .rgb = rgb };
    }

    fn planLoupeRemoval(self: *Interaction) void {
        const loupe = self.loupe orelse return;
        const scale = self.surfaces[loupe.surface].config.scale;
        self.appendDamage(loupe.surface, magnifier.windowRect(loupe.origin, scale).expand(2));
        self.loupe = null;
    }

    fn planSelectionDamage(self: *Interaction, previous: ?FRect, next: ?FRect) void {
        for (self.surfaces, 0..) |*surface, index| {
            var damage = Rect{};
            if (self.selectionPhysical(index, previous)) |rect| damage = damage.unionWith(rect);
            const selection = self.selectionPhysical(index, next);
            if (selection) |rect| damage = damage.unionWith(rect);
            if (surface.last_badge) |badge| damage = damage.unionWith(badge);
            surface.last_badge = null;

            if (selection) |selected| {
                if (self.cursorPhysical(index)) |cursor| {
                    if (overlay.sizeBadge(selected, cursor, surface.config.scale, surface.config.baseline.rect())) |badge| {
                        const bounds = badge.bounds();
                        damage = damage.unionWith(bounds.expand(2));
                        surface.last_badge = bounds;
                    }
                }
            }
            if (!damage.isEmpty()) self.appendDamage(index, damage.expand(3));
        }
    }

    fn selectionPhysical(self: *const Interaction, surface: SurfaceId, selection: ?FRect) ?Rect {
        const selected = selection orelse return null;
        const config = self.surfaces[surface].config;
        const physical = Rect.roundF(.{
            .x = (selected.x - config.logical.x) * config.scale,
            .y = (selected.y - config.logical.y) * config.scale,
            .w = selected.w * config.scale,
            .h = selected.h * config.scale,
        });
        if (physical.isEmpty() or !physical.intersects(config.baseline.rect())) return null;
        return physical;
    }

    fn cursorPhysical(self: *const Interaction, surface: SurfaceId) ?Point {
        const cursor = self.cursor orelse return null;
        if (cursor.surface != surface) return null;
        return sampling.toPhysical(self.surfaces[surface].config.scale, cursor.local);
    }
};
