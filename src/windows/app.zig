//! Windows frontend: one topmost popup per monitor painted from the shared core,
//! and GDI for capture.
//!
//! Structurally identical to the Wayland and macOS frontends: one borderless
//! window per monitor covering it exactly, a baseline grab per monitor taken
//! with `BitBlt` before the overlay appears, the same gesture state machine and
//! the same loupe. Final screenshots crop the baseline the user selected from,
//! so dismissing the overlay needs no second screen capture.
//!
//! Where Windows differs from the other two, and why:
//!
//!   * Logical coordinates are the virtualised desktop a dpi-unaware process
//!     sees: every monitor rect and cursor position divided by the system dpi
//!     scale. That is the space `--pick` and `--shot` take, the space the core
//!     works in, and the space a shell script on this machine reports a pointer
//!     position in - the same contract the other two frontends keep, where
//!     "logical" means points. Device pixels arrive from the window system (a
//!     client coordinate, `GetCursorPos`) and are divided by that one scale;
//!     the monitor's own dpi reaches the core separately as `ui_scale`, because
//!     the instrument follows the monitor while coordinates follow the system
//!     (see `interaction.Surface`). Y is already down and the primary is at
//!     0,0, so there is no flip.
//!   * Presentation is a layered window fed by `UpdateLayeredWindowIndirect`:
//!     each frame composes the dirty rectangle into a DIB-section canvas and
//!     hands that rectangle to DWM as one transaction. Painting into a window
//!     DC piecemeal is not atomic under DWM - the compositor can pick up a
//!     surface between the erase of the old loupe and the draw of the new one -
//!     and that is a flicker no amount of damage bookkeeping cures. Mouse events
//!     only widen the dirty rectangle; the message loop presents once per
//!     iteration, so a burst of moves is one compose and one copy.
//!   * `canvas` is premultiplied ARGB8888 top-down, which on little endian is
//!     byte-for-byte BGRA - exactly what a top-down 32bpp DIB section holds, what
//!     `UpdateLayeredWindow` blends with `AC_SRC_ALPHA`, and what a `CF_DIB`
//!     wants after a row flip, so capture, presentation and clipboard are copies
//!     rather than conversions.
//!   * There is no pointer lock: the fine cursor is fed unaccelerated deltas
//!     from raw input (mouse deltas, the same kind of input the Wayland
//!     relative-pointer and the CoreGraphics mouse deltas provide), and the
//!     system pointer is dragged along under it so the physical mouse cannot
//!     run out of screen.
//!   * A process started by a hotkey cannot reliably take the foreground, so
//!     escape is polled with `GetAsyncKeyState` as well as being received as a
//!     key message, and raw input is registered with `RIDEV_INPUTSINK` so the
//!     fine cursor works without focus.

