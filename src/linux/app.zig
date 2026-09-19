//! Wayland frontend.
//!
//! How it maps onto the gesture:
//!   * one layer-shell surface per output on the overlay layer, covering the
//!     whole output, painted from a baseline grab taken at startup,
//!   * wl_pointer drives hover (loupe), click (hex) and drag (selection),
//!   * the loupe magnifies the baseline grab, never a live capture, which is
//!     what stops it from magnifying its own overlay,
//!   * the final screenshot is a fresh `zwlr_screencopy` grab taken after the
//!     overlay has been unmapped, so it shows the desktop, not our dimming,
//!   * the result is published on the clipboard through a `wl_data_source` and
//!     the process lingers until the paste happens or another client takes the
//!     selection.

const std = @import("std");
const wl = @import("wl.zig");
const shm_mod = @import("shm.zig");
const capture = @import("capture.zig");
const sampling = @import("../core/sampling.zig");
const geom = @import("../core/geom.zig");
const canvas_mod = @import("../core/canvas.zig");
const color_mod = @import("../core/color.zig");
const gesture = @import("../core/gesture.zig");
const magnifier = @import("../core/magnifier.zig");
const overlay_mod = @import("../core/overlay.zig");
const png = @import("../core/png.zig");
const out = @import("../core/out.zig");
const cli = @import("../core/cli.zig");
const sys = @import("../core/sys.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const Point = geom.Point;
const FRect = geom.FRect;

const namespace = "hex-god-screenshot-master";

const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;

/// Synthetic gestures for development: they drive the very same functions the
/// pointer handlers call, so a click or a drag can be exercised (and screenshoted
/// mid selection) without a mouse or an input injector on the box.
const DevGesture = union(enum) {
    none,
    click: Point,
    drag: struct { start: Point, end: Point, via: ?Point, hold_ms: u64 },
};

fn parseDevGesture(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    remaining: *std.ArrayList([]const u8),
) !DevGesture {
    var click: ?Point = null;
    var drag: ?[4]f64 = null;
    var via: ?Point = null;
    var hold_ms: u64 = 1000;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dev-click")) {
            index += 1;
            if (index >= args.len) return error.MissingPoint;
            click = cli.parsePoint(args[index]) orelse return error.MissingPoint;
        } else if (std.mem.eql(u8, arg, "--dev-drag")) {
            index += 1;
            if (index >= args.len) return error.MissingRect;
            const rect = cli.parseRect(args[index]) orelse return error.MissingRect;
            drag = .{ rect.x, rect.y, rect.maxX(), rect.maxY() };
        } else if (std.mem.eql(u8, arg, "--dev-via")) {
            index += 1;
            if (index >= args.len) return error.MissingPoint;
            via = cli.parsePoint(args[index]) orelse return error.MissingPoint;
        } else if (std.mem.eql(u8, arg, "--dev-hold")) {
            index += 1;
            if (index >= args.len) return error.MissingRect;
            hold_ms = std.fmt.parseInt(u64, args[index], 10) catch return error.MissingRect;
        } else {
            try remaining.append(allocator, arg);
        }
    }

    if (drag) |values| {
        return .{ .drag = .{
            .start = .{ .x = values[0], .y = values[1] },
            .end = .{ .x = values[2], .y = values[3] },
            .via = via,
            .hold_ms = hold_ms,
        } };
    }
    if (click) |point| return .{ .click = point };
    return .none;
}

const clipboard_timeout_ms: i64 = 60_000;
const clipboard_idle_after_send_ms: i64 = 5_000;
const overlay_settle_ms: u64 = 60;

