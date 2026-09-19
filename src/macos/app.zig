//! macOS frontend: AppKit overlay windows painted from the shared core, and
//! CoreGraphics for capture.
//!
//! Structurally identical to the Wayland frontend: one borderless window per
//! display covering it exactly, a baseline grab per display taken with
//! `CGDisplayCreateImage` before the overlay appears, the same gesture state
//! machine, the same loupe, and a fresh `CGDisplayCreateImageForRect` grab once
//! the windows are ordered out for the final screenshot.
//!
//! NOTE: this file cannot be compiled on Linux (no Apple SDK) and has not been
//! run on macOS yet. It is written against the documented AppKit/CoreGraphics
//! ABI: see src/macos/objc.zig for what is declared and why.

const std = @import("std");
const objc = @import("objc.zig");
const geom = @import("../core/geom.zig");
const canvas_mod = @import("../core/canvas.zig");
const color = @import("../core/color.zig");
const gesture = @import("../core/gesture.zig");
const magnifier = @import("../core/magnifier.zig");
const overlay_mod = @import("../core/overlay.zig");
const sampling = @import("../core/sampling.zig");
const png = @import("../core/png.zig");
const cli = @import("../core/cli.zig");
const sys = @import("../core/sys.zig");
const out = @import("../core/out.zig");

const id = objc.id;
const SEL = objc.SEL;
const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const Point = geom.Point;
const FRect = geom.FRect;

const overlay_settle_ms: u64 = 60;