const std = @import("std");
const win32 = @import("win32.zig");
const geom = @import("../core/geom.zig");
const canvas_mod = @import("../core/canvas.zig");
const color = @import("../core/color.zig");
const interaction_mod = @import("../core/interaction.zig");
const png = @import("../core/png.zig");
const save = @import("../core/save.zig");
const cli = @import("../core/cli.zig");
const out = @import("../core/out.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const Point = geom.Point;
const FRect = geom.FRect;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("HexGodOverlay");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("hgsm");

/// Physical pixels of cursor travel per raw mouse count. One, because that is
/// what the macOS frontend feeds the same state machine, and `--gain` is
/// documented against that feel.
const pixels_per_count: f64 = 1;

const Display = struct {
    app: *App,
    index: u32,
    interaction_id: interaction_mod.SurfaceId = 0,
    /// The monitor in device pixels, y down from the primary's top-left. What
    /// the window is placed at and what the baseline is grabbed from.
    physical: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// The same rect in logical units: the space the core and the command line
    /// work in, and the space a dpi-unaware caller reports positions in.
    logical: FRect = .{},
    /// The monitor's effective dpi, e.g. 144 at 150%. Sizes the instrument.
    dpi: u32 = 96,
    /// The monitor as it was before the overlay appeared. Borrowed pixels from a
    /// DIB section, released with `baseline_bitmap`.
    baseline: ?Canvas = null,
    baseline_bitmap: ?win32.HBITMAP = null,
    /// Backing store for the overlay window, physical pixels: a DIB section held
    /// by a memory DC, which is what `UpdateLayeredWindowIndirect` presents from.
    canvas: ?Canvas = null,
    canvas_bitmap: ?win32.HBITMAP = null,
    canvas_dc: ?win32.HDC = null,
    /// Physical pixels changed since the last present. One compose and one
    /// present per frame cover every mouse event that arrived in between.
    dirty: ?Rect = null,
    hwnd: ?win32.HWND = null,
};

const App = struct {
    allocator: std.mem.Allocator,
    displays: std.ArrayList(*Display) = .empty,
    /// The monitors as the shared interaction sees them, built once after the
    /// baselines exist. Indexed by `interaction_id`.
    surfaces: []interaction_mod.Surface = &.{},
    /// Device pixels per logical unit: the system dpi over 96. The whole
    /// virtualised desktop shares it, which is what makes logical coordinates
    /// mean the same thing to this process as to a dpi-unaware caller.
    scale: f64 = 1,
    interaction: ?interaction_mod.Interaction = null,
    /// Logical pixels of cursor movement per unit of the mouse's own delta, from
    /// `--gain`. Zero keeps the pointer driving the cursor, as it always did.
    gain: f64 = 0,
    /// Directory from `--save-dir`: each screenshot is also written there as a
    /// PNG. Null means clipboard only, which is the default.
    save_dir: ?[]const u8 = null,
    /// The fine cursor owns the system pointer. Windows cannot detach one from
    /// the mouse, so the pointer is dragged along under the fine cursor instead.
    pointer_detached: bool = false,
    /// Last absolute raw report, for the absolute-positioning devices a virtual
    /// machine's mouse shows up as.
    last_absolute: ?win32.POINT = null,
    /// The extents an absolute raw report's 0..65535 space is mapped over: the
    /// primary monitor, and the whole virtual desktop.
    primary_span: win32.POINT = .{ .x = 1, .y = 1 },
    virtual_span: win32.POINT = .{ .x = 1, .y = 1 },
    finished: bool = false,
    exit_code: u8 = 0,
};

/// Set while the overlay is up, so the window procedure (which receives no user
/// data) can reach the app. It is the one piece of global state in this
/// frontend: Win32 class dispatch has nowhere else to put a context pointer.
var current_app: ?*App = null;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(minimal: std.process.Init.Minimal) !void {
    // Before any window: a process that has not declared per-monitor awareness
    // is lied to about monitor geometry and cursor positions, which would make
    // every capture the wrong size.
    win32.declarePerMonitorAware();
    win32.attachParentConsole();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var args = try minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var rest: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try rest.append(allocator, arg);

    const invocation = switch (cli.parse(rest.items)) {
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

    var app = App{ .allocator = allocator, .gain = invocation.gain, .save_dir = invocation.save_dir };

    try collectDisplays(&app);
    defer releaseBaselines(&app);
    try captureBaselines(&app);
    app.surfaces = try buildSurfaces(&app);

    switch (command) {
        .info => printInfo(&app),
        .pick => |point| {
            const rgb = interaction_mod.colorAt(app.surfaces, point) orelse {
                out.fail("no monitor contains {d},{d}\n", .{ point.x, point.y });
                std.process.exit(1);
            };
            const hex = color.hexString(rgb);
            out.print("{s}\n", .{hex});
            copyText(&hex);
        },
        .shot => |rect| {
            var canvas = try captureScreenshot(&app, rect);
            defer canvas.deinit();
            const bytes = try png.encode(allocator, canvas);
            defer allocator.free(bytes);
            saveScreenshot(&app, bytes);
            out.print("Screenshot copied to clipboard\n", .{});
            copyScreenshot(canvas, bytes);
        },
        .interactive => {
            switch (dev) {
                .none => {},
                else => {
                    out.fail("synthetic gestures are linux-only\n", .{});
                    std.process.exit(2);
                },
            }
            // The window procedure can run before runOverlay returns to this
            // frame, so it must be able to find the app first.
            current_app = &app;
            defer current_app = null;
            try runOverlay(&app);
        },
    }

    if (app.exit_code != 0) std.process.exit(app.exit_code);
}

// ---------------------------------------------------------------------------
// Monitors
// ---------------------------------------------------------------------------

/// What the monitor enumeration hands back: the displays, the primary monitor's
/// rect, and the union of all of them.
const MonitorCollector = struct {
    app: *App,
    failed: bool = false,
    primary: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    virtual: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

fn collectDisplays(app: *App) !void {
    // The system dpi first: it is the scale of the virtualised desktop as a
    // whole, the factor a dpi-unaware process sees every rectangle and every
    // pointer position divided by, and the callbacks below divide by it. It is
    // deliberately not the per-monitor dpi, which sizes the instrument instead.
    app.scale = @as(f64, @floatFromInt(win32.systemDpi())) / 96.0;
    if (app.scale <= 0) app.scale = 1;

    var collector = MonitorCollector{ .app = app };

    const result = win32.EnumDisplayMonitors(null, null, monitorCallback, @bitCast(@intFromPtr(&collector)));
    if (result == 0 or collector.failed or app.displays.items.len == 0) return error.NoDisplays;

    const primary = if (collector.primary.width() > 0) collector.primary else app.displays.items[0].physical;
    app.primary_span = .{ .x = @max(1, primary.width()), .y = @max(1, primary.height()) };
    app.virtual_span = if (collector.virtual.width() > 0)
        .{ .x = @max(1, collector.virtual.width()), .y = @max(1, collector.virtual.height()) }
    else
        app.primary_span;
}

fn monitorCallback(monitor: ?win32.HANDLE, dc: ?win32.HDC, rect: *win32.RECT, data: win32.LPARAM) callconv(.winapi) win32.BOOL {
    _ = dc;
    const collector: *MonitorCollector = @ptrFromInt(@as(usize, @bitCast(data)));
    const app = collector.app;

    var info = win32.MONITORINFO{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = rect.*,
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
    };
    if (win32.GetMonitorInfoW(monitor, &info) == 0) {
        collector.failed = true;
        return 1;
    }
    if (info.dwFlags & win32.monitorinfof_primary != 0) collector.primary = info.rcMonitor;
    collector.virtual = .{
        .left = @min(collector.virtual.left, info.rcMonitor.left),
        .top = @min(collector.virtual.top, info.rcMonitor.top),
        .right = @max(collector.virtual.right, info.rcMonitor.right),
        .bottom = @max(collector.virtual.bottom, info.rcMonitor.bottom),
    };

    const display = app.allocator.create(Display) catch {
        collector.failed = true;
        return 1;
    };
    display.* = .{
        .app = app,
        .index = @intCast(app.displays.items.len),
        .physical = info.rcMonitor,
        .logical = .{
            .x = @as(f64, @floatFromInt(info.rcMonitor.left)) / app.scale,
            .y = @as(f64, @floatFromInt(info.rcMonitor.top)) / app.scale,
            .w = @as(f64, @floatFromInt(info.rcMonitor.width())) / app.scale,
            .h = @as(f64, @floatFromInt(info.rcMonitor.height())) / app.scale,
        },
        .dpi = if (monitor) |handle| win32.monitorDpi(handle) else 96,
    };
    app.displays.append(app.allocator, display) catch {
        collector.failed = true;
        return 1;
    };
    return 1;
}

/// Grab every monitor once, before the overlay appears. In device pixels: this
/// is the screen, not a view of it.
fn captureBaselines(app: *App) !void {
    errdefer releaseBaselines(app);
    for (app.displays.items) |display| {
        const grab = captureDib(app.allocator, display.physical) catch |err| {
            out.fail("could not capture monitor {d}\n", .{display.index});
            return err;
        };
        display.baseline = grab.canvas;
        display.baseline_bitmap = grab.bitmap;
    }
}

fn releaseBaselines(app: *App) void {
    for (app.displays.items) |display| {
        if (display.baseline_bitmap) |bitmap| _ = win32.DeleteObject(bitmap);
        display.baseline_bitmap = null;
        if (display.canvas_dc) |dc| _ = win32.DeleteDC(dc);
        display.canvas_dc = null;
        if (display.canvas_bitmap) |bitmap| _ = win32.DeleteObject(bitmap);
        display.canvas_bitmap = null;
        display.canvas = null;
    }
}

/// The immutable per-monitor surfaces the shared interaction works in, built
/// once after the baselines exist. `interaction_id` is the index.
fn buildSurfaces(app: *App) ![]interaction_mod.Surface {
    const surfaces = try app.allocator.alloc(interaction_mod.Surface, app.displays.items.len);
    for (app.displays.items, 0..) |display, index| {
        display.interaction_id = index;
        surfaces[index] = .{
            .logical = display.logical,
            // Logical units to device pixels: the virtualised desktop's scale.
            .scale = app.scale,
            // The instrument is drawn in points, so it keeps its apparent size
            // on a scaled monitor. Per monitor, unlike `scale`.
            .ui_scale = @as(f64, @floatFromInt(display.dpi)) / 96.0,
            .baseline = &display.baseline.?,
        };
    }
    return surfaces;
}

fn printInfo(app: *App) void {
    for (app.displays.items) |display| {
        out.print(
            "display {d}: {d}x{d} logical at {d},{d} scale {d:.3} dpi {d} ({d:.3}) baseline {d}x{d}\n",
            .{
                display.index,
                @as(i64, @intFromFloat(display.logical.w)),
                @as(i64, @intFromFloat(display.logical.h)),
                @as(i64, @intFromFloat(display.logical.x)),
                @as(i64, @intFromFloat(display.logical.y)),
                app.scale,
                display.dpi,
                @as(f64, @floatFromInt(display.dpi)) / 96.0,
                display.baseline.?.width,
                display.baseline.?.height,
            },
        );
    }
    out.print("fine pointer: {s}\n", .{if (rawInputAvailable()) "raw mouse deltas" else "none (pointer drives the cursor)"});
}

/// Whether a raw mouse can be registered on this session. Asking is the only
/// way to know, and `--info` is not allowed to leave a registration behind, so
/// the probe registers and immediately releases.
fn rawInputAvailable() bool {
    var device = win32.RAWINPUTDEVICE{
        .usUsagePage = 0x01,
        .usUsage = 0x02,
        .dwFlags = 0,
        .hwndTarget = null,
    };
    if (win32.RegisterRawInputDevices(@ptrCast(&device), 1, @sizeOf(win32.RAWINPUTDEVICE)) == 0) return false;
    device.dwFlags = win32.ridev_remove;
    _ = win32.RegisterRawInputDevices(@ptrCast(&device), 1, @sizeOf(win32.RAWINPUTDEVICE));
    return true;
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

const Grab = struct {
    canvas: Canvas,
    bitmap: win32.HBITMAP,
};

/// Copy a screen rectangle into a top-down 32bpp DIB section and hand back a
/// canvas over it. The bitmap owns the pixels; the canvas must never be
/// deinited, only the bitmap deleted.
fn captureDib(allocator: std.mem.Allocator, rect: win32.RECT) !Grab {
    const width = rect.width();
    const height = rect.height();
    if (width <= 0 or height <= 0) return error.EmptyCapture;

    const screen = win32.GetDC(null) orelse return error.NoScreenDc;
    defer _ = win32.ReleaseDC(null, screen);
    const memory = win32.CreateCompatibleDC(screen) orelse return error.NoMemoryDc;
    defer _ = win32.DeleteDC(memory);

    var info = bitmapInfo(width, height);
    var bits: ?*anyopaque = null;
    const bitmap = win32.CreateDIBSection(screen, &info, win32.dib_rgb_colors, &bits, null, 0) orelse
        return error.CreateDibFailed;
    errdefer _ = win32.DeleteObject(bitmap);

    const previous = win32.SelectObject(memory, bitmap);
    defer if (previous) |object| {
        _ = win32.SelectObject(memory, object);
    };
    // CAPTUREBLT is required for layered windows such as menus, HUDs and other
    // overlays. Omitting it benchmarks faster but freezes an incomplete desktop.
    if (win32.BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, win32.srccopy | win32.captureblt) == 0) {
        return error.CaptureFailed;
    }

    const raw = bits orelse return error.CreateDibFailed;
    const pixels: [*]u32 = @ptrCast(@alignCast(raw));
    const count: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    // GDI leaves the alpha byte zeroed. The core composites premultiplied, where
    // a zero alpha means "transparent", so a dimming pass over this would come
    // out black. Screens are opaque; make them say so.
    for (pixels[0..count]) |*pixel| pixel.* |= 0xff00_0000;

    return .{
        .canvas = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .pixels = pixels[0..count],
            .allocator = allocator,
        },
        .bitmap = bitmap,
    };
}

/// A 32bpp BI_RGB bitmap description. Top-down (negative height) so row zero is
/// the top row, matching the canvas and letting a source rectangle be named in
/// canvas coordinates.
fn bitmapInfo(width: i32, height: i32) win32.BITMAPINFO {
    return .{
        .bmiHeader = .{
            .biSize = @sizeOf(win32.BITMAPINFOHEADER),
            .biWidth = width,
            .biHeight = -height,
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = win32.bi_rgb,
            .biSizeImage = @intCast(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4),
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        },
        .bmiColors = .{0},
    };
}

/// Capture a global logical rectangle. The composition and the single-monitor
/// shortcut both live in the shared interaction; this only supplies the
/// per-monitor capture.
fn captureScreenshot(app: *App, rect: FRect) !Canvas {
    return interaction_mod.captureScreenshot(app.allocator, app.surfaces, rect, app, captureOne);
}

/// Crop one monitor's share from the baseline already shown under the overlay.
/// This is both WYSIWYG and avoids another screen capture after dragging.
fn captureOne(app: *App, surface: interaction_mod.SurfaceId, intersection: FRect) anyerror!Canvas {
    const display = app.displays.items[surface];
    const baseline = display.baseline.?;
    const source = Rect.roundF(.{
        .x = (intersection.x - display.logical.x) * app.scale,
        .y = (intersection.y - display.logical.y) * app.scale,
        .w = intersection.w * app.scale,
        .h = intersection.h * app.scale,
    }).clamped(baseline.width, baseline.height);
    if (source.isEmpty()) return error.EmptyCapture;

    var captured = try Canvas.initUninitialized(
        app.allocator,
        @intCast(source.w),
        @intCast(source.h),
    );
    errdefer captured.deinit();
    var row: i32 = 0;
    while (row < source.h) : (row += 1) {
        const source_start = baseline.index(source.x, source.y + row);
        const captured_start = captured.index(0, row);
        const width: usize = @intCast(source.w);
        @memcpy(
            captured.pixels[captured_start .. captured_start + width],
            baseline.pixels[source_start .. source_start + width],
        );
    }
    return captured;
}

// ---------------------------------------------------------------------------
// Overlay
// ---------------------------------------------------------------------------

fn runOverlay(app: *App) !void {
    if (!registerClass()) return error.ClassRegistrationFailed;

    app.interaction = try interaction_mod.Interaction.init(app.allocator, app.surfaces);
    defer {
        app.interaction.?.deinit();
        app.interaction = null;
    }

    for (app.displays.items) |display| try createWindow(app, display);

    // Seed the loupe before presenting any window, then show them, take the
    // system cursor away and hand the pointer to the fine cursor.
    const initial_cursor = updateHoverFromMouse(app);
    showOverlays(app);
    hideCursor();
    var cursor_hidden = true;
    defer if (cursor_hidden) showCursor();
    defer releasePointer(app);

    if (initial_cursor) |global| {
        // The fine cursor is driven by raw mouse deltas, so it is only taken over
        // when a raw mouse actually registered. Without one the pointer would
        // have nothing to follow and the loupe would not move at all, which is
        // worse than the compositor driving it, as it does with `--no-fine`.
        if (registerRawInput(app)) _ = beginFinePointer(app, global);
    }

    var message: win32.MSG = undefined;
    while (!app.finished) {
        while (win32.PeekMessageW(&message, null, 0, 0, win32.pm_remove) != 0) {
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }
        if (app.finished) break;
        // Every mouse event above only widened `dirty`; this is the one compose
        // and the one present for all of them.
        presentAll(app);

        // Escape is polled, not only handled as a key message: a process started
        // from a hotkey cannot reliably take the foreground, and the overlay has
        // to be cancellable whatever the window manager decided.
        if (win32.GetAsyncKeyState(@intCast(win32.vk_escape)) < 0) {
            cancel(app);
            break;
        }
        _ = win32.MsgWaitForMultipleObjectsEx(0, null, 8, win32.qs_allinput, win32.mwmo_inputavailable);
    }

    for (app.displays.items) |display| {
        if (display.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
            display.hwnd = null;
        }
    }
    showCursor();
    cursor_hidden = false;
}

fn registerClass() bool {
    const Cache = struct {
        var attempted: bool = false;
        var registered: bool = false;
    };
    if (Cache.attempted) return Cache.registered;
    Cache.attempted = true;

    const class = win32.WNDCLASSW{
        .style = 0,
        .lpfnWndProc = &windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.idc_arrow),
        // No background brush: the window is painted from a complete canvas and
        // an erase would only flash the underlying desktop.
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
    };
    Cache.registered = win32.RegisterClassW(&class) != 0;
    return Cache.registered;
}

fn createWindow(app: *App, display: *Display) !void {
    const x = display.physical.left;
    const y = display.physical.top;
    const width = display.physical.width();
    const height = display.physical.height();

    const hwnd = win32.CreateWindowExW(
        win32.ws_ex_topmost | win32.ws_ex_toolwindow | win32.ws_ex_layered,
        class_name,
        window_title,
        win32.ws_popup,
        x,
        y,
        width,
        height,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowFailed;
    display.hwnd = hwnd;

    const surface = try createSurfaceCanvas(app.allocator, width, height);
    display.canvas = surface.canvas;
    display.canvas_bitmap = surface.bitmap;
    display.canvas_dc = surface.dc;
    paintRegion(display, display.canvas.?.rect());
}

/// A canvas backed by a DIB section that a memory DC holds: the shape
/// `UpdateLayeredWindowIndirect` takes its pixels from, and premultiplied BGRA
/// top-down is exactly what the core already produces, so presenting is a copy.
const SurfaceCanvas = struct {
    canvas: Canvas,
    bitmap: win32.HBITMAP,
    dc: win32.HDC,
};

fn createSurfaceCanvas(allocator: std.mem.Allocator, width: i32, height: i32) !SurfaceCanvas {
    if (width <= 0 or height <= 0) return error.EmptyCapture;

    const screen = win32.GetDC(null) orelse return error.NoScreenDc;
    defer _ = win32.ReleaseDC(null, screen);
    const dc = win32.CreateCompatibleDC(screen) orelse return error.NoMemoryDc;
    errdefer _ = win32.DeleteDC(dc);

    var info = bitmapInfo(width, height);
    var bits: ?*anyopaque = null;
    const bitmap = win32.CreateDIBSection(screen, &info, win32.dib_rgb_colors, &bits, null, 0) orelse
        return error.CreateDibFailed;
    errdefer _ = win32.DeleteObject(bitmap);

    const previous = win32.SelectObject(dc, bitmap);
    // Deliberately left selected: this memory DC keeps the canvas for the
    // lifetime of the overlay, and every paint blits out of it.
    _ = previous;

    const raw = bits orelse return error.CreateDibFailed;
    const pixels: [*]u32 = @ptrCast(@alignCast(raw));
    const count: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    return .{
        .canvas = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .pixels = pixels[0..count],
            .allocator = allocator,
        },
        .bitmap = bitmap,
        .dc = dc,
    };
}

fn displayForWindow(hwnd: ?win32.HWND) ?*Display {
    const app = current_app orelse return null;
    for (app.displays.items) |display| {
        if (display.hwnd == hwnd and hwnd != null) return display;
    }
    return null;
}

/// Present every overlay's first frame, show it above the taskbar without
/// stealing the click that will dismiss it, then take the foreground so keys
/// arrive. Present before show: a layered window that has not been given its
/// pixels yet is transparent, and the desktop would show through it. This is
/// the same reason the macOS frontend flushes its first frame before it takes
/// the cursor away.
fn showOverlays(app: *App) void {
    for (app.displays.items) |display| {
        presentDisplay(display);
        const hwnd = display.hwnd orelse continue;
        _ = win32.SetWindowPos(
            hwnd,
            win32.hwnd_topmost,
            display.physical.left,
            display.physical.top,
            display.physical.width(),
            display.physical.height(),
            win32.swp_showwindow | win32.swp_noactivate,
        );
    }
    if (app.displays.items.len > 0) takeForeground(app.displays.items[0].hwnd orelse return);
}

fn hideOverlays(app: *App) void {
    for (app.displays.items) |display| {
        if (display.hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.sw_hide);
    }
}

/// The documented dance for a process that did not start in the foreground: a
/// thread attached to the current foreground thread is allowed to hand the
/// foreground over.
fn takeForeground(hwnd: win32.HWND) void {
    const foreground = win32.GetForegroundWindow();
    const target = win32.GetWindowThreadProcessId(foreground, null);
    const this = win32.GetCurrentThreadId();
    const attached = target != 0 and target != this and
        win32.AttachThreadInput(this, target, 1) != 0;
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.SetFocus(hwnd);
    if (attached) _ = win32.AttachThreadInput(this, target, 0);
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// Widen the frame's dirty rectangle. Nothing is composed or presented here:
/// a mouse event only records what changed, and `presentAll` turns everything
/// recorded since the last frame into one compose and one present.
fn paintRegion(display: *Display, region: Rect) void {
    const canvas = display.canvas orelse return;
    const clipped = region.clamped(canvas.width, canvas.height);
    if (clipped.isEmpty()) return;
    display.dirty = if (display.dirty) |dirty| dirty.unionWith(clipped) else clipped;
}

fn presentAll(app: *App) void {
    for (app.displays.items) |display| presentDisplay(display);
}

/// Compose the dirty rectangle into the canvas and hand exactly that rectangle
/// to the window system as one layered-window update.
///
/// Why a layered window and not `BitBlt` into a paint DC: DWM composites a
/// redirected window from its surface whenever it likes, including halfway
/// through a sequence of blits into it, and a frame caught between the erase of
/// the old loupe and the draw of the new one has no loupe - which the eye reads
/// as the instrument flickering as it moves. `UpdateLayeredWindowIndirect`
/// presents the dirty rectangle as a single transaction, so every frame the
/// compositor can see is a whole one.
fn presentDisplay(display: *Display) void {
    const canvas = &(display.canvas orelse return);
    const hwnd = display.hwnd orelse return;
    const source = display.canvas_dc orelse return;
    const dirty = display.dirty orelse return;
    display.dirty = null;

    // GDI batches; make sure nothing still reads the canvas while we write it.
    _ = win32.GdiFlush();
    if (current_app) |app| {
        if (app.interaction) |*interaction| {
            interaction.render(display.interaction_id, canvas, dirty);
        }
    }

    const destination = win32.POINT{ .x = display.physical.left, .y = display.physical.top };
    const size = win32.SIZE{ .cx = display.physical.width(), .cy = display.physical.height() };
    const origin = win32.POINT{ .x = 0, .y = 0 };
    const blend = win32.BLENDFUNCTION{};
    const rect = win32.RECT{ .left = dirty.x, .top = dirty.y, .right = dirty.maxX(), .bottom = dirty.maxY() };
    const info = win32.UPDATELAYEREDWINDOWINFO{
        .cbSize = @sizeOf(win32.UPDATELAYEREDWINDOWINFO),
        .hdcDst = null,
        .pptDst = &destination,
        .psize = &size,
        .hdcSrc = source,
        .pptSrc = &origin,
        .crKey = 0,
        .pblend = &blend,
        .dwFlags = win32.ulw_alpha,
        .prcDirty = &rect,
    };
    if (win32.UpdateLayeredWindowIndirect(hwnd, &info) == 0) {
        std.debug.print("UpdateLayeredWindowIndirect failed: {d}\n", .{win32.GetLastError()});
        // Keep the whole frame dirty so a later present can retry rather than
        // silently treating a frame Windows never accepted as current.
        display.dirty = canvas.rect();
    }
}

/// Record one monitor's damage. This is the frontend's whole implementation of
/// the shared `PaintFn`.
fn paintDisplay(ctx: *anyopaque, surface: interaction_mod.SurfaceId, region: Rect) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    paintRegion(app.displays.items[surface], region);
}

fn windowProc(hwnd: ?win32.HWND, message: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (message) {
        // The loupe is the pointer while the overlay is up.
        win32.wm_setcursor => {
            _ = win32.SetCursor(null);
            return 1;
        },
        // Take the click as a click, not as an activation that is swallowed.
        win32.wm_mouseactivate => return win32.ma_activate,
        win32.wm_mousemove => {
            mouseMoved(hwnd, lParam);
            return 0;
        },
        win32.wm_lbuttondown => {
            _ = win32.SetCapture(hwnd.?);
            mouseMoved(hwnd, lParam);
            if (current_app) |app| beginSelection(app);
            return 0;
        },
        win32.wm_lbuttonup => {
            _ = win32.ReleaseCapture();
            mouseMoved(hwnd, lParam);
            if (current_app) |app| {
                if (app.interaction.?.isSelecting()) endSelection(app);
            }
            return 0;
        },
        win32.wm_rbuttondown => {
            if (current_app) |app| cancel(app);
            return 0;
        },
        win32.wm_mousewheel => {
            onWheel(message, wParam);
            return 0;
        },
        win32.wm_mousehwheel => {
            onWheel(message, wParam);
            return 0;
        },
        win32.wm_keydown => {
            onKey(wParam);
            return 0;
        },
        win32.wm_input => {
            onRawInput(lParam);
            // Required: the system frees the raw input buffer in the default
            // handler, and a window that swallows WM_INPUT leaks it.
            return win32.DefWindowProcW(hwnd, message, wParam, lParam);
        },
        win32.wm_destroy => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, message, wParam, lParam),
    }
}