const Output = struct {
    app: *App,
    wl_output: *wl.Obj,
    xdg_output: ?*wl.Obj = null,
    /// Global logical position and size, from xdg_output (or the mode size).
    logical: FRect = .{},
    logical_known: bool = false,
    mode_width: i32 = 0,
    mode_height: i32 = 0,
    mode_known: bool = false,
    /// Physical pixels per logical pixel, derived from the capture size.
    scale: f64 = 1,
    /// The screen as it was before the overlay appeared.
    baseline: ?Canvas = null,
    buffers: [2]shm_mod.ShmBuffer = .{ .{}, .{} },
    have_buffers: bool = false,
    /// Which buffer the next commit uses; the two are alternated.
    buffer_index: usize = 0,
    /// Per-buffer regions that still need composing (output-local physical).
    dirty: [2]std.ArrayList(Rect) = .{ .empty, .empty },
    /// A buffer that has never been committed needs a full paint.
    fresh: [2]bool = .{ true, true },
    /// Where the size badge was last drawn, so the next move can erase it. The
    /// badge sits outside the selection rectangle, so it needs its own damage.
    last_badge: ?Rect = null,
    surface: ?*wl.Obj = null,
    surface_version: u32 = 1,
    layer_surface: ?*wl.Obj = null,
    viewport: ?*wl.Obj = null,
    configured: bool = false,

    fn canvasSize(self: *Output) Rect {
        if (self.baseline) |baseline| {
            return .{ .x = 0, .y = 0, .w = @intCast(baseline.width), .h = @intCast(baseline.height) };
        }
        return .{};
    }

    fn localLogical(self: *Output, global: Point) Point {
        return .{ .x = global.x - self.logical.x, .y = global.y - self.logical.y };
    }

    fn toPhysical(self: *Output, local: Point) Point {
        return .{ .x = local.x * self.scale, .y = local.y * self.scale };
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *wl.Obj,
    registry: ?*wl.Obj = null,
    compositor: ?*wl.Obj = null,
    compositor_version: u32 = 1,
    shm: ?*wl.Obj = null,
    shm_version: u32 = 1,
    layer_shell: ?*wl.Obj = null,
    layer_shell_version: u32 = 1,
    screencopy: ?*wl.Obj = null,
    screencopy_version: u32 = 1,
    xdg_manager: ?*wl.Obj = null,
    xdg_manager_version: u32 = 3,
    viewporter: ?*wl.Obj = null,
    data_device_manager: ?*wl.Obj = null,
    data_device_manager_version: u32 = 1,
    seat: ?*wl.Obj = null,
    seat_version: u32 = 1,
    pointer: ?*wl.Obj = null,
    pointer_version: u32 = 1,
    keyboard: ?*wl.Obj = null,
    keyboard_version: u32 = 1,
    data_device: ?*wl.Obj = null,
    outputs: std.ArrayList(*Output) = .empty,

    // Gesture.
    coordinator: gesture.Coordinator = .{},
    cursor_output: ?*Output = null,
    cursor_local: Point = .{},
    cursor_global: Point = .{},
    selection: ?FRect = null,
    buttons: u32 = 0,
    pointer_serial: u32 = 0,
    last_serial: u32 = 0,

    // Loupe.
    loupe_output: ?*Output = null,
    loupe_origin: ?Point = null,
    loupe_active: bool = false,
    sample: ?Canvas = null,
    last_sample_hex: ?color_mod.Rgb = null,

    // Clipboard.
    clip_source: ?*wl.Obj = null,
    clip_payload: []const u8 = &.{},
    clip_set_ms: i64 = 0,
    clip_last_send_ms: ?i64 = null,
    clip_cancelled: bool = false,

    // Keyboard/cursor.
    xkb_context: ?*anyopaque = null,
    xkb_keymap: ?*anyopaque = null,
    xkb_state: ?*anyopaque = null,
    cursor_surface: ?*wl.Obj = null,
    cursor_buffer: ?*shm_mod.ShmBuffer = null,

    overlays_up: bool = false,
    /// True while a synthetic gesture from --dev-click/--dev-drag is running.
    /// Real pointer events are ignored for the duration: the compositor sends an
    /// enter for the new overlay surface as soon as it appears under the physical
    /// cursor, which would otherwise drag the synthetic selection back to wherever
    /// the mouse actually is and make the harness non-deterministic.
    dev_gesture_active: bool = false,
    quit: bool = false,
    exit_code: u8 = 0,
    pending_screenshot: ?FRect = null,
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(minimal: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var args = try minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // argv[0]
    var raw: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| raw.append(allocator, arg) catch return error.OutOfMemory;
    var rest: std.ArrayList([]const u8) = .empty;
    const dev_gesture = parseDevGesture(allocator, raw.items, &rest) catch {
        out.fail(
            "--dev-click X,Y | --dev-drag X,Y,W,H | --dev-via X,Y | --dev-hold MS\n",
            .{},
        );
        std.process.exit(2);
    };

    const options = switch (cli.parse(rest.items)) {
        .options => |parsed| parsed,
        .help => {
            cli.printUsage();
            return;
        },
        .invalid => {
            cli.printUsage();
            std.process.exit(2);
        },
    };

    const display = wl.wl_display_connect(null) orelse {
        out.fail("cannot connect to a wayland compositor (is WAYLAND_DISPLAY set?)\n", .{});
        std.process.exit(1);
    };

    var app = App{ .allocator = allocator, .display = display };
    defer wl.wl_display_disconnect(display);

    try connect(&app);
    try captureBaselines(&app);

    switch (options.mode) {
        .info => {
            for (app.outputs.items) |o| {
                out.print(
                    "output {d}x{d} logical at {d},{d} scale {d:.3} baseline {d}x{d}\n",
                    .{
                        @as(i64, @intFromFloat(o.logical.w)),
                        @as(i64, @intFromFloat(o.logical.h)),
                        @as(i64, @intFromFloat(o.logical.x)),
                        @as(i64, @intFromFloat(o.logical.y)),
                        o.scale,
                        o.baseline.?.width,
                        o.baseline.?.height,
                    },
                );
            }
        },
        .pick => {
            const point = options.pick.?;
            const rgb = pickColor(&app, point) orelse {
                out.fail("no output contains {d},{d}\n", .{ point.x, point.y });
                std.process.exit(1);
            };
            const hex = color_mod.hexString(rgb);
            out.print("{s}\n", .{hex});
            serveClipboard(&app, "text/plain;charset=utf-8", &hex);
        },
        .shot => {
            var canvas = try captureScreenshot(&app, options.shot.?);
            defer canvas.deinit();
            const bytes = try png.encode(allocator, canvas);
            out.print("Screenshot copied to clipboard\n", .{});
            serveClipboard(&app, "image/png", bytes);
        },
        .interactive => {
            try startOverlay(&app);
            switch (dev_gesture) {
                .none => try eventLoop(&app),
                .click => |point| {
                    app.dev_gesture_active = true;
                    devClick(&app, point);
                },
                .drag => |drag| {
                    app.dev_gesture_active = true;
                    devDrag(&app, drag.start, drag.via, drag.end, drag.hold_ms);
                    app.dev_gesture_active = false;
                },
            }
            try eventLoop(&app);
            teardownOverlay(&app);
        },
    }

    if (options.mode != .interactive) {
        try eventLoop(&app);
    }
    if (app.exit_code != 0) std.process.exit(app.exit_code);
}

// ---------------------------------------------------------------------------
// Connection setup
// ---------------------------------------------------------------------------

fn connect(self: *App) !void {
    self.registry = wl.getRegistry(self.display, 1) orelse return error.NoRegistry;
    wl.addListener(self.registry.?, &registry_listener, self);
    try roundtrip(self);

    if (self.compositor == null or self.shm == null or self.screencopy == null) {
        out.fail(
            "the compositor is missing a required protocol (compositor/shm/screencopy)\n",
            .{},
        );
        return error.MissingProtocols;
    }

    // xdg-output for real logical geometry; without it we fall back to the
    // output's mode size, which is only correct at scale 1.
    if (self.xdg_manager) |manager| {
        for (self.outputs.items) |o| {
            const xdg = wl.xdgOutputManagerGetOutput(manager, self.xdg_manager_version, o.wl_output) orelse continue;
            o.xdg_output = xdg;
            wl.addListener(xdg, &xdg_output_listener, o);
        }
        try roundtrip(self);
    }

    // A pointer and a keyboard exist only once the seat advertises them.
    if (self.seat) |seat| {
        if (self.data_device_manager) |manager| {
            self.data_device = wl.dataDeviceManagerGetDevice(manager, self.data_device_manager_version, seat);
            if (self.data_device) |device| wl.addListener(device, &data_device_listener, self);
        }
        try roundtrip(self);
    }

    for (self.outputs.items) |o| {
        if (!o.logical_known and o.mode_known) {
            o.logical = .{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(o.mode_width),
                .h = @floatFromInt(o.mode_height),
            };
        }
    }
}

fn roundtrip(self: *App) !void {
    if (wl.wl_display_roundtrip(self.display) < 0) return error.Disconnected;
}

/// Grab every output once. This baseline is what the overlay is composed from
/// and what the loupe magnifies, so the loupe can never magnify itself.
fn captureBaselines(self: *App) !void {
    for (self.outputs.items) |o| {
        var captured = capture.captureOutput(
            self.display,
            self.screencopy.?,
            self.screencopy_version,
            self.shm.?,
            self.shm_version,
            o.wl_output,
        ) catch |err| {
            out.fail("could not capture output: {t}\n", .{err});
            return err;
        };
        defer captured.destroy();

        const baseline = try capture.toCanvas(self.allocator, &captured);
        o.baseline = baseline;
        if (o.logical.w > 0) {
            o.scale = @as(f64, @floatFromInt(baseline.width)) / o.logical.w;
        }
        if (!o.logical_known) {
            o.logical = .{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(baseline.width),
                .h = @floatFromInt(baseline.height),
            };
        }
    }
}

// ---------------------------------------------------------------------------
// Overlay lifecycle
// ---------------------------------------------------------------------------

fn startOverlay(self: *App) !void {
    if (self.layer_shell == null) {
        out.fail("the compositor does not support wlr-layer-shell\n", .{});
        return error.MissingProtocols;
    }

    self.sample = try Canvas.init(self.allocator, magnifier.sample_side, magnifier.sample_side);
    try createCursor(self);

    for (self.outputs.items) |o| {
        const surface = wl.compositorCreateSurface(self.compositor.?, self.compositor_version) orelse
            return error.CreateSurfaceFailed;
        o.surface = surface;
        o.surface_version = wl.wl_proxy_get_version(surface);
        wl.surfaceSetBufferScale(surface, 1);

        const layer_surface = wl.layerShellGetLayerSurface(
            self.layer_shell.?,
            self.layer_shell_version,
            surface,
            o.wl_output,
            wl.layer_overlay,
            namespace,
        ) orelse return error.CreateLayerSurfaceFailed;
        o.layer_surface = layer_surface;
        wl.addListener(layer_surface, &layer_listener, o);

        wl.layerSurfaceSetSize(
            layer_surface,
            @intFromFloat(@max(1, o.logical.w)),
            @intFromFloat(@max(1, o.logical.h)),
        );
        wl.layerSurfaceSetAnchor(layer_surface, wl.anchor_top | wl.anchor_left);
        wl.layerSurfaceSetExclusiveZone(layer_surface, -1);
        wl.layerSurfaceSetKeyboardInteractivity(layer_surface, wl.keyboard_interactivity_exclusive);

        if (self.viewporter) |viewporter| {
            const viewport = wl.viewporterGetViewport(viewporter, 1, surface);
            if (viewport) |vp| {
                o.viewport = vp;
                wl.viewportSetDestination(
                    vp,
                    @intFromFloat(@max(1, o.logical.w)),
                    @intFromFloat(@max(1, o.logical.h)),
                );
            }
        }

        wl.surfaceCommit(surface);
    }

    try roundtrip(self); // configure events
    self.overlays_up = true;

    for (self.outputs.items) |o| {
        if (!o.configured) {
            out.fail("warning: an output was never configured, skipping it\n", .{});
            continue;
        }
        const size = o.canvasSize();
        for (&o.buffers) |*buffer| {
            buffer.create(
                self.shm.?,
                self.shm_version,
                @intCast(size.w),
                @intCast(size.h),
                wl.shm_format_argb8888,
                @intCast(size.w * 4),
            ) catch |err| {
                out.fail("could not create overlay buffer: {t}\n", .{err});
                return err;
            };
        }
        o.have_buffers = true;
        flushOutput(o);
    }
    try roundtrip(self);
}

fn teardownOverlay(self: *App) void {
    for (self.outputs.items) |o| {
        if (o.layer_surface) |layer_surface| wl.layerSurfaceDestroy(layer_surface);
        if (o.surface) |surface| wl.surfaceDestroy(surface);
        o.layer_surface = null;
        o.surface = null;
        o.configured = false;
        for (&o.buffers) |*buffer| {
            if (buffer.buffer != null) buffer.destroy();
        }
        o.have_buffers = false;
        o.fresh = .{ true, true };
        o.last_badge = null;
        for (&o.dirty) |*dirty| dirty.clearRetainingCapacity();
    }
    if (self.cursor_surface) |surface| {
        wl.surfaceDestroy(surface);
        self.cursor_surface = null;
    }
    if (self.cursor_buffer) |buffer| {
        buffer.destroy();
        self.cursor_buffer = null;
    }
    self.loupe_active = false;
    self.overlays_up = false;
}

/// Wait for the compositor to actually drop our surfaces, then capture.
fn settle(self: *App) void {
    roundtrip(self) catch {};
    sys.sleepMs(overlay_settle_ms);
    roundtrip(self) catch {};
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

fn repaintOutput(self: *App, o: *Output, region: Rect) void {
    _ = self;
    if (!o.configured or !o.have_buffers) return;
    const clipped = region.clamped(
        @intCast(o.baseline.?.width),
        @intCast(o.baseline.?.height),
    );
    if (clipped.isEmpty()) return;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        o.dirty[i].append(o.app.allocator, clipped) catch return;
    }
    flushOutput(o);
}

fn flushAll(self: *App) void {
    for (self.outputs.items) |o| flushOutput(o);
}

/// Compose the pending regions into a buffer and commit it.
///
/// A released buffer is preferred, but never waited for. Hyprland can hold the
/// buffer it is displaying for a long time, so gating on `wl_buffer.release` (or
/// on a `wl_surface.frame` callback, which it also stops delivering for these
/// surfaces) means the client waits forever and stops painting - that is how the
/// selection box went missing. Alternating regardless keeps frames flowing; the
/// worst case is that a frame lands in a buffer the compositor is still reading.
fn flushOutput(o: *Output) void {
    if (!o.configured or !o.have_buffers) return;

    const other = 1 - o.buffer_index;
    const index = if (o.buffers[o.buffer_index].released) o.buffer_index else other;
    const buffer = &o.buffers[index];

    var canvas = buffer.canvas();
    canvas.clearClip();

    var regions: [MAX_DIRTY]Rect = undefined;
    var count: usize = 0;
    if (o.fresh[index]) {
        compose(o, &canvas, canvas.rect());
        regions[0] = canvas.rect();
        count = 1;
        o.fresh[index] = false;
    } else {
        const pending = o.dirty[index].items;
        if (pending.len == 0) return;
        for (pending, 0..) |region, i| {
            if (i >= MAX_DIRTY) break;
            compose(o, &canvas, region);
            regions[i] = region;
            count = i + 1;
        }
    }
    o.dirty[index].clearRetainingCapacity();

    wl.surfaceAttach(o.surface.?, buffer.buffer.?, 0, 0);
    var i: usize = 0;
    while (i < count) : (i += 1) damageBuffer(o, regions[i]);
    wl.surfaceCommit(o.surface.?);
    buffer.released = false;
    o.buffer_index = 1 - index;
}

/// Upper bound on regions composed in one commit; anything past it is folded
/// into the last rectangle so no region is silently dropped.
const MAX_DIRTY = 32;

fn damageBuffer(o: *Output, region: Rect) void {
    if (o.surface_version >= 4) {
        const args = [_]wl.Argument{
            .{ .i = region.x },
            .{ .i = region.y },
            .{ .i = region.w },
            .{ .i = region.h },
        };
        _ = wl.request(o.surface.?, 9, &args); // wl_surface.damage_buffer
    } else {
        // Fall back to damage in surface coordinates: the whole thing.
        wl.surfaceDamage(
            o.surface.?,
            0,
            0,
            @intFromFloat(o.logical.w),
            @intFromFloat(o.logical.h),
        );
    }
}

/// Paint one region of one output from the baseline plus the current gesture.
fn compose(o: *Output, canvas: *Canvas, region: Rect) void {
    const app = o.app;
    const scene = overlay_mod.Scene{
        .baseline = &o.baseline.?,
        .selection = selectionPhysicalOf(o, o.app.selection),
        .cursor = cursorPhysical(o),
        .ui_scale = o.scale,
    };
    overlay_mod.renderRegion(canvas, scene, region);
    if (app.loupe_active and app.loupe_output == o) {
        if (app.loupe_origin) |origin| {
            if (app.sample) |sample| overlay_mod.renderMagnifier(canvas, origin, sample, o.scale);
        }
    }
}

/// Cursor position in this output's physical pixels, when the pointer is here.
fn cursorPhysical(o: *Output) ?Point {
    if (o.app.cursor_output != o) return null;
    return o.toPhysical(o.app.cursor_local);
}

// ---------------------------------------------------------------------------
// Gesture
// ---------------------------------------------------------------------------

fn updateCursor(self: *App, o: *Output, local: Point) void {
    self.cursor_output = o;
    self.cursor_local = local;
    self.cursor_global = .{ .x = o.logical.x + local.x, .y = o.logical.y + local.y };

    if (self.coordinator.isSelecting()) {
        // Drive the state machine on every move, otherwise the selection stays
        // the zero sized rectangle `begin` created and no box is ever drawn.
        _ = self.coordinator.move(self.cursor_global);
        updateSelection(self);
    } else {
        updateLoupe(self);
    }
}

fn updateLoupe(self: *App) void {
    const o = self.cursor_output orelse return;
    var sample = self.sample orelse return;
    const baseline = &(o.baseline orelse return);

    sampling.fillSample(&sample, baseline, o.scale, self.cursor_local);
    const rgb = magnifier.hexAt(sample) orelse return;

    const physical = o.toPhysical(self.cursor_local);
    const origin = magnifier.windowOrigin(physical, o.scale);

    const previous_output = self.loupe_output;
    const previous_origin = self.loupe_origin;
    const same_spot = self.loupe_active and previous_output == o and
        self.last_sample_hex != null and
        std.meta.eql(self.last_sample_hex.?, rgb);
    if (same_spot) {
        if (previous_origin) |old| {
            if (@abs(old.x - origin.x) < 0.5 and @abs(old.y - origin.y) < 0.5) return;
        }
    }

    self.last_sample_hex = rgb;
    self.loupe_output = o;
    self.loupe_origin = origin;
    self.loupe_active = true;

    var damage = magnifier.windowRect(origin, o.scale).expand(2);
    if (previous_output) |old_output| {
        if (previous_origin) |old| {
            damage = damage.unionWith(magnifier.windowRect(old, old_output.scale).expand(2));
        }
    }
    // If the pointer moved to another output, erase the loupe there too.
    if (previous_output) |old_output| {
        if (old_output != o and previous_origin != null) {
            repaintOutput(self, old_output, magnifier.windowRect(previous_origin.?, old_output.scale).expand(2));
        }
    }
    repaintOutput(self, o, damage);
}

fn hideLoupe(self: *App) void {
    if (!self.loupe_active) return;
    self.loupe_active = false;
    self.last_sample_hex = null;
    if (self.loupe_output) |o| {
        if (self.loupe_origin) |origin| {
            repaintOutput(self, o, magnifier.windowRect(origin, o.scale).expand(2));
        }
    }
    self.loupe_output = null;
    self.loupe_origin = null;
}

fn updateSelection(self: *App) void {
    const next = self.coordinator.selection;
    const previous = self.selection;
    self.selection = next;

    for (self.outputs.items) |o| {
        var damage = Rect{};
        if (previous) |rect| {
            if (selectionPhysicalOf(o, rect)) |physical| damage = damage.unionWith(physical);
        }
        if (next) |rect| {
            if (selectionPhysicalOf(o, rect)) |physical| damage = damage.unionWith(physical);
        }
        // The size badge is drawn beside the cursor, outside the selection, so it
        // has to be damaged explicitly or it is composed nowhere.
        if (o.last_badge) |previous_badge| damage = damage.unionWith(previous_badge);
        o.last_badge = null;
        if (next) |rect| {
            if (selectionPhysicalOf(o, rect)) |physical| {
                if (cursorPhysical(o)) |cursor| {
                    if (overlay_mod.sizeBadge(physical, cursor, o.scale, o.canvasSize())) |badge| {
                        damage = damage.unionWith(badge.rect.expand(2));
                        o.last_badge = badge.rect;
                    }
                }
            }
        }
        if (!damage.isEmpty()) repaintOutput(self, o, damage.expand(3));
    }
}

/// A global logical selection converted to this output's physical pixels, or
/// null when it misses this output entirely.
fn selectionPhysicalOf(o: *Output, selection: ?FRect) ?Rect {
    const selection_rect = selection orelse return null;
    const local = FRect{
        .x = selection_rect.x - o.logical.x,
        .y = selection_rect.y - o.logical.y,
        .w = selection_rect.w,
        .h = selection_rect.h,
    };
    const physical = Rect.roundF(.{
        .x = local.x * o.scale,
        .y = local.y * o.scale,
        .w = local.w * o.scale,
        .h = local.h * o.scale,
    });
    if (physical.isEmpty()) return null;
    const canvas = o.canvasSize();
    if (!physical.intersects(.{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h })) return null;
    return physical;
}

fn beginSelection(self: *App) void {
    _ = self.coordinator.begin(self.cursor_global);
    self.selection = self.coordinator.selection;
    updateSelection(self);
}

fn endSelection(self: *App) void {
    const event = self.coordinator.end(self.cursor_global);
    self.selection = self.coordinator.selection;
    switch (event) {
        .finished => |result| finish(self, result),
        else => {},
    }
}

fn cancel(self: *App) void {
    if (self.coordinator.finished) return;
    self.coordinator.finished = true;
    teardownOverlay(self);
    self.quit = true;
}

/// Move the synthetic cursor to a global logical point, resolving which output
/// it lands on. Only used by the dev gestures.
fn devMoveCursor(self: *App, global: Point) void {
    for (self.outputs.items) |o| {
        const local = o.localLogical(global);
        if (local.x < 0 or local.y < 0) continue;
        if (local.x >= o.logical.w or local.y >= o.logical.h) continue;
        updateCursor(self, o, local);
        return;
    }
    out.fail("no output contains {d},{d}\n", .{ global.x, global.y });
}

/// Exactly what a press-and-release in place does: a click that resolves to a
/// colour.
fn devClick(self: *App, point: Point) void {
    devMoveCursor(self, point);
    if (self.cursor_output == null) return;
    hideLoupe(self);
    beginSelection(self);
    endSelection(self);
}

/// Exactly what a press, drag and release does, with a pause before the release
/// so the selection box can be photographed mid gesture. The pause pumps the
/// event loop, because a commit is only sent to the compositor on the next
/// flush: without that the box would sit in our outgoing buffer and never be
/// seen on screen.
fn devDrag(self: *App, start: Point, via: ?Point, end: Point, hold_ms: u64) void {
    devMoveCursor(self, start);
    if (self.cursor_output == null) return;
    hideLoupe(self);
    beginSelection(self);
    if (via) |mid| {
        devMoveCursor(self, mid);
        out.print("dev: drag {d},{d} -> {d},{d}, holding\n", .{ start.x, start.y, mid.x, mid.y });
        holdWithPump(self, hold_ms);
    }
    devMoveCursor(self, end);
    out.print("dev: drag {d},{d} -> {d},{d}, holding\n", .{ start.x, start.y, end.x, end.y });
    holdWithPump(self, hold_ms);
    out.print("dev: releasing at {d},{d}\n", .{ end.x, end.y });
    endSelection(self);
}

fn holdWithPump(self: *App, milliseconds: u64) void {
    var remaining = milliseconds;
    while (remaining > 0) : (remaining -= @min(remaining, 20)) {
        wl.pump(self.display, 20) catch return;
        flushAll(self);
    }
}

fn finish(self: *App, result: gesture.Result) void {
    hideLoupe(self);
    switch (result) {
        .color => |point| {
            const rgb = pickColor(self, point) orelse {
                out.fail("the pixel colour could not be read\n", .{});
                self.exit_code = 1;
                self.quit = true;
                return;
            };
            const hex = color_mod.hexString(rgb);
            out.print("{s}\n", .{hex});
            teardownOverlay(self);
            settle(self);
            serveClipboard(self, "text/plain;charset=utf-8", &hex);
        },
        .screenshot => |rect| {
            self.pending_screenshot = rect;
        },
    }
}

/// Copy a drag selection and publish it, after the overlay is out of the way.
fn finishScreenshot(self: *App, rect: FRect) void {
    teardownOverlay(self);
    settle(self);
    const canvas = captureScreenshot(self, rect) catch |err| {
        out.fail("screenshot failed: {t}\n", .{err});
        self.exit_code = 1;
        self.quit = true;
        return;
    };
    const bytes = png.encode(self.allocator, canvas) catch |err| {
        out.fail("png encoding failed: {t}\n", .{err});
        self.exit_code = 1;
        self.quit = true;
        return;
    };
    out.print("Screenshot copied to clipboard\n", .{});
    serveClipboard(self, "image/png", bytes);
}

fn pickColor(self: *App, global: Point) ?color_mod.Rgb {
    for (self.outputs.items) |o| {
        const baseline = o.baseline orelse continue;
        const local = o.localLogical(global);
        if (local.x < 0 or local.y < 0) continue;
        if (local.x >= o.logical.w or local.y >= o.logical.h) continue;
        const physical = o.toPhysical(local);
        if (physical.x < 0 or physical.y < 0) continue;
        if (physical.x >= @as(f64, @floatFromInt(baseline.width))) continue;
        if (physical.y >= @as(f64, @floatFromInt(baseline.height))) continue;
        return sampling.sampleHex(&baseline, o.scale, local);
    }
    return null;
}

/// Capture a global logical rectangle.
///
/// The common case - the whole rectangle on one output - keeps the captured
/// pixels exactly as the compositor produced them, which is what makes the
/// result byte-identical to other screencopy clients. Only a selection spanning
/// displays needs a composed image, since the two captures have to be placed in
/// one common pixel grid.
fn captureScreenshot(self: *App, rect: FRect) !Canvas {
    var single: ?*Output = null;
    var count: usize = 0;
    for (self.outputs.items) |o| {
        if (intersectionOf(o, rect) == null) continue;
        single = o;
        count += 1;
    }
    if (count == 1) {
        const o = single.?;
        const intersection = intersectionOf(o, rect).?;
        var captured = try captureRegionOf(self, o, intersection);
        defer captured.destroy();
        return capture.toCanvas(self.allocator, &captured);
    }

    var scale: f64 = 1;
    for (self.outputs.items) |o| scale = @max(scale, o.scale);

    const width: u32 = @intFromFloat(@max(1, @round(rect.w * scale)));
    const height: u32 = @intFromFloat(@max(1, @round(rect.h * scale)));
    var output_canvas = try Canvas.init(self.allocator, width, height);
    errdefer self.allocator.free(output_canvas.pixels);

    for (self.outputs.items) |o| {
        const intersection = intersectionOf(o, rect) orelse continue;
        var captured = try captureRegionOf(self, o, intersection);
        defer captured.destroy();

        var image = try capture.toCanvas(self.allocator, &captured);
        const destination = Rect.roundF(.{
            .x = (intersection.x - rect.x) * scale,
            .y = (intersection.y - rect.y) * scale,
            .w = intersection.w * scale,
            .h = intersection.h * scale,
        });
        output_canvas.blitNearest(image, destination);
        image.deinit();
    }
    return output_canvas;
}

/// The part of `rect` that lands on `o`, in global logical coordinates.
fn intersectionOf(o: *Output, rect: FRect) ?FRect {
    const intersection = FRect{
        .x = @max(rect.x, o.logical.x),
        .y = @max(rect.y, o.logical.y),
        .w = @min(rect.maxX(), o.logical.maxX()) - @max(rect.x, o.logical.x),
        .h = @min(rect.maxY(), o.logical.maxY()) - @max(rect.y, o.logical.y),
    };
    if (intersection.isEmpty()) return null;
    return intersection;
}

fn captureRegionOf(self: *App, o: *Output, intersection: FRect) !shm_mod.ShmBuffer {
    const local = FRect{
        .x = intersection.x - o.logical.x,
        .y = intersection.y - o.logical.y,
        .w = intersection.w,
        .h = intersection.h,
    };
    return capture.captureRegion(
        self.display,
        self.screencopy.?,
        self.screencopy_version,
        self.shm.?,
        self.shm_version,
        o.wl_output,
        local,
    ) catch |err| {
        out.fail("capture of a display region failed: {t}\n", .{err});
        return err;
    };
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

fn serveClipboard(self: *App, mime: [:0]const u8, payload: []const u8) void {
    const manager = self.data_device_manager orelse {
        out.fail("this compositor has no clipboard support\n", .{});
        self.exit_code = 1;
        self.quit = true;
        return;
    };
    const device = self.data_device orelse {
        out.fail("this compositor has no clipboard device\n", .{});
        self.exit_code = 1;
        self.quit = true;
        return;
    };

    const source = wl.dataDeviceManagerCreateSource(manager, self.data_device_manager_version) orelse {
        self.quit = true;
        return;
    };
    // The payload outlives the caller's stack frame: this process keeps serving
    // the selection until the paste happens, so it has to own the bytes.
    const owned = self.allocator.dupe(u8, payload) catch {
        self.quit = true;
        return;
    };
    wl.addListener(source, &data_source_listener, self);
    wl.dataSourceOffer(source, mime.ptr);
    wl.dataDeviceSetSelection(device, source, self.last_serial);
    _ = wl.wl_display_flush(self.display);

    self.clip_source = source;
    self.clip_payload = owned;
    self.clip_set_ms = nowMs();
    self.clip_last_send_ms = null;
    self.clip_cancelled = false;
}

fn clipboardExpired(self: *App) bool {
    if (self.clip_source == null) return false;
    const now = nowMs();
    if (self.clip_last_send_ms) |sent| {
        return now - sent > clipboard_idle_after_send_ms;
    }
    return now - self.clip_set_ms > clipboard_timeout_ms;
}

fn nowMs() i64 {
    return sys.monotonicMs();
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

fn eventLoop(self: *App) !void {
    while (!self.quit) {
        wl.pump(self.display, 40) catch {
            self.quit = true;
            return;
        };
        // A repaint requested while both buffers were still being read by the
        // compositor is dropped by flushOutput; this retries it as soon as one
        // comes back. Without it a dropped frame - a selection box included -
        // would sit in the dirty list until the next pointer event.
        flushAll(self);
        if (self.pending_screenshot) |rect| {
            self.pending_screenshot = null;
            finishScreenshot(self, rect);
        }
        if (self.clip_cancelled) {
            self.quit = true;
        }
        if (clipboardExpired(self)) {
            self.quit = true;
        }
        // Nothing to wait for and nothing on screen: bail out rather than
        // lingering invisibly.
        if (!self.overlays_up and self.clip_source == null) self.quit = true;
    }
}

// ---------------------------------------------------------------------------
// Cursor theme: a hand drawn crosshair, since we cannot rely on a cursor theme
// ---------------------------------------------------------------------------

fn createCursor(self: *App) !void {
    const size: u32 = 33;
    const surface = wl.compositorCreateSurface(self.compositor.?, self.compositor_version) orelse
        return error.CreateSurfaceFailed;
    self.cursor_surface = surface;

    const buffer = try self.allocator.create(shm_mod.ShmBuffer);
    buffer.* = .{};
    try buffer.create(
        self.shm.?,
        self.shm_version,
        size,
        size,
        wl.shm_format_argb8888,
        size * 4,
    );
    const canvas = buffer.canvas();
    const ink = color_mod.solid(.{ .r = 255, .g = 255, .b = 255 });
    const outline = color_mod.black(255);
    const centre: i32 = @intCast(size / 2);
    const arm: i32 = 7;
    // Heavy black outline first, then a white cross on top.
    canvas.fillRect(.{ .x = centre - 1, .y = centre - arm, .w = 3, .h = arm * 2 + 1 }, outline);
    canvas.fillRect(.{ .x = centre - arm, .y = centre - 1, .w = arm * 2 + 1, .h = 3 }, outline);
    canvas.fillRect(.{ .x = centre, .y = centre - arm, .w = 1, .h = arm * 2 + 1 }, ink);
    canvas.fillRect(.{ .x = centre - arm, .y = centre, .w = arm * 2 + 1, .h = 1 }, ink);
    canvas.fillRect(.{ .x = centre, .y = centre, .w = 1, .h = 1 }, outline);

    wl.surfaceAttach(surface, buffer.buffer.?, 0, 0);
    wl.surfaceCommit(surface);
    self.cursor_buffer = buffer;
}

fn applyCursor(self: *App) void {
    const surface = self.cursor_surface orelse return;
    const pointer = self.pointer orelse return;
    if (self.pointer_version < 1) return;
    wl.pointerSetCursor(pointer, self.pointer_serial, surface, 16, 16);
}

// ---------------------------------------------------------------------------
// Listeners
// ---------------------------------------------------------------------------

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*wl.Obj, u32, ?[*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*wl.Obj, u32) callconv(.c) void,
};

const registry_listener = RegistryListener{
    .global = onRegistryGlobal,
    .global_remove = @ptrCast(&wl.noop),
};

fn onRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*wl.Obj,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const registry_obj = registry.?;
    const iface = std.mem.span(interface.?);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        app.compositor_version = @min(version, 6);
        app.compositor = wl.bind(registry_obj, name, &wl.wl_compositor_interface, app.compositor_version);
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        app.shm_version = @min(version, 1);
        app.shm = wl.bind(registry_obj, name, &wl.wl_shm_interface, app.shm_version);
    } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
        app.layer_shell_version = @min(version, 5);
        app.layer_shell = wl.bind(registry_obj, name, &wl.zwlr_layer_shell_v1_interface, app.layer_shell_version);
    } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
        app.screencopy_version = @min(version, 3);
        app.screencopy = wl.bind(registry_obj, name, &wl.zwlr_screencopy_manager_v1_interface, app.screencopy_version);
    } else if (std.mem.eql(u8, iface, "zxdg_output_manager_v1")) {
        app.xdg_manager_version = @min(version, 3);
        app.xdg_manager = wl.bind(registry_obj, name, &wl.zxdg_output_manager_v1_interface, app.xdg_manager_version);
    } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
        app.viewporter = wl.bind(registry_obj, name, &wl.wp_viewporter_interface, @min(version, 1));
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        app.data_device_manager_version = @min(version, 3);
        app.data_device_manager = wl.bind(registry_obj, name, &wl.wl_data_device_manager_interface, app.data_device_manager_version);
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        app.seat_version = @min(version, 5);
        const seat = wl.bind(registry_obj, name, &wl.wl_seat_interface, app.seat_version);
        app.seat = seat;
        if (seat) |s| wl.addListener(s, &seat_listener, app);
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        const output_proxy = wl.bind(registry_obj, name, &wl.wl_output_interface, @min(version, 2)) orelse return;
        const output = app.allocator.create(Output) catch return;
        output.* = .{ .app = app, .wl_output = output_proxy };
        wl.addListener(output_proxy, &output_listener, output);
        app.outputs.append(app.allocator, output) catch return;
    }
}