const Display = struct {
    app: *App,
    id: objc.CGDirectDisplayID,
    /// Global logical rect, y down from the top-left of the primary display.
    logical: FRect = .{},
    /// Physical pixels per logical pixel.
    scale: f64 = 1,
    /// The display as it was before the overlay appeared.
    baseline: ?Canvas = null,
    /// Backing store for the overlay window, physical pixels.
    canvas: ?Canvas = null,
    window: id = null,
    view: id = null,
    dirty: std.ArrayList(Rect) = .empty,
    /// Where the size badge was last drawn, so the next move can erase it. The
    /// badge sits outside the selection rectangle, so it needs its own damage.
    last_badge: ?Rect = null,

    fn localLogical(self: *Display, global: Point) Point {
        return .{ .x = global.x - self.logical.x, .y = global.y - self.logical.y };
    }

    fn toPhysical(self: *Display, local: Point) Point {
        return .{ .x = local.x * self.scale, .y = local.y * self.scale };
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    displays: std.ArrayList(*Display) = .empty,
    /// Bottom edge of the primary display in AppKit coordinates, used to flip
    /// between AppKit's y-up space and the core's y-down space.
    main_max_y: f64 = 0,
    coordinator: gesture.Coordinator = .{},
    cursor_display: ?*Display = null,
    cursor_local: Point = .{},
    cursor_global: Point = .{},
    selection: ?FRect = null,
    buttons: u32 = 0,
    loupe_display: ?*Display = null,
    loupe_origin: ?Point = null,
    loupe_active: bool = false,
    last_sample_hex: ?color.Rgb = null,
    sample: ?Canvas = null,
    finished: bool = false,
    exit_code: u8 = 0,
};

var current_app: ?*App = null;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(minimal: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var args = try minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var rest: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try rest.append(allocator, arg);

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

    var app = App{ .allocator = allocator };

    // NSApplication first: NSScreen is only populated once it exists.
    const application = objc.msgSend(id, objc.class("NSApplication"), objc.sel("sharedApplication"), .{});
    objc.msgSend(void, application, objc.sel("setActivationPolicy:"), .{objc.application_activation_policy_accessory});

    if (!objc.CGPreflightScreenCaptureAccess()) {
        _ = objc.CGRequestScreenCaptureAccess();
        if (!objc.CGPreflightScreenCaptureAccess()) {
            out.fail(
                \\Screen Recording permission is required.
                \\Enable it for this binary in System Settings > Privacy & Security
                \\> Screen & System Audio Recording, then run it again.
                \\
            , .{});
            std.process.exit(1);
        }
    }

    try collectDisplays(&app);
    try captureBaselines(&app);

    switch (options.mode) {
        .info => printInfo(&app),
        .pick => {
            const point = options.pick.?;
            const rgb = pickColor(&app, point) orelse {
                out.fail("no display contains {d},{d}\n", .{ point.x, point.y });
                std.process.exit(1);
            };
            const hex = color.hexString(rgb);
            out.print("{s}\n", .{hex});
            copyText(&hex);
        },
        .shot => {
            const canvas = try captureScreenshot(&app, options.shot.?);
            const bytes = try png.encode(allocator, canvas);
            out.print("Screenshot copied to clipboard\n", .{});
            copyPng(bytes);
        },
        .interactive => {
            try startOverlay(&app);
            current_app = &app;
            objc.msgSend(void, application, objc.sel("activateIgnoringOtherApps:"), .{true});
            updateHoverFromMouse(&app);
            objc.msgSend(void, application, objc.sel("run"), .{});
            current_app = null;
        },
    }

    if (app.exit_code != 0) std.process.exit(app.exit_code);
}

// ---------------------------------------------------------------------------
// Displays
// ---------------------------------------------------------------------------

fn collectDisplays(app: *App) !void {
    const screens = objc.msgSend(id, objc.class("NSScreen"), objc.sel("screens"), .{});
    const count = objc.msgSend(objc.NSUInteger, screens, objc.sel("count"), .{});
    if (count == 0) return error.NoDisplays;

    const primary = objc.msgSend(objc.CGRect, objc.msgSend(id, screens, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, 0)}), objc.sel("frame"), .{});
    app.main_max_y = primary.maxY();

    const number_key = objc.msgSend(
        id,
        objc.class("NSString"),
        objc.sel("stringWithUTF8String:"),
        .{@as([*:0]const u8, "NSScreenNumber")},
    );

    var index: objc.NSUInteger = 0;
    while (index < count) : (index += 1) {
        const screen = objc.msgSend(id, screens, objc.sel("objectAtIndex:"), .{index});
        const frame = objc.msgSend(objc.CGRect, screen, objc.sel("frame"), .{});
        const scale = objc.msgSend(f64, screen, objc.sel("backingScaleFactor"), .{});

        const description = objc.msgSend(id, screen, objc.sel("deviceDescription"), .{});
        const number = objc.msgSend(id, description, objc.sel("objectForKey:"), .{number_key});
        if (number == null) continue;
        const display_id: objc.CGDirectDisplayID = @intCast(objc.msgSend(c_int, number, objc.sel("intValue"), .{}));

        const display = try app.allocator.create(Display);
        display.* = .{
            .app = app,
            .id = display_id,
            .logical = .{
                .x = frame.origin.x,
                .y = app.main_max_y - frame.maxY(),
                .w = frame.size.width,
                .h = frame.size.height,
            },
            .scale = if (scale > 0) scale else 1,
        };
        try app.displays.append(app.allocator, display);
    }
}

fn captureBaselines(app: *App) !void {
    for (app.displays.items) |display| {
        const image = objc.CGDisplayCreateImage(display.id) orelse {
            out.fail("could not capture display {d}\n", .{display.id});
            return error.CaptureFailed;
        };
        defer objc.CGImageRelease(image);
        display.baseline = try canvasFromImage(app.allocator, image, objc.interpolation_none);
        const baseline = display.baseline.?;
        if (display.logical.w > 0) {
            display.scale = @as(f64, @floatFromInt(baseline.width)) / display.logical.w;
        }
    }
}

fn printInfo(app: *App) void {
    for (app.displays.items) |display| {
        out.print(
            "display {d}: {d}x{d} logical at {d},{d} scale {d:.3} baseline {d}x{d}\n",
            .{
                display.id,
                @as(i64, @intFromFloat(display.logical.w)),
                @as(i64, @intFromFloat(display.logical.h)),
                @as(i64, @intFromFloat(display.logical.x)),
                @as(i64, @intFromFloat(display.logical.y)),
                display.scale,
                display.baseline.?.width,
                display.baseline.?.height,
            },
        );
    }
}