// ---------------------------------------------------------------------------
// Gesture
// ---------------------------------------------------------------------------

fn updateCursor(app: *App, display: *Display, local: Point) void {
    interaction_mod.paintDamages(app.interaction.?.moveCursor(display.interaction_id, local), app, paintDisplay);
}

fn beginSelection(app: *App) void {
    interaction_mod.paintDamages(app.interaction.?.beginSelection(), app, paintDisplay);
}

fn endSelection(app: *App) void {
    if (app.interaction.?.endSelection()) |result| finish(app, result);
}

fn cancel(app: *App) void {
    if (app.finished or !app.interaction.?.cancel()) return;
    app.finished = true;
    terminate(app);
}

fn finish(app: *App, result: interaction_mod.Result) void {
    if (app.finished) return;
    app.finished = true;
    // Put the system pointer back under the fine cursor before dismissing.
    releasePointer(app);

    switch (result) {
        .color => |point| {
            const rgb = interaction_mod.colorAt(app.surfaces, point) orelse {
                out.fail("the pixel colour could not be read\n", .{});
                app.exit_code = 1;
                terminate(app);
                return;
            };
            const hex = color.hexString(rgb);
            out.print("{s}\n", .{hex});
            hideOverlays(app);
            copyText(&hex);
        },
        .screenshot => |rect| {
            hideOverlays(app);
            var canvas = captureScreenshot(app, rect) catch |err| {
                out.fail("screenshot failed: {t}\n", .{err});
                app.exit_code = 1;
                terminate(app);
                return;
            };
            defer canvas.deinit();
            const bytes = png.encode(app.allocator, canvas) catch |err| {
                out.fail("png encoding failed: {t}\n", .{err});
                app.exit_code = 1;
                terminate(app);
                return;
            };
            defer app.allocator.free(bytes);
            saveScreenshot(app, bytes);
            out.print("Screenshot copied to clipboard\n", .{});
            copyScreenshot(canvas, bytes);
        },
    }
    terminate(app);
}