const SeatListener = extern struct {
    capabilities: *const fn (?*anyopaque, ?*wl.Obj, u32) callconv(.c) void,
    name: *const fn () callconv(.c) void,
};

const seat_listener = SeatListener{
    .capabilities = onSeatCapabilities,
    .name = @ptrCast(&wl.noop),
};

fn onSeatCapabilities(data: ?*anyopaque, seat: ?*wl.Obj, capabilities: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));

    if (capabilities & wl.seat_capability_pointer != 0 and app.pointer == null) {
        app.pointer_version = @min(app.seat_version, 5);
        const pointer = wl.seatGetPointer(seat.?, app.pointer_version);
        app.pointer = pointer;
        if (pointer) |p| wl.addListener(p, &pointer_listener, app);
    }
    if (capabilities & wl.seat_capability_keyboard != 0 and app.keyboard == null) {
        app.keyboard_version = @min(app.seat_version, 5);
        const keyboard = wl.seatGetKeyboard(seat.?, app.keyboard_version);
        app.keyboard = keyboard;
        if (keyboard) |k| wl.addListener(k, &keyboard_listener, app);
    }
}

const OutputListener = extern struct {
    geometry: *const fn (?*anyopaque, ?*wl.Obj, i32, i32, i32, i32, i32, ?[*:0]const u8, ?[*:0]const u8, i32) callconv(.c) void,
    mode: *const fn (?*anyopaque, ?*wl.Obj, u32, i32, i32, i32) callconv(.c) void,
    done: *const fn () callconv(.c) void,
    scale: *const fn (?*anyopaque, ?*wl.Obj, i32) callconv(.c) void,
};