fn canvasFromImage(
    allocator: std.mem.Allocator,
    image: objc.CGImageRef,
    quality: c_int,
) !Canvas {
    const width = objc.CGImageGetWidth(image);
    const height = objc.CGImageGetHeight(image);
    if (width == 0 or height == 0) return error.EmptyImage;

    var canvas = try Canvas.init(allocator, @intCast(width), @intCast(height));
    errdefer canvas.deinit();

    const space = objc.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
    defer objc.CGColorSpaceRelease(space);
    const context = objc.CGBitmapContextCreate(
        @ptrCast(canvas.pixels.ptr),
        width,
        height,
        8,
        width * 4,
        space,
        objc.bitmap_info_argb8888,
    ) orelse return error.NoContext;
    defer objc.CGContextRelease(context);

    objc.CGContextSetInterpolationQuality(context, quality);
    objc.CGContextDrawImage(context, objc.CGRect.make(0, 0, @floatFromInt(width), @floatFromInt(height)), image);
    return canvas;
}

// ---------------------------------------------------------------------------
// Overlay windows
// ---------------------------------------------------------------------------

fn startOverlay(app: *App) !void {
    const view_class = viewClass();
    const window_class = windowClass();
    if (view_class == null or window_class == null) return error.ClassRegistrationFailed;

    app.sample = try Canvas.init(app.allocator, magnifier.sample_side, magnifier.sample_side);
    for (app.displays.items) |display| {
        try createWindow(app, display, view_class, window_class);
    }
}

fn createWindow(app: *App, display: *Display, view_class: objc.Class, window_class: objc.Class) !void {
    const frame = objc.CGRect.make(
        display.logical.x,
        app.main_max_y - (display.logical.y + display.logical.h),
        display.logical.w,
        display.logical.h,
    );

    var window = objc.msgSend(id, window_class, objc.sel("alloc"), .{});
    window = objc.msgSend(id, window, objc.sel("initWithContentRect:styleMask:backing:defer:"), .{
        frame,
        objc.window_style_borderless,
        objc.backing_store_buffered,
        false,
    });
    if (window == null) return error.WindowFailed;

    objc.msgSend(void, window, objc.sel("setLevel:"), .{objc.window_level_screen_saver});
    objc.msgSend(void, window, objc.sel("setOpaque:"), .{false});
    objc.msgSend(void, window, objc.sel("setHasShadow:"), .{false});
    objc.msgSend(void, window, objc.sel("setBackgroundColor:"), .{
        objc.msgSend(id, objc.class("NSColor"), objc.sel("clearColor"), .{}),
    });
    objc.msgSend(void, window, objc.sel("setCollectionBehavior:"), .{
        objc.collection_behavior_can_join_all_spaces |
            objc.collection_behavior_full_screen_auxiliary,
    });
    objc.msgSend(void, window, objc.sel("setAcceptsMouseMovedEvents:"), .{true});

    var view = objc.msgSend(id, view_class, objc.sel("alloc"), .{});
    view = objc.msgSend(id, view, objc.sel("initWithFrame:"), .{
        objc.CGRect.make(0, 0, display.logical.w, display.logical.h),
    });
    objc.msgSend(void, window, objc.sel("setContentView:"), .{view});

    display.window = window;
    display.view = view;
    const pixel_width: u32 = @intFromFloat(@round(display.logical.w * display.scale));
    const pixel_height: u32 = @intFromFloat(@round(display.logical.h * display.scale));
    display.canvas = try Canvas.init(app.allocator, pixel_width, pixel_height);

    paintRegion(display, display.canvas.?.rect());

    objc.msgSend(void, window, objc.sel("makeKeyAndOrderFront:"), .{@as(id, null)});
    objc.msgSend(void, window, objc.sel("makeFirstResponder:"), .{view});
}

