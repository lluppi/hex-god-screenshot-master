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
const geom = @import("../core/geom.zig");
const canvas_mod = @import("../core/canvas.zig");
const color_mod = @import("../core/color.zig");
const interaction_mod = @import("../core/interaction.zig");
const png = @import("../core/png.zig");
const out = @import("../core/out.zig");
const cli = @import("../core/cli.zig");
const sys = @import("../core/sys.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const Point = geom.Point;
const FRect = geom.FRect;

const namespace = "hgsm";

const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;

/// evdev keycodes, for when no keymap has arrived and no keysym can be named.
const evdev_escape: u32 = 1;
const evdev_shift_l: u32 = 42;
const evdev_shift_r: u32 = 54;

/// Synthetic gestures for development: they drive the very same functions the
/// pointer handlers call, so a click or a drag can be exercised (and screenshoted
/// mid selection) without a mouse or an input injector on the box.
const clipboard_timeout_ms: i64 = 60_000;
const clipboard_idle_after_send_ms: i64 = 5_000;
const overlay_settle_ms: u64 = 60;

const Output = struct {
    app: *App,
    wl_output: *wl.Obj,
    interaction_id: interaction_mod.SurfaceId = 0,
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
    surface: ?*wl.Obj = null,
    surface_version: u32 = 1,
    layer_surface: ?*wl.Obj = null,
    configured: bool = false,

    fn canvasSize(self: *Output) Rect {
        if (self.baseline) |baseline| {
            return .{ .x = 0, .y = 0, .w = @intCast(baseline.width), .h = @intCast(baseline.height) };
        }
        return .{};
    }

    /// A geometry event: a zero dimension means "not known yet", so it is left
    /// alone. Callers decide when the size is complete enough to use.
    fn setLogicalSize(self: *Output, w: i32, h: i32) void {
        if (w > 0) self.logical.w = @floatFromInt(w);
        if (h > 0) self.logical.h = @floatFromInt(h);
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
    constraints: ?*wl.Obj = null,
    constraints_version: u32 = 1,
    relative_pointer_manager: ?*wl.Obj = null,
    relative_pointer_manager_version: u32 = 1,
    data_device_manager: ?*wl.Obj = null,
    data_device_manager_version: u32 = 1,
    seat: ?*wl.Obj = null,
    seat_version: u32 = 1,
    pointer: ?*wl.Obj = null,
    pointer_version: u32 = 1,
    /// Raw, unquantised pointer deltas. Null when the compositor has no
    /// relative-pointer, in which case the cursor stays on the compositor's own
    /// (integer logical pixel) positions.
    relative_pointer: ?*wl.Obj = null,
    /// The lock meant to park the real pointer, once one has been requested.
    locked_pointer: ?*wl.Obj = null,
    /// Output surface the current lock belongs to, used to restore the real
    /// pointer under the fine cursor before releasing it.
    locked_output: ?*Output = null,
    /// Logical pixels of cursor movement per unit of raw delta, from `--gain`.
    /// Zero means the compositor's own cursor position drives the overlay.
    gain: f64 = 0.5,
    /// The compositor reported the lock active. It does not follow that the
    /// pointer is held where it was; see `onPointerLocked`.
    pinned: bool = false,
    /// The axis (and value) of the last `wl_pointer.axis`, which is what tells a
    /// `axis_discrete` with no step count which way the wheel turned.
    pending_axis: u32 = 0,
    pending_axis_value: f64 = 0,
    /// Shift swaps the scroll axes; the keyboard reports it, so it is tracked
    /// here instead of through the xkb modifier state.
    shift_down: bool = false,
    /// The fine cursor has seen its first batch of deltas, which is the point
    /// where the lock can be re-asked for if it never reported in.
    fine_started: bool = false,
    /// A keyboard is created only once, however often capabilities are announced.
    keyboard_active: bool = false,
    data_device: ?*wl.Obj = null,
    outputs: std.ArrayList(*Output) = .empty,
    /// The outputs as the shared interaction sees them, built once after the
    /// baselines exist. Indexed by `interaction_id`.
    surfaces: []interaction_mod.Surface = &.{},

    // Native pointer routing plus shared gesture/loupe state.
    cursor_output: ?*Output = null,
    interaction: ?interaction_mod.Interaction = null,
    serial: u32 = 0,

    // Clipboard.
    clip_source: ?*wl.Obj = null,
    clip_payload: []const u8 = &.{},
    clip_set_ms: i64 = 0,
    clip_last_send_ms: ?i64 = null,
    clip_cancelled: bool = false,

    // Keyboard. `xkb_state` is what turns a keycode into a keysym; the keymap it
    // was built from has to outlive it, and both are replaced when the
    // compositor sends a new keymap.
    xkb_context: ?*anyopaque = null,
    xkb_keymap: ?*anyopaque = null,
    xkb_state: ?*anyopaque = null,

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

    const invocation = switch (cli.parse(raw.items)) {
        .run => |parsed| parsed,
        .help => {
            cli.printUsage();
            return;
        },
        .version => {
            cli.printVersion();
            return;
        },
        .invalid => |message| {
            out.fail("{s}\n", .{message});
            cli.printUsage();
            std.process.exit(2);
        },
    };
    const command = invocation.command;
    const dev = invocation.dev;

    const display = wl.wl_display_connect(null) orelse {
        out.fail("cannot connect to a wayland compositor (is WAYLAND_DISPLAY set?)\n", .{});
        std.process.exit(1);
    };

    var app = App{
        .allocator = allocator,
        .display = display,
        // A synthetic gesture drives the cursor directly, so it must not have a
        // raw-delta cursor racing it.
        .gain = if (dev != .none) 0 else invocation.gain,
    };
    defer wl.wl_display_disconnect(display);
    defer if (app.clip_source) |source| wl.dataSourceDestroy(source);

    try connect(&app);
    try captureBaselines(&app);
    app.surfaces = try buildSurfaces(&app);

    switch (command) {
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
            out.print("fine pointer: {s}\n", .{finePointerSupport(&app)});
        },
        .pick => |point| {
            const rgb = interaction_mod.colorAt(app.surfaces, point) orelse {
                out.fail("no output contains {d},{d}\n", .{ point.x, point.y });
                std.process.exit(1);
            };
            const hex = color_mod.hexString(rgb);
            out.print("{s}\n", .{hex});
            publish(&app, "text/plain;charset=utf-8", &hex);
        },
        .shot => |rect| {
            var canvas = try captureScreenshot(&app, rect);
            defer canvas.deinit();
            const bytes = try png.encode(allocator, canvas);
            out.print("Screenshot copied to clipboard\n", .{});
            publish(&app, "image/png", bytes);
        },
        .interactive => {
            try startOverlay(&app);
            switch (dev) {
                .none => {},
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
            eventLoop(&app);
            teardownOverlay(&app);
        },
    }

    if (command != .interactive) eventLoop(&app);
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
    // output's mode size, which is only correct at scale 1. The xdg objects only
    // exist to deliver that geometry, so they are destroyed once it has arrived.
    if (self.xdg_manager) |manager| {
        const xdg_outputs = try self.allocator.alloc(?*wl.Obj, self.outputs.items.len);
        defer self.allocator.free(xdg_outputs);
        for (self.outputs.items, 0..) |o, index| {
            xdg_outputs[index] = wl.xdgOutputManagerGetOutput(manager, self.xdg_manager_version, o.wl_output);
            if (xdg_outputs[index]) |xdg| wl.addListener(xdg, &xdg_output_listener, o);
        }
        try roundtrip(self);
        for (xdg_outputs) |xdg| {
            if (xdg) |proxy| wl.xdgOutputDestroy(proxy);
        }
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

/// What the compositor offers for the fine cursor, for `--info`.
fn finePointerSupport(self: *App) []const u8 {
    if (self.relative_pointer_manager == null) return "none";
    if (self.constraints == null) return "relative-pointer";
    return "relative-pointer + pointer-constraints";
}

fn roundtrip(self: *App) !void {
    if (wl.wl_display_roundtrip(self.display) < 0) return error.Disconnected;
}

/// Grab every output once. This baseline is what the overlay is composed from
/// and what the loupe magnifies, so the loupe can never magnify itself.
fn captureBaselines(self: *App) !void {
    for (self.outputs.items) |o| {
        var captured = capture.capture(
            self.display,
            self.screencopy.?,
            self.screencopy_version,
            self.shm.?,
            self.shm_version,
            o.wl_output,
            null,
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

/// The immutable per-output surfaces the shared interaction works in, built once
/// after the baselines exist. `interaction_id` is the index.
fn buildSurfaces(self: *App) ![]interaction_mod.Surface {
    const surfaces = try self.allocator.alloc(interaction_mod.Surface, self.outputs.items.len);
    for (self.outputs.items, 0..) |o, index| {
        o.interaction_id = index;
        surfaces[index] = .{ .logical = o.logical, .scale = o.scale, .baseline = &o.baseline.? };
    }
    return surfaces;
}

// ---------------------------------------------------------------------------
// Overlay lifecycle
// ---------------------------------------------------------------------------

fn startOverlay(self: *App) !void {
    if (self.layer_shell == null) {
        out.fail("the compositor does not support wlr-layer-shell\n", .{});
        return error.MissingProtocols;
    }

    self.interaction = try interaction_mod.Interaction.init(self.allocator, self.surfaces);
    errdefer {
        self.interaction.?.deinit();
        self.interaction = null;
    }
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
            // The viewport is parented to the surface, so destroying the surface
            // destroys it too; only the destination size matters here.
            if (wl.viewporterGetViewport(viewporter, 1, surface)) |vp| {
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
    // Release the pointer before anything else: the screenshot capture that
    // follows wants the desktop back to normal.
    releaseLock(self);
    self.fine_started = false;
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
        for (&o.dirty) |*dirty| dirty.clearRetainingCapacity();
    }
    if (self.interaction) |*interaction| {
        interaction.deinit();
        self.interaction = null;
    }
    self.cursor_output = null;
    self.overlays_up = false;
}

/// Wait for the compositor to actually drop our surfaces, then capture. Best
/// effort: if the compositor has gone away the capture that follows reports it.
fn settle(self: *App) void {
    roundtrip(self) catch {};
    sys.sleepMs(overlay_settle_ms);
    roundtrip(self) catch {};
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// Queue a repaint of one output's region and flush it. This is the frontend's
/// whole implementation of the shared `PaintFn`.
fn paintOutput(ctx: *anyopaque, surface: interaction_mod.SurfaceId, region: Rect) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const o = self.outputs.items[surface];
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
        regions[0] = canvas.rect();
        count = 1;
        o.fresh[index] = false;
    } else {
        const pending = o.dirty[index].items;
        if (pending.len == 0) return;
        for (pending) |region| {
            if (count < MAX_DIRTY) {
                regions[count] = region;
                count += 1;
            } else {
                regions[MAX_DIRTY - 1] = regions[MAX_DIRTY - 1].unionWith(region);
            }
        }
    }
    o.dirty[index].clearRetainingCapacity();

    if (o.app.interaction) |*interaction| {
        for (regions[0..count]) |region| interaction.render(o.interaction_id, &canvas, region);
    }

    wl.surfaceAttach(o.surface.?, buffer.buffer.?, 0, 0);
    if (o.surface_version >= 4) {
        for (regions[0..count]) |region| wl.surfaceDamageBuffer(o.surface.?, region);
    } else {
        // Fall back to one full-surface damage call per commit.
        wl.surfaceDamage(
            o.surface.?,
            0,
            0,
            @intFromFloat(o.logical.w),
            @intFromFloat(o.logical.h),
        );
    }
    wl.surfaceCommit(o.surface.?);
    buffer.released = false;
    o.buffer_index = 1 - index;
}

/// Upper bound on regions composed in one commit; anything past it is folded
/// into the last rectangle so no region is silently dropped.
const MAX_DIRTY = 32;

// ---------------------------------------------------------------------------
// Gesture
// ---------------------------------------------------------------------------

fn updateCursor(self: *App, o: *Output, local: Point) void {
    self.cursor_output = o;
    const interaction = &(self.interaction orelse return);
    interaction_mod.paintDamages(interaction.moveCursor(o.interaction_id, local), self, paintOutput);
}

fn beginSelection(self: *App) void {
    const interaction = &(self.interaction orelse return);
    interaction_mod.paintDamages(interaction.beginSelection(), self, paintOutput);
}

fn endSelection(self: *App) void {
    const interaction = &(self.interaction orelse return);
    if (interaction.endSelection()) |result| finish(self, result);
}

fn cancel(self: *App) void {
    const interaction = &(self.interaction orelse return);
    if (!interaction.cancel()) return;
    teardownOverlay(self);
    self.quit = true;
}

/// Move the synthetic cursor to a global logical point, resolving which output
/// it lands on. Only used by the dev gestures.
fn devMoveCursor(self: *App, global: Point) void {
    const hit = interaction_mod.hitTest(self.surfaces, global) orelse {
        out.fail("no output contains {d},{d}\n", .{ global.x, global.y });
        return;
    };
    updateCursor(self, self.outputs.items[hit.surface], hit.local);
}

/// Exactly what a press-and-release in place does: a click that resolves to a
/// colour.
fn devClick(self: *App, point: Point) void {
    devMoveCursor(self, point);
    if (self.cursor_output == null) return;
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
    while (remaining > 0) : (remaining -= @min(remaining, dev_pump_slice_ms)) {
        wl.pump(self.display, dev_pump_slice_ms) catch return;
        flushAll(self);
    }
}

/// Slice of the event loop a dev gesture pumps between steps, so a commit
/// reaches the compositor instead of sitting in our outgoing buffer.
const dev_pump_slice_ms: i32 = 20;

fn finish(self: *App, result: interaction_mod.Result) void {
    switch (result) {
        .color => |point| {
            const rgb = interaction_mod.colorAt(self.surfaces, point) orelse {
                fail(self, "the pixel colour could not be read");
                return;
            };
            const hex = color_mod.hexString(rgb);
            out.print("{s}\n", .{hex});
            // The overlay has to be gone before the clipboard paste happens,
            // or the user pastes our own dimming.
            teardownOverlay(self);
            settle(self);
            publish(self, "text/plain;charset=utf-8", &hex);
        },
        .screenshot => |rect| {
            self.pending_screenshot = rect;
        },
    }
}

/// Give up: report, set the exit code and let the event loop stop.
fn fail(self: *App, message: []const u8) void {
    out.fail("{s}\n", .{message});
    self.exit_code = 1;
    self.quit = true;
}

/// Copy a drag selection and publish it, after the overlay is out of the way.
fn finishScreenshot(self: *App, rect: FRect) void {
    teardownOverlay(self);
    settle(self);
    var canvas = captureScreenshot(self, rect) catch |err| {
        out.fail("screenshot failed: {t}\n", .{err});
        self.exit_code = 1;
        self.quit = true;
        return;
    };
    defer canvas.deinit();
    const bytes = png.encode(self.allocator, canvas) catch |err| {
        out.fail("png encoding failed: {t}\n", .{err});
        self.exit_code = 1;
        self.quit = true;
        return;
    };
    defer self.allocator.free(bytes);
    out.print("Screenshot copied to clipboard\n", .{});
    publish(self, "image/png", bytes);
}

/// Capture a global logical rectangle. The composition and the single-output
/// shortcut both live in the shared interaction; this only supplies the
/// per-output capture.
fn captureScreenshot(self: *App, rect: FRect) !Canvas {
    return interaction_mod.captureScreenshot(self.allocator, self.surfaces, rect, self, captureOne);
}

/// Capture one output's share of a screenshot. `intersection` is in global
/// logical coordinates; the protocol wants it output-local.
fn captureOne(self: *App, surface: interaction_mod.SurfaceId, intersection: FRect) anyerror!Canvas {
    const o = self.outputs.items[surface];
    const local = FRect{
        .x = intersection.x - o.logical.x,
        .y = intersection.y - o.logical.y,
        .w = intersection.w,
        .h = intersection.h,
    };
    var captured = capture.capture(
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
    defer captured.destroy();
    return capture.toCanvas(self.allocator, &captured);
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

fn publish(self: *App, mime: [:0]const u8, payload: []const u8) void {
    const manager = self.data_device_manager orelse {
        fail(self, "this compositor has no clipboard support");
        return;
    };
    const device = self.data_device orelse {
        fail(self, "this compositor has no clipboard device");
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
    wl.dataDeviceSetSelection(device, source, self.serial);
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

/// How long a quiet event loop sleeps between pumps. Only a fallback: pointer
/// and clipboard traffic wakes it sooner.
const event_pump_timeout_ms: i32 = 40;

fn eventLoop(self: *App) void {
    while (!self.quit) {
        wl.pump(self.display, event_pump_timeout_ms) catch {
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

fn hideCursor(self: *App) void {
    const pointer = self.pointer orelse return;
    if (self.pointer_version < 1) return;
    wl.pointerSetCursor(pointer, self.serial, null, 0, 0);
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

    // Plain globals: bind once at the highest version we understand, recording
    // both the proxy and the version we settled on.
    const Binding = struct {
        name: []const u8,
        iface: *const wl.Interface,
        max_version: u32,
        version: *u32,
        proxy: *?*wl.Obj,
    };
    const bindings = [_]Binding{
        .{ .name = "wl_compositor", .iface = &wl.wl_compositor_interface, .max_version = 6, .version = &app.compositor_version, .proxy = &app.compositor },
        .{ .name = "wl_shm", .iface = &wl.wl_shm_interface, .max_version = 1, .version = &app.shm_version, .proxy = &app.shm },
        .{ .name = "zwlr_layer_shell_v1", .iface = &wl.zwlr_layer_shell_v1_interface, .max_version = 5, .version = &app.layer_shell_version, .proxy = &app.layer_shell },
        .{ .name = "zwlr_screencopy_manager_v1", .iface = &wl.zwlr_screencopy_manager_v1_interface, .max_version = 3, .version = &app.screencopy_version, .proxy = &app.screencopy },
        .{ .name = "zxdg_output_manager_v1", .iface = &wl.zxdg_output_manager_v1_interface, .max_version = 3, .version = &app.xdg_manager_version, .proxy = &app.xdg_manager },
        .{ .name = "wl_data_device_manager", .iface = &wl.wl_data_device_manager_interface, .max_version = 3, .version = &app.data_device_manager_version, .proxy = &app.data_device_manager },
    };
    for (bindings) |binding| {
        if (!std.mem.eql(u8, iface, binding.name)) continue;
        binding.version.* = @min(version, binding.max_version);
        binding.proxy.* = wl.bind(registry_obj, name, binding.iface, binding.version.*);
        return;
    }

    if (std.mem.eql(u8, iface, "wp_viewporter")) {
        app.viewporter = wl.bind(registry_obj, name, &wl.wp_viewporter_interface, @min(version, 1));
    } else if (std.mem.eql(u8, iface, "zwp_pointer_constraints_v1")) {
        app.constraints_version = @min(version, 1);
        app.constraints = wl.bind(registry_obj, name, &wl.zwp_pointer_constraints_v1_interface, app.constraints_version);
    } else if (std.mem.eql(u8, iface, "zwp_relative_pointer_manager_v1")) {
        app.relative_pointer_manager_version = @min(version, 1);
        app.relative_pointer_manager = wl.bind(registry_obj, name, &wl.zwp_relative_pointer_manager_v1_interface, app.relative_pointer_manager_version);
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

        // Relative motion is a property of the pointer object, so it can only be
        // asked for once the seat has handed one over.
        if (pointer) |p| {
            if (app.relative_pointer_manager) |manager| {
                app.relative_pointer = wl.relativePointerManagerGetRelativePointer(
                    manager,
                    app.relative_pointer_manager_version,
                    p,
                );
                if (app.relative_pointer) |rp| wl.addListener(rp, &relative_pointer_listener, app);
            }
        }
    }
    if (capabilities & wl.seat_capability_keyboard != 0 and !app.keyboard_active) {
        app.keyboard_active = true;
        const keyboard = wl.seatGetKeyboard(seat.?, @min(app.seat_version, 5));
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
    self.setLogicalSize(w, h);
}

fn onXdgSize(data: ?*anyopaque, xdg: ?*wl.Obj, w: i32, h: i32) callconv(.c) void {
    _ = xdg;
    const self: *Output = @ptrCast(@alignCast(data.?));
    self.setLogicalSize(w, h);
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
    self.setLogicalSize(@intCast(width), @intCast(height));
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
    axis: *const fn (?*anyopaque, ?*wl.Obj, u32, u32, i32) callconv(.c) void,
    frame: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
    axis_source: *const fn () callconv(.c) void,
    axis_stop: *const fn () callconv(.c) void,
    axis_discrete: *const fn (?*anyopaque, ?*wl.Obj, u32, i32) callconv(.c) void,
    axis_value120: *const fn () callconv(.c) void,
    axis_relative_direction: *const fn () callconv(.c) void,
};

const pointer_listener = PointerListener{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = @ptrCast(&wl.noop),
    .axis_source = @ptrCast(&wl.noop),
    .axis_stop = @ptrCast(&wl.noop),
    .axis_discrete = onPointerDiscreteAxis,
    .axis_value120 = @ptrCast(&wl.noop),
    .axis_relative_direction = @ptrCast(&wl.noop),
};

/// `zwp_relative_pointer_v1.relative_motion`: two `u32` timestamps, then the
/// accelerated and unaccelerated deltas as `wl_fixed_t`. The accelerated pair is
/// what the compositor would have moved its own cursor by, so it keeps whatever
/// the pointer itself is configured to do; the unaccelerated pair is only used
/// when the compositor sends nothing accelerated.
const RelativePointerListener = extern struct {
    relative_motion: *const fn (
        ?*anyopaque,
        ?*wl.Obj,
        u32,
        u32,
        i32,
        i32,
        i32,
        i32,
    ) callconv(.c) void,
};

const relative_pointer_listener = RelativePointerListener{
    .relative_motion = onRelativeMotion,
};

const LockedPointerListener = extern struct {
    locked: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
    unlocked: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
};

const locked_pointer_listener = LockedPointerListener{
    .locked = onPointerLocked,
    .unlocked = onPointerUnlocked,
};

/// The compositor reported the lock active. The fine cursor does not depend on
/// this either way; it only says whether the real pointer is meant to be parked,
/// which is what keeps it where the user left it once the overlay is gone.
/// Hyprland reports it for layer surfaces without actually holding the pointer,
/// so nothing here may claim more than the event does.
fn onPointerLocked(data: ?*anyopaque, locked: ?*wl.Obj) callconv(.c) void {
    _ = locked;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.pinned = true;
}

fn onPointerUnlocked(data: ?*anyopaque, locked: ?*wl.Obj) callconv(.c) void {
    _ = locked;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.pinned = false;
}

/// Relative motion belongs to its own protocol stream and is not coupled to
/// `wl_pointer.frame`, so apply each event as it arrives.
fn onRelativeMotion(
    data: ?*anyopaque,
    relative_pointer: ?*wl.Obj,
    time_hi: u32,
    time_lo: u32,
    dx: i32,
    dy: i32,
    dx_unaccel: i32,
    dy_unaccel: i32,
) callconv(.c) void {
    _ = relative_pointer;
    _ = time_hi;
    _ = time_lo;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.dev_gesture_active) return;

    const accelerated = dx != 0 or dy != 0;
    advanceFineCursor(app, .{
        .x = wl.fixedToFloat(if (accelerated) dx else dx_unaccel),
        .y = wl.fixedToFloat(if (accelerated) dy else dy_unaccel),
    });
}

/// Move the fine cursor by one batch of raw deltas and repaint what changed.
fn advanceFineCursor(self: *App, delta: Point) void {
    const interaction = prepareFineMove(self) orelse return;
    interaction_mod.paintDamages(interaction.advanceFine(delta), self, paintOutput);
}

fn nudgeFineCursor(self: *App, delta: Point) void {
    const interaction = prepareFineMove(self) orelse return;
    interaction_mod.paintDamages(interaction.nudgeFine(delta), self, paintOutput);
}

fn prepareFineMove(self: *App) ?*interaction_mod.Interaction {
    const interaction = &(self.interaction orelse return null);
    if (!interaction.fineActive()) return null;
    if (!self.fine_started) {
        self.fine_started = true;
        // A compositor only activates a fresh constraint whose surface already
        // holds focus, and the pointer enter that asked for it can beat that
        // focus. Deltas are flowing here, so the focus is certainly ours by now:
        // a lock that never reported in gets dropped and asked for once more.
        if (!self.pinned) relockFine(self);
    }
    return interaction;
}

/// Ask for the lock again, parked under the fine cursor rather than under a
/// pointer position the user has already moved on from.
fn relockFine(self: *App) void {
    const interaction = &(self.interaction orelse return);
    const global = interaction.finePosition() orelse return;
    const hit = interaction_mod.hitTest(self.surfaces, global) orelse return;
    releaseLock(self);
    requestLock(self, self.outputs.items[hit.surface], hit.local);
}

/// The value of a `wl_pointer.axis` event, kept so a `axis_discrete` that
/// arrives without a step count still knows which way the wheel turned.
fn onPointerAxis(
    data: ?*anyopaque,
    pointer: ?*wl.Obj,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.pending_axis = axis;
    app.pending_axis_value = wl.fixedToFloat(value);
}

/// One wheel detent is one physical pixel of cursor movement, which is the only
/// step that is exactly one cell of the loupe's grid at every display scale.
fn onPointerDiscreteAxis(
    data: ?*anyopaque,
    pointer: ?*wl.Obj,
    axis: u32,
    discrete: i32,
) callconv(.c) void {
    _ = pointer;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.dev_gesture_active) return;

    const interaction = &(app.interaction orelse return);
    const global = interaction.finePosition() orelse return;
    const hit = interaction_mod.hitTest(app.surfaces, global) orelse return;
    const o = app.outputs.items[hit.surface];

    const steps = std.math.clamp(discrete, -10, 10);
    const direction: f64 = if (steps != 0)
        @floatFromInt(steps)
    else if (app.pending_axis == axis and app.pending_axis_value > 0)
        1
    else if (app.pending_axis == axis and app.pending_axis_value < 0)
        -1
    else
        return;

    // Shift swaps the axes, since a compositor hands shift+wheel over as a plain
    // vertical scroll.
    const scroll_axis = if (app.shift_down)
        if (axis == wl.axis_vertical) wl.axis_horizontal else wl.axis_vertical
    else
        axis;
    const step = direction / o.scale;
    const delta = if (scroll_axis == wl.axis_horizontal)
        Point{ .x = step, .y = 0 }
    else
        Point{ .x = 0, .y = step };
    nudgeFineCursor(app, delta);
}

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
    app.serial = serial;
    hideCursor(app);
    const o = outputForSurface(app, surface) orelse return;
    const local = Point{ .x = wl.fixedToFloat(surface_x), .y = wl.fixedToFloat(surface_y) };
    if (app.interaction) |*interaction| {
        if (interaction.fineActive()) return;
    }
    updateCursor(app, o, local);
    beginFineCursor(app, o, local);
    requestLock(app, o, local);
}

/// Hand the cursor over to raw deltas, anchored on the point the compositor
/// currently reports, so taking over moves nothing on the first frame.
fn beginFineCursor(self: *App, o: *Output, local: Point) void {
    const interaction = &(self.interaction orelse return);
    if (self.gain <= 0 or self.relative_pointer == null) return;
    interaction.beginFine(
        .{ .x = o.logical.x + local.x, .y = o.logical.y + local.y },
        self.gain,
    );
}

/// Ask for the real pointer to be parked for the duration of the overlay. The
/// fine cursor is driven by relative deltas either way, so this is only about
/// the pointer not wandering off while the overlay is up, and being where the
/// user left it once the overlay is gone.
fn requestLock(self: *App, o: *Output, local: Point) void {
    const constraints = self.constraints orelse return;
    const pointer = self.pointer orelse return;
    const surface = o.surface orelse return;
    if (self.gain <= 0 or self.relative_pointer == null) return;
    if (self.locked_pointer != null) return;

    const locked = wl.constraintsLockPointer(
        constraints,
        self.constraints_version,
        surface,
        pointer,
        wl.constraint_lifetime_persistent,
    ) orelse return;
    // Where the pointer already is, so the lock does not teleport it.
    wl.lockedPointerSetCursorPositionHint(locked, local.x, local.y);
    wl.surfaceCommit(surface);
    wl.addListener(locked, &locked_pointer_listener, self);
    self.locked_pointer = locked;
    self.locked_output = o;
}

/// Commit the fine cursor as the unlock position, then release the constraint.
fn releaseLock(self: *App) void {
    const locked = self.locked_pointer orelse return;
    if (self.locked_output) |o| {
        if (self.interaction) |*interaction| {
            if (interaction.finePosition()) |global| {
                wl.lockedPointerSetCursorPositionHint(
                    locked,
                    global.x - o.logical.x,
                    global.y - o.logical.y,
                );
                if (o.surface) |surface| wl.surfaceCommit(surface);
            }
        }
    }
    wl.lockedPointerDestroy(locked);
    self.locked_pointer = null;
    self.locked_output = null;
    self.pinned = false;
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
    app.serial = serial;
    const o = outputForSurface(app, surface) orelse return;
    if (app.interaction) |*interaction| {
        // The fine cursor is not the compositor's pointer, so the real one
        // wandering off a surface neither moves it nor hides it.
        if (interaction.fineActive()) return;
    }
    if (app.cursor_output == o) app.cursor_output = null;
    if (app.interaction) |*interaction| {
        interaction_mod.paintDamages(interaction.leaveSurface(o.interaction_id), app, paintOutput);
    }
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
    if (app.interaction) |*interaction| {
        // Those positions are quantised to whole logical pixels, which is more
        // than one physical pixel on a fractional-scaled output. The fine cursor
        // is driven by deltas instead, so this stream is not allowed to fight it.
        if (interaction.fineActive()) return;
    }
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
    app.serial = serial;

    if (state == wl.button_pressed) {
        if (button == btn_left) {
            if (app.cursor_output != null) beginSelection(app);
        } else if (button == btn_right) {
            cancel(app);
        }
    } else if (state == wl.button_released) {
        const selecting = if (app.interaction) |*interaction| interaction.isSelecting() else false;
        if (button == btn_left and selecting) endSelection(app);
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

    // One context for the process; each keymap event replaces the previous
    // keymap and state, so the old ones are released rather than leaked.
    const context = app.xkb_context orelse blk: {
        const created = wl.xkb.xkb_context_new(wl.xkb.context_no_flags) orelse return;
        app.xkb_context = created;
        break :blk created;
    };
    const text: [*:0]const u8 = @ptrCast(memory.ptr);
    const keymap = wl.xkb.xkb_keymap_new_from_string(
        context,
        text,
        wl.xkb.keymap_format_text_v1,
        wl.xkb.keymap_compile_no_flags,
    ) orelse return;
    const state = wl.xkb.xkb_state_new(keymap) orelse {
        wl.xkb.xkb_keymap_unref(keymap);
        return;
    };
    if (app.xkb_state) |previous| wl.xkb.xkb_state_unref(previous);
    if (app.xkb_keymap) |previous| wl.xkb.xkb_keymap_unref(previous);
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
    app.serial = serial;
    const pressed = state == wl.button_pressed;
    const sym: u32 = if (app.xkb_state) |xkb_state|
        wl.xkb.xkb_state_key_get_one_sym(xkb_state, key + wl.xkb.keycode_offset)
    else
        0;

    if (sym == wl.xkb.keysym_shift_l or sym == wl.xkb.keysym_shift_r or
        (sym == 0 and (key == evdev_shift_l or key == evdev_shift_r)))
    {
        app.shift_down = pressed;
        return;
    }
    if (!pressed) return;

    if (sym == wl.xkb.keysym_escape or (sym == 0 and key == evdev_escape)) {
        cancel(app);
    } else if (sym == wl.xkb.keysym_minus) {
        adjustGain(app, 1 / cli.gain_step);
    } else if (sym == wl.xkb.keysym_equal or sym == wl.xkb.keysym_plus) {
        adjustGain(app, cli.gain_step);
    }
}

/// Change the fine cursor's speed on the fly, so it can be found by feel rather
/// than by re-running with another `--gain`.
fn adjustGain(self: *App, factor: f64) void {
    const interaction = &(self.interaction orelse return);
    self.gain = cli.adjustedGain(self.gain, factor);
    interaction.setFineGain(self.gain);
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
    const app: *App = @ptrCast(@alignCast(data.?));
    if (source) |cancelled| wl.dataSourceDestroy(cancelled);
    app.clip_source = null;
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