const output_listener = OutputListener{
    .geometry = @ptrCast(&wl.noop),
    .mode = onOutputMode,
    .done = @ptrCast(&wl.noop),
    .scale = @ptrCast(&wl.noop),
};

fn onOutputMode(
    data: ?*anyopaque,
    output: ?*wl.Obj,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = output;
    _ = refresh;
    const self: *Output = @ptrCast(@alignCast(data.?));
    // Bit 0 is "current"; prefer it, but take anything before one arrives.
    if (flags & 1 != 0 or !self.mode_known) {
        self.mode_width = width;
        self.mode_height = height;
        self.mode_known = true;
    }
}

const XdgOutputListener = extern struct {
    log: *const fn (?*anyopaque, ?*wl.Obj, i32, i32, i32, i32) callconv(.c) void,
    size: *const fn (?*anyopaque, ?*wl.Obj, i32, i32) callconv(.c) void,
    done: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
    name: *const fn () callconv(.c) void,
    description: *const fn () callconv(.c) void,
};

const xdg_output_listener = XdgOutputListener{
    .log = onXdgLog,
    .size = onXdgSize,
    .done = onXdgDone,
    .name = @ptrCast(&wl.noop),
    .description = @ptrCast(&wl.noop),
};

fn onXdgLog(data: ?*anyopaque, xdg: ?*wl.Obj, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    _ = xdg;
    const self: *Output = @ptrCast(@alignCast(data.?));
    self.logical.x = @floatFromInt(x);
    self.logical.y = @floatFromInt(y);
    if (w > 0) self.logical.w = @floatFromInt(w);
    if (h > 0) self.logical.h = @floatFromInt(h);
}