fn hideOverlays(app: *App) void {
    for (app.displays.items) |display| {
        if (display.window) |window| {
            objc.msgSend(void, window, objc.sel("orderOut:"), .{@as(id, null)});
        }
    }
    app.loupe_active = false;
    app.loupe_display = null;
    app.loupe_origin = null;
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// Compose a region into a display's canvas and mark it for redraw.
fn paintRegion(display: *Display, region: Rect) void {
    const app = display.app;
    const canvas = &(display.canvas orelse return);
    const clipped = region.clamped(canvas.width, canvas.height);
    if (clipped.isEmpty()) return;

    canvas.setClip(clipped);
    const scene = overlay_mod.Scene{
        .baseline = &(display.baseline orelse return),
        .selection = selectionPhysical(display),
        .cursor = cursorPhysical(display),
        .ui_scale = display.scale,
    };
    overlay_mod.renderRegion(canvas, scene, clipped);
    if (app.loupe_active and app.loupe_display == display) {
        if (app.loupe_origin) |origin| {
            if (app.sample) |sample| {
                overlay_mod.renderMagnifier(canvas, origin, sample, display.scale);
            }
        }
    }
    canvas.clearClip();

    // View coordinates are points and y up.
    const points = objc.CGRect.make(
        @as(f64, @floatFromInt(clipped.x)) / display.scale,
        display.logical.h - @as(f64, @floatFromInt(clipped.maxY())) / display.scale,
        @as(f64, @floatFromInt(clipped.w)) / display.scale,
        @as(f64, @floatFromInt(clipped.h)) / display.scale,
    );
    if (display.view) |view| {
        objc.msgSend(void, view, objc.sel("setNeedsDisplayInRect:"), .{points});
    }
}

fn selectionPhysical(display: *Display) ?Rect {
    const selection = display.app.selection orelse return null;
    return rectPhysical(display, selection);
}

fn rectPhysical(display: *Display, selection: FRect) ?Rect {
    const local = FRect{
        .x = selection.x - display.logical.x,
        .y = selection.y - display.logical.y,
        .w = selection.w,
        .h = selection.h,
    };
    const physical = Rect.roundF(.{
        .x = local.x * display.scale,
        .y = local.y * display.scale,
        .w = local.w * display.scale,
        .h = local.h * display.scale,
    });
    if (physical.isEmpty()) return null;
    return physical;
}

fn cursorPhysical(display: *Display) ?Point {
    if (display.app.cursor_display != display) return null;
    return display.toPhysical(display.app.cursor_local);
}

fn displayForView(view: id) ?*Display {
    const app = current_app orelse return null;
    for (app.displays.items) |display| {
        if (display.view == view) return display;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Gesture
// ---------------------------------------------------------------------------

fn updateCursor(app: *App, display: *Display, local: Point) void {
    app.cursor_display = display;
    app.cursor_local = local;
    app.cursor_global = .{ .x = display.logical.x + local.x, .y = display.logical.y + local.y };

    if (app.coordinator.isSelecting()) {
        // Drive the state machine on every move, otherwise the selection stays
        // the zero sized rectangle `begin` created and no box is ever drawn.
        _ = app.coordinator.move(app.cursor_global);
        updateSelection(app);
    } else {
        updateLoupe(app);
    }
}

fn updateLoupe(app: *App) void {
    const display = app.cursor_display orelse return;
    var sample = app.sample orelse return;
    const baseline = &(display.baseline orelse return);

    sampling.fillSample(&sample, baseline, display.scale, app.cursor_local);
    const rgb = magnifier.hexAt(sample) orelse return;

    const physical = display.toPhysical(app.cursor_local);
    const origin = magnifier.windowOrigin(physical, display.scale);

    const previous_display = app.loupe_display;
    const previous_origin = app.loupe_origin;
    if (app.loupe_active and previous_display == display and previous_origin != null) {
        const old = previous_origin.?;
        if (std.meta.eql(app.last_sample_hex, rgb) and
            @abs(old.x - origin.x) < 0.5 and @abs(old.y - origin.y) < 0.5)
        {
            return;
        }
    }

    app.last_sample_hex = rgb;
    app.loupe_display = display;
    app.loupe_origin = origin;
    app.loupe_active = true;

    var damage = magnifier.windowRect(origin, display.scale).expand(2);
    if (previous_origin) |old| {
        damage = damage.unionWith(magnifier.windowRect(old, display.scale).expand(2));
    }
    if (previous_display) |old_display| {
        if (old_display != display) {
            if (previous_origin) |old| {
                paintRegion(old_display, magnifier.windowRect(old, old_display.scale).expand(2));
            }
        }
    }
    paintRegion(display, damage);
}

fn hideLoupe(app: *App) void {
    if (!app.loupe_active) return;
    app.loupe_active = false;
    app.last_sample_hex = null;
    if (app.loupe_display) |display| {
        if (app.loupe_origin) |origin| {
            paintRegion(display, magnifier.windowRect(origin, display.scale).expand(2));
        }
    }
    app.loupe_display = null;
    app.loupe_origin = null;
}

fn updateSelection(app: *App) void {
    const next = app.coordinator.selection;
    const previous = app.selection;
    app.selection = next;

    for (app.displays.items) |display| {
        var damage = Rect{};
        if (previous) |rect| {
            if (rectPhysical(display, rect)) |physical| damage = damage.unionWith(physical);
        }
        if (next) |rect| {
            if (rectPhysical(display, rect)) |physical| damage = damage.unionWith(physical);
        }
        // The size badge is drawn beside the cursor, outside the selection, so it
        // has to be damaged explicitly or it is composed nowhere.
        if (display.last_badge) |previous_badge| damage = damage.unionWith(previous_badge);
        display.last_badge = null;
        if (next) |rect| {
            if (rectPhysical(display, rect)) |physical| {
                if (cursorPhysical(display)) |cursor| {
                    const canvas_rect = if (display.canvas) |canvas| canvas.rect() else Rect{};
                    if (overlay_mod.sizeBadge(physical, cursor, display.scale, canvas_rect)) |badge| {
                        damage = damage.unionWith(badge.rect.expand(2));
                        display.last_badge = badge.rect;
                    }
                }
            }
        }
        if (!damage.isEmpty()) paintRegion(display, damage.expand(3));
    }
}

fn beginSelection(app: *App) void {
    _ = app.coordinator.begin(app.cursor_global);
    app.selection = app.coordinator.selection;
    updateSelection(app);
}

fn endSelection(app: *App) void {
    const event = app.coordinator.end(app.cursor_global);
    app.selection = app.coordinator.selection;
    switch (event) {
        .finished => |result| finish(app, result),
        else => {},
    }
}

fn cancel(app: *App) void {
    if (app.finished) return;
    app.finished = true;
    terminate();
}

fn finish(app: *App, result: gesture.Result) void {
    if (app.finished) return;
    app.finished = true;
    hideLoupe(app);

    switch (result) {
        .color => |point| {
            const rgb = pickColor(app, point) orelse {
                out.fail("the pixel colour could not be read\n", .{});
                app.exit_code = 1;
                terminate();
                return;
            };
            const hex = color.hexString(rgb);
            out.print("{s}\n", .{hex});
            hideOverlays(app);
            sys.sleepMs(overlay_settle_ms);
            copyText(&hex);
        },
        .screenshot => |rect| {
            hideOverlays(app);
            sys.sleepMs(overlay_settle_ms);
            const canvas = captureScreenshot(app, rect) catch |err| {
                out.fail("screenshot failed: {t}\n", .{err});
                app.exit_code = 1;
                terminate();
                return;
            };
            const bytes = png.encode(app.allocator, canvas) catch |err| {
                out.fail("png encoding failed: {t}\n", .{err});
                app.exit_code = 1;
                terminate();
                return;
            };
            out.print("Screenshot copied to clipboard\n", .{});
            copyPng(bytes);
        },
    }
    terminate();
}

fn terminate() void {
    const application = objc.msgSend(id, objc.class("NSApplication"), objc.sel("sharedApplication"), .{});
    objc.msgSend(void, application, objc.sel("terminate:"), .{@as(id, null)});
}

fn pickColor(app: *App, global: Point) ?color.Rgb {
    for (app.displays.items) |display| {
        const baseline = display.baseline orelse continue;
        const local = display.localLogical(global);
        if (local.x < 0 or local.y < 0) continue;
        if (local.x >= display.logical.w or local.y >= display.logical.h) continue;
        return sampling.sampleHex(&baseline, display.scale, local);
    }
    return null;
}

/// Capture a global logical rectangle.
///
/// A rectangle that sits on one display keeps the captured pixels exactly as
/// CoreGraphics produced them; only a selection spanning displays needs a
/// composed image in a common pixel grid.
fn captureScreenshot(app: *App, rect: FRect) !Canvas {
    var single: ?*Display = null;
    var count: usize = 0;
    for (app.displays.items) |display| {
        if (intersectionOf(display, rect) == null) continue;
        single = display;
        count += 1;
    }
    if (count == 1) {
        const display = single.?;
        const intersection = intersectionOf(display, rect).?;
        const image = try captureDisplayRegion(display, intersection);
        defer objc.CGImageRelease(image);
        return canvasFromImage(app.allocator, image, objc.interpolation_none);
    }

    var scale: f64 = 1;
    for (app.displays.items) |display| scale = @max(scale, display.scale);

    const width: u32 = @intFromFloat(@max(1, @round(rect.w * scale)));
    const height: u32 = @intFromFloat(@max(1, @round(rect.h * scale)));
    var composite = try Canvas.init(app.allocator, width, height);

    for (app.displays.items) |display| {
        const intersection = intersectionOf(display, rect) orelse continue;
        const image = try captureDisplayRegion(display, intersection);
        defer objc.CGImageRelease(image);

        var captured = try canvasFromImage(app.allocator, image, objc.interpolation_high);
        const destination = Rect.roundF(.{
            .x = (intersection.x - rect.x) * scale,
            .y = (intersection.y - rect.y) * scale,
            .w = intersection.w * scale,
            .h = intersection.h * scale,
        });
        composite.blitNearest(captured, destination);
        captured.deinit();
    }
    return composite;
}

/// The part of `rect` that lands on `display`, in global logical coordinates.
fn intersectionOf(display: *Display, rect: FRect) ?FRect {
    const intersection = FRect{
        .x = @max(rect.x, display.logical.x),
        .y = @max(rect.y, display.logical.y),
        .w = @min(rect.maxX(), display.logical.maxX()) - @max(rect.x, display.logical.x),
        .h = @min(rect.maxY(), display.logical.maxY()) - @max(rect.y, display.logical.y),
    };
    if (intersection.isEmpty()) return null;
    return intersection;
}

fn captureDisplayRegion(display: *Display, intersection: FRect) !objc.CGImageRef {
    const local = display.localLogical(.{ .x = intersection.x, .y = intersection.y });
    // CGDisplayCreateImageForRect takes display-local points, y down.
    const request = objc.CGRect.make(local.x, local.y, intersection.w, intersection.h);
    return objc.CGDisplayCreateImageForRect(display.id, request) orelse {
        out.fail("could not capture display {d}\n", .{display.id});
        return error.CaptureFailed;
    };
}

fn updateHoverFromMouse(app: *App) void {
    const location = objc.msgSend(objc.CGPoint, objc.class("NSEvent"), objc.sel("mouseLocation"), .{});
    const global = Point{ .x = location.x, .y = app.main_max_y - location.y };
    for (app.displays.items) |display| {
        const local = display.localLogical(global);
        if (local.x < 0 or local.y < 0) continue;
        if (local.x >= display.logical.w or local.y >= display.logical.h) continue;
        updateCursor(app, display, local);
        return;
    }
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

fn nsString(bytes: []const u8) id {
    const allocated = objc.msgSend(id, objc.class("NSString"), objc.sel("alloc"), .{});
    return objc.msgSend(id, allocated, objc.sel("initWithBytes:length:encoding:"), .{
        bytes.ptr,
        bytes.len,
        @as(objc.NSUInteger, 4), // NSUTF8StringEncoding
    });
}

fn pasteboard() id {
    return objc.msgSend(id, objc.class("NSPasteboard"), objc.sel("generalPasteboard"), .{});
}

fn copyText(text: []const u8) void {
    const board = pasteboard();
    _ = objc.msgSend(objc.NSInteger, board, objc.sel("clearContents"), .{});
    const pasteboard_type = objc.msgSend(
        id,
        objc.class("NSString"),
        objc.sel("stringWithUTF8String:"),
        .{@as([*:0]const u8, "public.utf8-plain-text")},
    );
    _ = objc.msgSend(bool, board, objc.sel("setString:forType:"), .{ nsString(text), pasteboard_type });
}

fn copyPng(bytes: []const u8) void {
    const board = pasteboard();
    _ = objc.msgSend(objc.NSInteger, board, objc.sel("clearContents"), .{});
    const data = objc.msgSend(id, objc.class("NSData"), objc.sel("dataWithBytes:length:"), .{
        bytes.ptr,
        bytes.len,
    });
    const pasteboard_type = objc.msgSend(
        id,
        objc.class("NSString"),
        objc.sel("stringWithUTF8String:"),
        .{@as([*:0]const u8, "public.png")},
    );
    _ = objc.msgSend(bool, board, objc.sel("setData:forType:"), .{ data, pasteboard_type });
}

// ---------------------------------------------------------------------------
// Runtime defined classes: the overlay window and the view that paints it
// ---------------------------------------------------------------------------

fn viewClass() objc.Class {
    const Methods = struct {
        const list = [_]objc.Method{
            .{ .name = "drawRect:", .imp = @ptrCast(&viewDrawRect) },
            .{ .name = "acceptsFirstResponder", .imp = @ptrCast(&viewAcceptsFirstResponder) },
            .{ .name = "acceptsFirstMouse:", .imp = @ptrCast(&viewAcceptsFirstMouse) },
            .{ .name = "mouseMoved:", .imp = @ptrCast(&viewMouseMoved) },
            .{ .name = "mouseDown:", .imp = @ptrCast(&viewMouseDown) },
            .{ .name = "mouseDragged:", .imp = @ptrCast(&viewMouseDragged) },
            .{ .name = "mouseUp:", .imp = @ptrCast(&viewMouseUp) },
            .{ .name = "rightMouseDown:", .imp = @ptrCast(&viewRightMouseDown) },
            .{ .name = "keyDown:", .imp = @ptrCast(&viewKeyDown) },
            .{ .name = "resetCursorRects", .imp = @ptrCast(&viewResetCursorRects) },
        };
    };
    const Cache = struct {
        var value: objc.Class = null;
    };
    if (Cache.value == null) {
        Cache.value = objc.defineClass("HexGodOverlayView", objc.class("NSView"), &Methods.list);
    }
    return Cache.value;
}

fn windowClass() objc.Class {
    const Methods = struct {
        const list = [_]objc.Method{
            .{ .name = "canBecomeKeyWindow", .imp = @ptrCast(&windowCanBecomeKey) },
            .{ .name = "canBecomeMainWindow", .imp = @ptrCast(&windowCanBecomeMain) },
        };
    };
    const Cache = struct {
        var value: objc.Class = null;
    };
    if (Cache.value == null) {
        Cache.value = objc.defineClass("HexGodOverlayWindow", objc.class("NSWindow"), &Methods.list);
    }
    return Cache.value;
}

fn viewDrawRect(self: id, cmd: SEL, rect: objc.CGRect) callconv(.c) void {
    _ = cmd;
    _ = rect; // AppKit only calls us for the dirty region and clips to it.
    const display = displayForView(self) orelse return;
    const canvas = display.canvas orelse return;

    const image = cgImageFromCanvas(canvas) orelse return;
    defer objc.CGImageRelease(image);

    const graphics_context = objc.msgSend(id, objc.class("NSGraphicsContext"), objc.sel("currentContext"), .{});
    if (graphics_context == null) return;
    const context = objc.msgSend(?*anyopaque, graphics_context, objc.sel("CGContext"), .{}) orelse return;
    const bounds = objc.msgSend(objc.CGRect, self, objc.sel("bounds"), .{});
    objc.CGContextSetInterpolationQuality(@ptrCast(context), objc.interpolation_none);
    objc.CGContextDrawImage(@ptrCast(context), bounds, image);
}

extern "c" fn CGImageCreate(
    width: usize,
    height: usize,
    bits_per_component: usize,
    bits_per_pixel: usize,
    bytes_per_row: usize,
    space: objc.CGColorSpaceRef,
    bitmap_info: u32,
    provider: ?*anyopaque,
    decode: ?*const f64,
    should_interpolate: bool,
    intent: c_int,
) ?objc.CGImageRef;
extern "c" fn CGDataProviderCreateWithData(
    info: ?*anyopaque,
    data: ?*const anyopaque,
    size: usize,
    release: ?*const fn (?*anyopaque, ?*const anyopaque, usize) callconv(.c) void,
) ?*anyopaque;
extern "c" fn CGDataProviderRelease(provider: *anyopaque) void;

/// Wrap a canvas in a CGImage without copying pixels.
fn cgImageFromCanvas(canvas: Canvas) ?objc.CGImageRef {
    const space = objc.CGColorSpaceCreateDeviceRGB() orelse return null;
    defer objc.CGColorSpaceRelease(space);
    const length = @as(usize, canvas.width) * canvas.height * 4;
    const provider = CGDataProviderCreateWithData(null, canvas.pixels.ptr, length, null) orelse return null;
    defer CGDataProviderRelease(provider);
    return CGImageCreate(
        canvas.width,
        canvas.height,
        8,
        32,
        @as(usize, canvas.width) * 4,
        space,
        objc.bitmap_info_argb8888,
        provider,
        null,
        false,
        0,
    );
}

fn viewAcceptsFirstResponder(self: id, cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = cmd;
    return true;
}

fn viewAcceptsFirstMouse(self: id, cmd: SEL, event: id) callconv(.c) bool {
    _ = self;
    _ = cmd;
    _ = event;
    return true;
}

fn viewResetCursorRects(self: id, cmd: SEL) callconv(.c) void {
    _ = self;
    _ = cmd;
    // The crosshair is applied on every mouse move instead.
}

fn windowCanBecomeKey(self: id, cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = cmd;
    return true;
}

fn windowCanBecomeMain(self: id, cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = cmd;
    return true;
}

/// View-local point, y down, from an AppKit mouse event.
fn viewPoint(view: id, display: *Display, event: id) Point {
    const window_point = objc.msgSend(objc.CGPoint, event, objc.sel("locationInWindow"), .{});
    _ = view;
    // The view is not flipped, so the window's y grows upwards.
    return .{ .x = window_point.x, .y = display.logical.h - window_point.y };
}

fn viewMouseMoved(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    setCrosshairCursor();
    updateCursor(app, display, viewPoint(self, display, event));
}

fn viewMouseDown(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    app.buttons += 1;
    updateCursor(app, display, viewPoint(self, display, event));
    hideLoupe(app);
    beginSelection(app);
}

fn viewMouseDragged(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    updateCursor(app, display, viewPoint(self, display, event));
}

fn viewMouseUp(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    if (app.buttons > 0) app.buttons -= 1;
    updateCursor(app, display, viewPoint(self, display, event));
    if (app.coordinator.isSelecting()) endSelection(app);
}

fn viewRightMouseDown(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = self;
    _ = cmd;
    _ = event;
    const app = current_app orelse return;
    cancel(app);
}

fn viewKeyDown(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = self;
    _ = cmd;
    const app = current_app orelse return;
    const keycode = objc.msgSend(u16, event, objc.sel("keyCode"), .{});
    if (keycode == objc.escape_keycode) cancel(app);
}

fn setCrosshairCursor() void {
    const cursor = objc.msgSend(id, objc.class("NSCursor"), objc.sel("crosshairCursor"), .{});
    if (cursor != null) objc.msgSend(void, cursor, objc.sel("set"), .{});
}