/// Write the PNG into `--save-dir` if one was given, the same as the other
/// frontends. The clipboard copy is unaffected: a failed save is reported and
/// reflected in the exit code, but it does not stop the paste from working.
fn saveScreenshot(app: *App, bytes: []const u8) void {
    const dir = app.save_dir orelse return;
    const path = save.writePng(app.allocator, dir, bytes) catch |err| {
        out.fail("could not save screenshot to {s}: {t}\n", .{ dir, err });
        app.exit_code = 1;
        return;
    };
    defer app.allocator.free(path);
    out.print("Screenshot saved to {s}\n", .{path});
}

fn terminate(app: *App) void {
    app.finished = true;
    win32.PostQuitMessage(0);
}

/// Where the cursor goes for one mouse event. With a fine cursor running the
/// event's own position is ignored: raw deltas drive the cursor, and the
/// position only arrives because the system pointer is being dragged along.
fn mouseMoved(hwnd: ?win32.HWND, lParam: win32.LPARAM) void {
    const app = current_app orelse return;
    const interaction = &(app.interaction orelse return);
    if (interaction.fineActive()) return;
    const display = displayForWindow(hwnd) orelse return;

    // Client coordinates are device pixels relative to the window that got the
    // event, which under capture is the window the drag started in, even once
    // the pointer is over another monitor. Go through the global point and hit
    // test it, so the surface (and therefore the baseline the loupe samples) is
    // the monitor the pointer is actually on. Off every monitor, stay with the
    // window's own surface: the core clamps.
    const x: i16 = @truncate(lParam);
    const y: i16 = @truncate(lParam >> 16);
    const global = Point{
        .x = @as(f64, @floatFromInt(display.physical.left + x)) / app.scale,
        .y = @as(f64, @floatFromInt(display.physical.top + y)) / app.scale,
    };
    if (interaction_mod.hitTest(app.surfaces, global)) |hit| {
        updateCursor(app, app.displays.items[hit.surface], hit.local);
        return;
    }
    updateCursor(app, display, .{
        .x = global.x - display.logical.x,
        .y = global.y - display.logical.y,
    });
}