fn onXdgSize(data: ?*anyopaque, xdg: ?*wl.Obj, w: i32, h: i32) callconv(.c) void {
    _ = xdg;
    const self: *Output = @ptrCast(@alignCast(data.?));
    if (w > 0) self.logical.w = @floatFromInt(w);
    if (h > 0) self.logical.h = @floatFromInt(h);
    self.logical_known = true;
}

fn onXdgDone(data: ?*anyopaque, xdg: ?*wl.Obj) callconv(.c) void {
    _ = xdg;
    const self: *Output = @ptrCast(@alignCast(data.?));
    if (self.logical.w > 0 and self.logical.h > 0) self.logical_known = true;
}

const LayerSurfaceListener = extern struct {
    configure: *const fn (?*anyopaque, ?*wl.Obj, u32, u32, u32) callconv(.c) void,
    closed: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
};

const layer_listener = LayerSurfaceListener{
    .configure = onLayerConfigure,
    .closed = onLayerClosed,
};

fn onLayerConfigure(
    data: ?*anyopaque,
    layer_surface: ?*wl.Obj,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const self: *Output = @ptrCast(@alignCast(data.?));
    if (width > 0) self.logical.w = @floatFromInt(width);
    if (height > 0) self.logical.h = @floatFromInt(height);
    wl.layerSurfaceAckConfigure(layer_surface.?, serial);
    self.configured = true;
}

