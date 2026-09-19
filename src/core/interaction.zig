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
        self.clearDamages();
        if (surface >= self.surfaces.len or self.coordinator.finished) return self.damages.items;

        const config = self.surfaces[surface].config;
        const global = Point{ .x = config.logical.x + local.x, .y = config.logical.y + local.y };
        self.cursor = .{ .surface = surface, .local = local, .global = global };

        if (self.coordinator.isSelecting()) {
            const previous = self.coordinator.selection;
            _ = self.coordinator.move(global);
            self.planSelectionDamage(previous, self.coordinator.selection);
        } else {
            self.updateLoupe(surface, local);
        }
        return self.damages.items;
    }

    /// Forget a cursor that left a surface and erase its loupe.
    pub fn leaveSurface(self: *Interaction, surface: SurfaceId) []const Damage {
        self.clearDamages();
        if (self.cursor) |cursor| {
            if (cursor.surface == surface) self.cursor = null;
        }
        self.planLoupeRemoval();
        return self.damages.items;
    }

    /// Hide the loupe and begin a click-or-drag gesture at the current cursor.
    pub fn beginSelection(self: *Interaction) []const Damage {
        self.clearDamages();
        self.planLoupeRemoval();
        const cursor = self.cursor orelse return self.damages.items;
        const previous = self.coordinator.selection;
        _ = self.coordinator.begin(cursor.global);
        self.planSelectionDamage(previous, self.coordinator.selection);
        return self.damages.items;
    }

    /// Resolve the current gesture. Capture and clipboard side effects remain
    /// the frontend's responsibility.
    pub fn endSelection(self: *Interaction) ?Result {
        const cursor = self.cursor orelse return null;
        return switch (self.coordinator.end(cursor.global)) {
            .finished => |result| result,
            else => null,
        };
    }

    pub fn cancel(self: *Interaction) bool {
        return switch (self.coordinator.cancel()) {
            .cancelled => true,
            else => false,
        };
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
            .ui_scale = config.scale,
        }, region);

        if (self.loupe) |loupe| {
            if (loupe.surface == surface) {
                overlay.renderMagnifier(canvas, loupe.origin, self.sample, config.scale);
            }
        }
    }

    fn clearDamages(self: *Interaction) void {
        self.damages.clearRetainingCapacity();
    }

    fn appendDamage(self: *Interaction, surface: SurfaceId, rect: Rect) void {
        if (rect.isEmpty()) return;
        self.damages.appendAssumeCapacity(.{ .surface = surface, .rect = rect });
    }

    fn updateLoupe(self: *Interaction, surface: SurfaceId, local: Point) void {
        const config = self.surfaces[surface].config;
        sampling.fillSample(&self.sample, config.baseline, config.scale, local);
        const rgb = magnifier.hexAt(self.sample) orelse return;
        const physical = Point{ .x = local.x * config.scale, .y = local.y * config.scale };
        const origin = magnifier.windowOrigin(physical, config.scale);

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
            const new_rect = magnifier.windowRect(origin, config.scale).expand(2);
            if (previous.surface == surface) {
                self.appendDamage(surface, old_rect.unionWith(new_rect));
            } else {
                self.appendDamage(previous.surface, old_rect);
                self.appendDamage(surface, new_rect);
            }
        } else {
            self.appendDamage(surface, magnifier.windowRect(origin, config.scale).expand(2));
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
            if (self.selectionPhysical(index, next)) |rect| damage = damage.unionWith(rect);
            if (surface.last_badge) |badge| damage = damage.unionWith(badge);
            surface.last_badge = null;

            if (self.selectionPhysical(index, next)) |selection| {
                if (self.cursorPhysical(index)) |cursor| {
                    if (overlay.sizeBadge(selection, cursor, surface.config.scale, surface.config.baseline.rect())) |badge| {
                        damage = damage.unionWith(badge.rect.expand(2));
                        surface.last_badge = badge.rect;
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
        const scale = self.surfaces[surface].config.scale;
        return .{ .x = cursor.local.x * scale, .y = cursor.local.y * scale };
    }
};