/// One wheel detent is one physical pixel of cursor movement, the same rule the
/// other frontends apply. The vertical wheel nudge y and the tilt wheel nudges
/// x, and shift swaps them: shift+wheel arrives as a plain vertical scroll and
/// has to be able to reach the other axis, exactly as the Wayland and macOS
/// frontends arrange it.
fn onWheel(message: win32.UINT, wParam: win32.WPARAM) void {
    const app = current_app orelse return;
    const interaction = &(app.interaction orelse return);
    if (!interaction.fineActive()) return;

    const raw: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
    const steps = std.math.clamp(@divTrunc(@as(i32, raw), 120), -10, 10);
    if (steps == 0) return;

    var horizontal = message == win32.wm_mousehwheel;
    if (win32.GetAsyncKeyState(@intCast(win32.vk_shift)) < 0) horizontal = !horizontal;
    // A detent is a device pixel; the nudge is in logical units.
    const distance: f64 = @as(f64, @floatFromInt(steps)) / app.scale;
    interaction_mod.paintDamages(interaction.nudgeFine(if (horizontal)
        Point{ .x = distance, .y = 0 }
    else
        Point{ .x = 0, .y = distance }), app, paintDisplay);
}

fn onKey(wParam: win32.WPARAM) void {
    const app = current_app orelse return;
    if (wParam == win32.vk_escape) {
        cancel(app);
    } else if (wParam == win32.vk_oem_minus or wParam == win32.vk_subtract) {
        adjustGain(app, 1 / cli.gain_step);
    } else if (wParam == win32.vk_oem_plus or wParam == win32.vk_add) {
        adjustGain(app, cli.gain_step);
    }
}