fn onLayerClosed(data: ?*anyopaque, layer_surface: ?*wl.Obj) callconv(.c) void {
    _ = layer_surface;
    const self: *Output = @ptrCast(@alignCast(data.?));
    self.app.quit = true;
}

const PointerListener = extern struct {
    enter: *const fn (?*anyopaque, ?*wl.Obj, u32, ?*wl.Obj, i32, i32) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*wl.Obj, u32, ?*wl.Obj) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*wl.Obj, u32, i32, i32) callconv(.c) void,
    button: *const fn (?*anyopaque, ?*wl.Obj, u32, u32, u32, u32) callconv(.c) void,
    axis: *const fn () callconv(.c) void,
    frame: *const fn () callconv(.c) void,
    axis_source: *const fn () callconv(.c) void,
    axis_stop: *const fn () callconv(.c) void,
    axis_discrete: *const fn () callconv(.c) void,
    axis_value120: *const fn () callconv(.c) void,
    axis_relative_direction: *const fn () callconv(.c) void,
};

const pointer_listener = PointerListener{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = @ptrCast(&wl.noop),
    .frame = @ptrCast(&wl.noop),
    .axis_source = @ptrCast(&wl.noop),
    .axis_stop = @ptrCast(&wl.noop),
    .axis_discrete = @ptrCast(&wl.noop),
    .axis_value120 = @ptrCast(&wl.noop),
    .axis_relative_direction = @ptrCast(&wl.noop),
};

fn outputForSurface(app: *App, surface: ?*wl.Obj) ?*Output {
    for (app.outputs.items) |o| {
        if (o.surface != null and o.surface.? == surface) return o;
    }
    return null;
}

fn onPointerEnter(
    data: ?*anyopaque,
    pointer: ?*wl.Obj,
    serial: u32,
    surface: ?*wl.Obj,
    surface_x: i32,
    surface_y: i32,
) callconv(.c) void {
    _ = pointer;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.dev_gesture_active) return;
    app.pointer_serial = serial;
    app.last_serial = serial;
    applyCursor(app);
    const o = outputForSurface(app, surface) orelse return;
    updateCursor(app, o, .{ .x = wl.fixedToFloat(surface_x), .y = wl.fixedToFloat(surface_y) });
}

fn onPointerLeave(
    data: ?*anyopaque,
    pointer: ?*wl.Obj,
    serial: u32,
    surface: ?*wl.Obj,
) callconv(.c) void {
    _ = pointer;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.dev_gesture_active) return;
    app.last_serial = serial;
    const o = outputForSurface(app, surface) orelse return;
    if (app.cursor_output == o) app.cursor_output = null;
    hideLoupe(app);
}

fn onPointerMotion(
    data: ?*anyopaque,
    pointer: ?*wl.Obj,
    time: u32,
    surface_x: i32,
    surface_y: i32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.dev_gesture_active) return;
    const o = app.cursor_output orelse return;
    updateCursor(app, o, .{ .x = wl.fixedToFloat(surface_x), .y = wl.fixedToFloat(surface_y) });
}