/// Change the fine cursor's speed on the fly, so it can be found by feel rather
/// than by re-running with another `--gain`.
fn adjustGain(app: *App, factor: f64) void {
    app.gain = cli.adjustedGain(app.gain, factor);
    if (app.interaction) |*interaction| interaction.setFineGain(app.gain);
}

/// The mouse, in the same shape the other frontends take it from: raw deltas,
/// free of the pointer acceleration that makes a count of mouse travel mean a
/// different number of pixels every time. False when the session offers no raw
/// mouse at all.
fn registerRawInput(app: *App) bool {
    const target = for (app.displays.items) |display| {
        if (display.hwnd) |hwnd| break hwnd;
    } else return false;

    var device = win32.RAWINPUTDEVICE{
        .usUsagePage = 0x01, // generic desktop
        .usUsage = 0x02, // mouse
        // Receive input even while another window is in the foreground: the
        // overlay cannot always take it, and the fine cursor must not care.
        .dwFlags = win32.ridev_inputsink,
        .hwndTarget = target,
    };
    return win32.RegisterRawInputDevices(@ptrCast(&device), 1, @sizeOf(win32.RAWINPUTDEVICE)) != 0;
}

fn onRawInput(lParam: win32.LPARAM) void {
    const app = current_app orelse return;
    const interaction = &(app.interaction orelse return);
    if (!interaction.fineActive()) return;

    const handle: win32.HANDLE = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const Buffer = extern struct {
        header: win32.RAWINPUTHEADER,
        mouse: win32.RAWMOUSE,
        padding: [64]u8,
    };
    var buffer: Buffer = undefined;
    var size: win32.UINT = @sizeOf(Buffer);
    const read = win32.GetRawInputData(handle, win32.rid_input, &buffer, &size, @sizeOf(win32.RAWINPUTHEADER));
    if (read == 0 or read == std.math.maxInt(win32.UINT)) return;
    if (buffer.header.dwType != win32.rim_typemouse) return;

    const delta = rawDelta(app, buffer.mouse);
    if (delta.x == 0 and delta.y == 0) return;

    interaction_mod.paintDamages(interaction.advanceFine(delta), app, paintDisplay);
    pinPointer(app);
}

/// The mouse's movement, as logical pixels, from one raw report.
///
/// A relative device reports counts; an absolute one (a touchpad, a pen, and
/// the pointing device a virtual machine presents) reports a position in a
/// 0..65535 space mapped over a screen, so consecutive reports are differenced
/// and scaled back into pixels. Absolute devices report finer than a pixel,
/// which is exactly what the fine cursor wants.
fn rawDelta(app: *App, mouse: win32.RAWMOUSE) Point {
    if (mouse.usFlags & win32.mouse_move_absolute != 0) {
        // Absolute reports are mapped over the primary monitor, or over the
        // whole virtual desktop when the device says so.
        const span = if (mouse.usFlags & win32.mouse_virtual_desktop != 0) app.virtual_span else app.primary_span;
        const point = win32.POINT{ .x = mouse.lLastX, .y = mouse.lLastY };
        defer app.last_absolute = point;
        const previous = app.last_absolute orelse return .{};

        // Span is in device pixels; the core wants logical units.
        const units: f64 = 65536 * app.scale;
        return .{
            .x = @as(f64, @floatFromInt(wrapDelta(previous.x, point.x))) * @as(f64, @floatFromInt(span.x)) / units,
            .y = @as(f64, @floatFromInt(wrapDelta(previous.y, point.y))) * @as(f64, @floatFromInt(span.y)) / units,
        };
    }

    app.last_absolute = null;
    return .{
        .x = @as(f64, @floatFromInt(mouse.lLastX)) * pixels_per_count,
        .y = @as(f64, @floatFromInt(mouse.lLastY)) * pixels_per_count,
    };
}

/// Difference of two absolute reports, taking the short way round the 0..65535
/// circle when a report lands on the other side of it.
fn wrapDelta(previous: i32, current: i32) i32 {
    var delta = current - previous;
    if (delta > 32767) delta -= 65536;
    if (delta < -32768) delta += 65536;
    return delta;
}

/// Keep the system pointer under the fine cursor. Windows will not detach the
/// pointer from the mouse, but it will let it be moved, and moving it back
/// under the fine cursor is both what the user sees and what stops the physical
/// mouse from running out of screen: the pointer can never settle against an
/// edge, so the reports keep coming.
fn pinPointer(app: *App) void {
    const interaction = &(app.interaction orelse return);
    const position = interaction.finePosition() orelse return;
    // The fine cursor is logical; the pointer is device pixels.
    const target_x = position.x * app.scale;
    const target_y = position.y * app.scale;

    var current: win32.POINT = undefined;
    if (win32.GetCursorPos(&current) != 0) {
        const dx = @abs(@as(f64, @floatFromInt(current.x)) - target_x);
        const dy = @abs(@as(f64, @floatFromInt(current.y)) - target_y);
        // Only when it has actually drifted: warping on every count of a
        // thousand-hertz mouse would be most of the work this tool does.
        if (dx < 4 and dy < 4) return;
    }
    _ = win32.SetCursorPos(@intFromFloat(@round(target_x)), @intFromFloat(@round(target_y)));
}