fn onPointerButton(
    data: ?*anyopaque,
    pointer: ?*wl.Obj,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.dev_gesture_active) return;
    app.last_serial = serial;
    app.pointer_serial = serial;

    if (state == wl.button_pressed) {
        app.buttons += 1;
        if (button == btn_left) {
            if (app.cursor_output != null) {
                hideLoupe(app);
                beginSelection(app);
            }
        } else if (button == btn_right) {
            cancel(app);
        }
    } else if (state == wl.button_released) {
        if (app.buttons > 0) app.buttons -= 1;
        if (button == btn_left and app.coordinator.isSelecting()) endSelection(app);
    }
}

const KeyboardListener = extern struct {
    keymap: *const fn (?*anyopaque, ?*wl.Obj, u32, i32, u32) callconv(.c) void,
    enter: *const fn (?*anyopaque, ?*wl.Obj, u32, ?*wl.Obj, ?*anyopaque) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*wl.Obj, u32, ?*wl.Obj) callconv(.c) void,
    key: *const fn (?*anyopaque, ?*wl.Obj, u32, u32, u32, u32) callconv(.c) void,
    modifiers: *const fn () callconv(.c) void,
    repeat_info: *const fn () callconv(.c) void,
};

const keyboard_listener = KeyboardListener{
    .keymap = onKeyboardKeymap,
    .enter = @ptrCast(&wl.noop),
    .leave = @ptrCast(&wl.noop),
    .key = onKeyboardKey,
    .modifiers = @ptrCast(&wl.noop),
    .repeat_info = @ptrCast(&wl.noop),
};

fn onKeyboardKeymap(
    data: ?*anyopaque,
    keyboard: ?*wl.Obj,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = keyboard;
    const app: *App = @ptrCast(@alignCast(data.?));
    defer sys.closeFd(fd);
    if (format != wl.keyboard_keymap_format_xkb_v1) return;
    if (size == 0) return;

    const memory = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(memory);

    const context = wl.xkb.xkb_context_new(wl.xkb.context_no_flags) orelse return;
    if (app.xkb_context == null) app.xkb_context = context;
    const text: [*:0]const u8 = @ptrCast(memory.ptr);
    const keymap = wl.xkb.xkb_keymap_new_from_string(
        context,
        text,
        wl.xkb.keymap_format_text_v1,
        wl.xkb.keymap_compile_no_flags,
    ) orelse return;
    const state = wl.xkb.xkb_state_new(keymap) orelse return;
    app.xkb_keymap = keymap;
    app.xkb_state = state;
}

fn onKeyboardKey(
    data: ?*anyopaque,
    keyboard: ?*wl.Obj,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = time;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.last_serial = serial;
    if (state != wl.button_pressed) return;

    var escape = key == 1; // evdev Escape, when no keymap is available
    if (app.xkb_state) |xkb_state| {
        const sym = wl.xkb.xkb_state_key_get_one_sym(xkb_state, key + wl.xkb.keycode_offset);
        escape = sym == wl.xkb.keysym_escape;
    }
    if (escape) cancel(app);
}

const DataSourceListener = extern struct {
    target: *const fn () callconv(.c) void,
    send: *const fn (?*anyopaque, ?*wl.Obj, ?[*:0]const u8, i32) callconv(.c) void,
    cancelled: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
    dnd_drop_performed: *const fn () callconv(.c) void,
    dnd_finished: *const fn () callconv(.c) void,
    action: *const fn () callconv(.c) void,
};

const data_source_listener = DataSourceListener{
    .target = @ptrCast(&wl.noop),
    .send = onDataSourceSend,
    .cancelled = onDataSourceCancelled,
    .dnd_drop_performed = @ptrCast(&wl.noop),
    .dnd_finished = @ptrCast(&wl.noop),
    .action = @ptrCast(&wl.noop),
};

fn onDataSourceSend(
    data: ?*anyopaque,
    source: ?*wl.Obj,
    mime_type: ?[*:0]const u8,
    fd: i32,
) callconv(.c) void {
    _ = source;
    _ = mime_type;
    const app: *App = @ptrCast(@alignCast(data.?));
    defer sys.closeFd(fd);
    if (app.clip_payload.len == 0) return;
    sys.writeAll(fd, app.clip_payload);
    app.clip_last_send_ms = nowMs();
}

fn onDataSourceCancelled(data: ?*anyopaque, source: ?*wl.Obj) callconv(.c) void {
    _ = source;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.clip_cancelled = true;
}

const DataDeviceListener = extern struct {
    data_offer: *const fn () callconv(.c) void,
    enter: *const fn () callconv(.c) void,
    leave: *const fn () callconv(.c) void,
    motion: *const fn () callconv(.c) void,
    drop: *const fn () callconv(.c) void,
    selection: *const fn (?*anyopaque, ?*wl.Obj, ?*wl.Obj) callconv(.c) void,
};

const data_device_listener = DataDeviceListener{
    .data_offer = @ptrCast(&wl.noop),
    .enter = @ptrCast(&wl.noop),
    .leave = @ptrCast(&wl.noop),
    .motion = @ptrCast(&wl.noop),
    .drop = @ptrCast(&wl.noop),
    .selection = @ptrCast(&wl.noop),
};