fn beginFinePointer(app: *App, global: Point) bool {
    if (app.gain <= 0) return false;
    const interaction = &(app.interaction orelse return false);
    interaction.beginFine(global, app.gain);
    app.pointer_detached = true;
    return true;
}

/// Put the system pointer under the fine cursor before letting go of it.
fn releasePointer(app: *App) void {
    if (!app.pointer_detached) return;
    pinPointer(app);
    app.pointer_detached = false;
}

fn hideCursor() void {
    while (win32.ShowCursor(0) >= 0) {}
}

fn showCursor() void {
    while (win32.ShowCursor(1) < 0) {}
}

fn updateHoverFromMouse(app: *App) ?Point {
    var position: win32.POINT = undefined;
    if (win32.GetCursorPos(&position) == 0) return null;
    const global = Point{
        .x = @as(f64, @floatFromInt(position.x)) / app.scale,
        .y = @as(f64, @floatFromInt(position.y)) / app.scale,
    };
    const hit = interaction_mod.hitTest(app.surfaces, global) orelse return null;
    updateCursor(app, app.displays.items[hit.surface], hit.local);
    return global;
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

fn copyText(text: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, text) catch return;
    defer std.heap.page_allocator.free(wide);

    if (!openClipboard()) return;
    defer _ = win32.CloseClipboard();
    if (win32.EmptyClipboard() == 0) return;

    const memory = wideMemory(wide) orelse return;
    // Ownership passes to the clipboard on success; freeing the block here would
    // leave the paste with nothing to read.
    if (win32.SetClipboardData(win32.cf_unicode_text, memory) == null) _ = win32.GlobalFree(memory);
}

/// The clipboard has a single owner at a time and other software holds it
/// constantly - a clipboard manager, a launcher, Parallels' own sharing agent -
/// so `OpenClipboard` failing is routine rather than exceptional. This tool
/// exists to put one thing on the clipboard; it is worth waiting for it.
fn openClipboard() bool {
    var attempt: u8 = 0;
    while (attempt < clipboard_attempts) : (attempt += 1) {
        if (win32.OpenClipboard(null) != 0) return true;
        win32.Sleep(clipboard_retry_ms);
    }
    return false;
}

const clipboard_attempts: u8 = 20;
const clipboard_retry_ms: u32 = 10;

/// A `GMEM_MOVEABLE` block holding `wide`, terminator included, already locked
/// and unlocked again. Null when the allocation fails.
fn wideMemory(wide: [:0]const u16) ?win32.HGLOBAL {
    const bytes = (wide.len + 1) * @sizeOf(u16);
    const memory = win32.GlobalAlloc(win32.gmem_moveable, bytes) orelse return null;
    const destination = win32.GlobalLock(memory) orelse {
        _ = win32.GlobalFree(memory);
        return null;
    };
    @memcpy(@as([*]u8, @ptrCast(destination))[0..bytes], std.mem.sliceAsBytes(wide[0 .. wide.len + 1]));
    _ = win32.GlobalUnlock(memory);
    return memory;
}

/// Publish a screenshot as both a DIB (what paint, word, explorer and most
/// apps ask for) and the registered `PNG` format (what browsers, chat clients
/// and image editors ask for, and the only one that survives transparency and
/// exact bytes). One clipboard generation, two formats.
fn copyScreenshot(canvas: Canvas, png_bytes: []const u8) void {
    if (!openClipboard()) return;
    defer _ = win32.CloseClipboard();
    if (win32.EmptyClipboard() == 0) return;

    if (dibMemory(canvas)) |memory| {
        if (win32.SetClipboardData(win32.cf_dib, memory) == null) _ = win32.GlobalFree(memory);
    }

    const format = win32.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("PNG"));
    if (format != 0) {
        if (blobMemory(png_bytes)) |memory| {
            if (win32.SetClipboardData(format, memory) == null) _ = win32.GlobalFree(memory);
        }
    }
}

/// A bottom-up 32bpp BI_RGB bitmap: a `BITMAPINFOHEADER` followed by the rows,
/// last row first. Alpha is dropped rather than clipped, because that is what
/// 32bpp BI_RGB means and the screen is opaque anyway.
fn dibMemory(canvas: Canvas) ?win32.HGLOBAL {
    const width: usize = canvas.width;
    const height: usize = canvas.height;
    if (width == 0 or height == 0) return null;

    const header_bytes = @sizeOf(win32.BITMAPINFOHEADER);
    const pixels_bytes = width * height * 4;
    const memory = win32.GlobalAlloc(win32.gmem_moveable, header_bytes + pixels_bytes) orelse return null;
    const block = win32.GlobalLock(memory) orelse {
        _ = win32.GlobalFree(memory);
        return null;
    };

    const header: *win32.BITMAPINFOHEADER = @ptrCast(@alignCast(block));
    header.* = bitmapInfo(@intCast(width), @intCast(height)).bmiHeader;
    header.biHeight = @intCast(height);

    const bytes: [*]u8 = @ptrCast(block);
    const pixels: [*]u32 = @ptrCast(@alignCast(bytes + header_bytes));
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const source = canvas.pixels[(height - 1 - row) * width ..][0..width];
        @memcpy(pixels[row * width ..][0..width], source);
    }

    _ = win32.GlobalUnlock(memory);
    return memory;
}

/// A `GMEM_MOVEABLE` block holding `bytes`, already locked and unlocked again.
fn blobMemory(bytes: []const u8) ?win32.HGLOBAL {
    const memory = win32.GlobalAlloc(win32.gmem_moveable, bytes.len) orelse return null;
    const block = win32.GlobalLock(memory) orelse {
        _ = win32.GlobalFree(memory);
        return null;
    };
    @memcpy(@as([*]u8, @ptrCast(block))[0..bytes.len], bytes);
    _ = win32.GlobalUnlock(memory);
    return memory;
}
