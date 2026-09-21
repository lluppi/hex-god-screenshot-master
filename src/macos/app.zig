//! macOS frontend: AppKit overlay windows painted from the shared core, and
//! CoreGraphics for capture.
//!
//! Structurally identical to the Wayland frontend: one borderless window per
//! display covering it exactly, a baseline grab per display taken with
//! `CGDisplayCreateImage` before the overlay appears, the same gesture state
//! machine and the same loupe. Final screenshots crop the baseline the user
//! selected from, so dismissing the overlay needs no second display capture.
//!
//! NOTE: this file cannot be compiled on Linux (no Apple SDK) and has not been
//! run on macOS yet. It is written against the documented AppKit/CoreGraphics
//! ABI: see src/macos/objc.zig for what is declared and why.
//!
//! Known parity gap: the pointer can only be in one display's window at a time,
//! so there is no mouseExited handler and the loupe is never cleared when the
//! cursor crosses between displays. The Wayland frontend drives
//! `Interaction.leaveSurface` for that.

const std = @import("std");
const objc = @import("objc.zig");
const geom = @import("../core/geom.zig");
const canvas_mod = @import("../core/canvas.zig");
const color = @import("../core/color.zig");
const interaction_mod = @import("../core/interaction.zig");
const png = @import("../core/png.zig");
const save = @import("../core/save.zig");
const cli = @import("../core/cli.zig");
const out = @import("../core/out.zig");

const id = objc.id;
const SEL = objc.SEL;
const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const Point = geom.Point;
const FRect = geom.FRect;

const Display = struct {
    app: *App,
    id: objc.CGDirectDisplayID,
    interaction_id: interaction_mod.SurfaceId = 0,
    /// Global logical rect, y down from the top-left of the primary display.
    logical: FRect = .{},
    /// Physical pixels per logical pixel.
    scale: f64 = 1,
    /// The display as it was before the overlay appeared.
    baseline: ?Canvas = null,
    /// Keeps borrowed baseline pixels alive when the capture format is native.
    baseline_data: ?objc.CFDataRef = null,
    /// Backing store for the overlay window, physical pixels.
    canvas: ?Canvas = null,
    /// Physical damage waiting to be composed at the next AppKit draw.
    pending_damage: ?Rect = null,
    window: id = null,
    view: id = null,
};

const App = struct {
    allocator: std.mem.Allocator,
    displays: std.ArrayList(*Display) = .empty,
    /// The displays as the shared interaction sees them, built once after the
    /// baselines exist. Indexed by `interaction_id`.
    surfaces: []interaction_mod.Surface = &.{},
    /// Bottom edge of the primary display in AppKit coordinates, used to flip
    /// between AppKit's y-up space and the core's y-down space.
    main_max_y: f64 = 0,
    interaction: ?interaction_mod.Interaction = null,
    /// Logical pixels of cursor movement per unit of the mouse's own delta, from
    /// `--gain`. Zero keeps the pointer driving the cursor, as it always did.
    gain: f64 = 0,
    /// Directory from `--save-dir`: each screenshot is also written there as a
    /// PNG. Null means clipboard only, which is the default.
    save_dir: ?[]const u8 = null,
    pointer_detached: bool = false,
    finished: bool = false,
    exit_code: u8 = 0,
};

/// Set while the overlay is up, so the runtime-defined view and window callbacks
/// (which receive no user data) can reach the app. It is the one piece of global
/// state in this frontend: AppKit's delegate-less selector dispatch has nowhere
/// else to put a context pointer.
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
    defer releaseBaselineData(&app);
    app.surfaces = try buildSurfaces(&app);

    switch (command) {
        .info => printInfo(&app),
        .pick => |point| {
            const rgb = interaction_mod.colorAt(app.surfaces, point) orelse {
                out.fail("no display contains {d},{d}\n", .{ point.x, point.y });
                std.process.exit(1);
            };
            const hex = color.hexString(rgb);
            out.print("{s}\n", .{hex});
            copyText(&hex);
        },
        .shot => |rect| {
            const canvas = try captureScreenshot(&app, rect);
            const bytes = try png.encode(allocator, canvas);
            saveScreenshot(&app, bytes);
            out.print("Screenshot copied to clipboard\n", .{});
            copyPng(bytes);
        },
        .interactive => {
            switch (dev) {
                .none => {},
                else => {
                    out.fail("synthetic gestures are linux-only\n", .{});
                    std.process.exit(2);
                },
            }
            // Window ordering can invoke drawRect synchronously, so callbacks
            // must be able to find this app before startOverlay creates them.
            current_app = &app;
            defer current_app = null;
            try startOverlay(&app);
            defer {
                app.interaction.?.deinit();
                app.interaction = null;
            }
            // Seed the loupe before presenting any window, then submit the
            // first frames before taking the system cursor away.
            const initial_cursor = updateHoverFromMouse(&app);
            objc.msgSend(void, application, objc.sel("activateIgnoringOtherApps:"), .{true});
            showOverlays(&app);
            hideCursor();
            defer showCursor();
            defer releasePointer(&app);
            if (initial_cursor) |global| _ = beginFinePointer(&app, global);
            objc.msgSend(void, application, objc.sel("run"), .{});
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
            .scale = 1,
        };
        try app.displays.append(app.allocator, display);
    }
}

/// Grab every display once, before the overlay appears.
///
/// The scale is derived from the captured pixel size rather than AppKit's
/// `backingScaleFactor`, so it is the scale of the pixels we actually sample and
/// crop; it is the single source of truth for `Display.scale`.
fn captureBaselines(app: *App) !void {
    errdefer releaseBaselineData(app);
    for (app.displays.items) |display| {
        const image = objc.CGDisplayCreateImage(display.id) orelse {
            out.fail("could not capture display {d}\n", .{display.id});
            return error.CaptureFailed;
        };
        defer objc.CGImageRelease(image);
        const captured = try canvasFromImage(app.allocator, image);
        display.baseline = captured.canvas;
        display.baseline_data = captured.data;
        const baseline = display.baseline.?;
        if (display.logical.w > 0) {
            display.scale = @as(f64, @floatFromInt(baseline.width)) / display.logical.w;
        }
    }
}

fn releaseBaselineData(app: *App) void {
    for (app.displays.items) |display| {
        if (display.baseline_data) |data| objc.CFRelease(data);
        display.baseline_data = null;
    }
}

/// The immutable per-display surfaces the shared interaction works in, built
/// once after the baselines exist. `interaction_id` is the index.
fn buildSurfaces(app: *App) ![]interaction_mod.Surface {
    const surfaces = try app.allocator.alloc(interaction_mod.Surface, app.displays.items.len);
    for (app.displays.items, 0..) |display, index| {
        display.interaction_id = index;
        surfaces[index] = .{ .logical = display.logical, .scale = display.scale, .baseline = &display.baseline.? };
    }
    return surfaces;
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
    out.print("fine pointer: mouse deltas\n", .{});
}

const ImageCanvas = struct {
    canvas: Canvas,
    data: ?objc.CFDataRef = null,
};

fn canvasFromImage(allocator: std.mem.Allocator, image: objc.CGImageRef) !ImageCanvas {
    const width = objc.CGImageGetWidth(image);
    const height = objc.CGImageGetHeight(image);
    if (width == 0 or height == 0) return error.EmptyImage;

    const row_bytes = width * 4;
    const byte_length = row_bytes * height;
    if (objc.CGImageGetBitsPerPixel(image) == 32 and
        objc.CGImageGetBytesPerRow(image) == row_bytes and
        objc.CGImageGetBitmapInfo(image) == objc.bitmap_info_argb8888)
    {
        if (objc.CGImageGetDataProvider(image)) |provider| {
            if (objc.CGDataProviderCopyData(provider)) |data| {
                if (objc.CFDataGetLength(data) >= @as(isize, @intCast(byte_length))) {
                    if (objc.CFDataGetBytePtr(data)) |bytes| {
                        const pixels: [*]u32 = @ptrCast(@alignCast(@constCast(bytes)));
                        return .{
                            .canvas = .{
                                .width = @intCast(width),
                                .height = @intCast(height),
                                .pixels = pixels[0 .. width * height],
                                .allocator = allocator,
                            },
                            .data = data,
                        };
                    }
                }
                objc.CFRelease(data);
            }
        }
    }

    var canvas = try Canvas.initUninitialized(allocator, @intCast(width), @intCast(height));
    errdefer canvas.deinit();
    const space = objc.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
    defer objc.CGColorSpaceRelease(space);
    const context = objc.CGBitmapContextCreate(
        @ptrCast(canvas.pixels.ptr),
        width,
        height,
        8,
        row_bytes,
        space,
        objc.bitmap_info_argb8888,
    ) orelse return error.NoContext;
    defer objc.CGContextRelease(context);

    objc.CGContextSetInterpolationQuality(context, objc.interpolation_none);
    objc.CGContextDrawImage(context, objc.CGRect.make(0, 0, @floatFromInt(width), @floatFromInt(height)), image);
    return .{ .canvas = canvas };
}

// ---------------------------------------------------------------------------
// Overlay windows
// ---------------------------------------------------------------------------

fn startOverlay(app: *App) !void {
    const view_class = viewClass();
    const window_class = windowClass();
    if (view_class == null or window_class == null) return error.ClassRegistrationFailed;

    app.interaction = try interaction_mod.Interaction.init(app.allocator, app.surfaces);
    errdefer {
        app.interaction.?.deinit();
        app.interaction = null;
    }
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

    // Canvas is device RGB with 8-bit components. Let WindowServer handle the
    // final display conversion instead of expanding both full-screen images
    // into a floating-point backing store on the CPU at first presentation.
    objc.msgSend(void, window, objc.sel("setDynamicDepthLimit:"), .{false});
    objc.msgSend(void, window, objc.sel("setDepthLimit:"), .{objc.window_depth_rgb8});
    objc.msgSend(void, window, objc.sel("setColorSpace:"), .{
        objc.msgSend(id, objc.class("NSColorSpace"), objc.sel("deviceRGBColorSpace"), .{}),
    });
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
    display.canvas = try Canvas.initUninitialized(app.allocator, pixel_width, pixel_height);

    paintRegion(display, display.canvas.?.rect());
    objc.msgSend(void, window, objc.sel("makeFirstResponder:"), .{view});
}

/// Present the initial loupe with the background before hiding the system
/// cursor. Waiting for NSApplication.run to draw leaves a cursorless gap.
fn showOverlays(app: *App) void {
    for (app.displays.items) |display| {
        const window = display.window orelse continue;
        objc.msgSend(void, window, objc.sel("makeKeyAndOrderFront:"), .{@as(id, null)});
        objc.msgSend(void, window, objc.sel("displayIfNeeded"), .{});
        objc.msgSend(void, window, objc.sel("flushWindow"), .{});
    }
    // Modern AppKit records display lists: flushWindow alone can return before
    // drawRect runs. Commit the backing-layer draws too, before hiding the cursor.
    objc.msgSend(void, objc.class("CATransaction"), objc.sel("flush"), .{});
}

fn hideOverlays(app: *App) void {
    for (app.displays.items) |display| {
        if (display.window) |window| {
            objc.msgSend(void, window, objc.sel("orderOut:"), .{@as(id, null)});
        }
    }
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// Accumulate a region for the next AppKit draw instead of recomposing once
/// per mouse event. AppKit coalesces these invalidations to the display cadence.
fn paintRegion(display: *Display, region: Rect) void {
    const canvas = display.canvas orelse return;
    const clipped = region.clamped(canvas.width, canvas.height);
    if (clipped.isEmpty()) return;

    display.pending_damage = if (display.pending_damage) |pending|
        pending.unionWith(clipped)
    else
        clipped;

    if (display.view) |view| {
        objc.msgSend(void, view, objc.sel("setNeedsDisplayInRect:"), .{viewRectFromCanvasRect(display, clipped)});
    }
}

/// Convert a physical, top-down canvas rectangle to AppKit points, y up.
fn viewRectFromCanvasRect(display: *const Display, rect: Rect) objc.CGRect {
    return objc.CGRect.make(
        @as(f64, @floatFromInt(rect.x)) / display.scale,
        display.logical.h - @as(f64, @floatFromInt(rect.maxY())) / display.scale,
        @as(f64, @floatFromInt(rect.w)) / display.scale,
        @as(f64, @floatFromInt(rect.h)) / display.scale,
    );
}

/// Convert an AppKit dirty rectangle to the physical pixels that cover it.
fn canvasRectFromViewRect(display: *const Display, rect: objc.CGRect) Rect {
    const x0: i32 = @intFromFloat(@floor(rect.origin.x * display.scale));
    const x1: i32 = @intFromFloat(@ceil(rect.maxX() * display.scale));
    const y0: i32 = @intFromFloat(@floor((display.logical.h - rect.maxY()) * display.scale));
    const y1: i32 = @intFromFloat(@ceil((display.logical.h - rect.origin.y) * display.scale));
    return Rect{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
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

/// Repaint one display's region. This is the frontend's whole implementation of
/// the shared `PaintFn`.
fn paintDisplay(ctx: *anyopaque, surface: interaction_mod.SurfaceId, region: Rect) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    paintRegion(app.displays.items[surface], region);
}

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
    releasePointer(app);
    terminate();
}

fn finish(app: *App, result: interaction_mod.Result) void {
    if (app.finished) return;
    app.finished = true;
    // Restore the system pointer before dismissing the overlay.
    releasePointer(app);

    switch (result) {
        .color => |point| {
            const rgb = interaction_mod.colorAt(app.surfaces, point) orelse {
                out.fail("the pixel colour could not be read\n", .{});
                app.exit_code = 1;
                terminate();
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
                terminate();
                return;
            };
            defer canvas.deinit();
            const bytes = png.encode(app.allocator, canvas) catch |err| {
                out.fail("png encoding failed: {t}\n", .{err});
                app.exit_code = 1;
                terminate();
                return;
            };
            saveScreenshot(app, bytes);
            out.print("Screenshot copied to clipboard\n", .{});
            copyPng(bytes);
        },
    }
    terminate();
}

/// Write the PNG into `--save-dir` if one was given, the same as the linux
/// frontend. The clipboard copy is unaffected: a failed save is reported and
/// reflected in the exit code, but it does not stop the paste from working.
fn saveScreenshot(app: *App, bytes: []const u8) void {
    const dir = app.save_dir orelse return;
    const path = save.writePng(app.allocator, dir, bytes) catch |err| {
        out.fail("could not save screenshot to {s}: {t}\n", .{ dir, err });
        app.exit_code = 1;
        return;
    };
    out.print("Screenshot saved to {s}\n", .{path});
}

fn terminate() void {
    const application = objc.msgSend(id, objc.class("NSApplication"), objc.sel("sharedApplication"), .{});
    objc.msgSend(void, application, objc.sel("terminate:"), .{@as(id, null)});
}

/// Capture a global logical rectangle. The composition and the single-display
/// shortcut both live in the shared interaction; this only supplies the
/// per-display capture.
fn captureScreenshot(app: *App, rect: FRect) !Canvas {
    return interaction_mod.captureScreenshot(app.allocator, app.surfaces, rect, app, captureOne);
}

/// Crop one display's share from the baseline already shown under the overlay.
/// This is both WYSIWYG and avoids another WindowServer capture after dragging.
fn captureOne(app: *App, surface: interaction_mod.SurfaceId, intersection: FRect) anyerror!Canvas {
    const display = app.displays.items[surface];
    const baseline = display.baseline.?;
    const source = Rect.roundF(.{
        .x = (intersection.x - display.logical.x) * display.scale,
        .y = (intersection.y - display.logical.y) * display.scale,
        .w = intersection.w * display.scale,
        .h = intersection.h * display.scale,
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

fn updateHoverFromMouse(app: *App) ?Point {
    const location = objc.msgSend(objc.CGPoint, objc.class("NSEvent"), objc.sel("mouseLocation"), .{});
    const global = Point{ .x = location.x, .y = app.main_max_y - location.y };
    const hit = interaction_mod.hitTest(app.surfaces, global) orelse return null;
    updateCursor(app, app.displays.items[hit.surface], hit.local);
    return global;
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
            .{ .name = "drawRect:", .imp = @ptrCast(&viewDrawRect), .types = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}" },
            .{ .name = "acceptsFirstResponder", .imp = @ptrCast(&viewAcceptsFirstResponder), .types = objc.bool_no_args },
            .{ .name = "acceptsFirstMouse:", .imp = @ptrCast(&viewAcceptsFirstMouse), .types = objc.bool_object_arg },
            .{ .name = "mouseMoved:", .imp = @ptrCast(&viewMouseMoved), .types = "v@:@" },
            .{ .name = "mouseDown:", .imp = @ptrCast(&viewMouseDown), .types = "v@:@" },
            .{ .name = "mouseDragged:", .imp = @ptrCast(&viewMouseDragged), .types = "v@:@" },
            .{ .name = "mouseUp:", .imp = @ptrCast(&viewMouseUp), .types = "v@:@" },
            .{ .name = "rightMouseDown:", .imp = @ptrCast(&viewRightMouseDown), .types = "v@:@" },
            .{ .name = "scrollWheel:", .imp = @ptrCast(&viewScrollWheel), .types = "v@:@" },
            .{ .name = "keyDown:", .imp = @ptrCast(&viewKeyDown), .types = "v@:@" },
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
            .{ .name = "canBecomeKeyWindow", .imp = @ptrCast(&windowCanBecomeKey), .types = objc.bool_no_args },
            .{ .name = "canBecomeMainWindow", .imp = @ptrCast(&windowCanBecomeMain), .types = objc.bool_no_args },
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
    const display = displayForView(self) orelse return;
    const canvas = &(display.canvas orelse return);

    if (display.pending_damage) |damage| {
        const interaction = &(display.app.interaction orelse return);
        interaction.render(display.interaction_id, canvas, damage);
        display.pending_damage = null;
    }

    const region = canvasRectFromViewRect(display, rect).clamped(canvas.width, canvas.height);
    if (region.isEmpty()) return;
    const image = cgImageFromCanvasRegion(canvas.*, region) orelse return;
    defer objc.CGImageRelease(image);

    const graphics_context = objc.msgSend(id, objc.class("NSGraphicsContext"), objc.sel("currentContext"), .{});
    if (graphics_context == null) return;
    const context = objc.msgSend(?*anyopaque, graphics_context, objc.sel("CGContext"), .{}) orelse return;
    objc.CGContextClipToRect(@ptrCast(context), rect);
    objc.CGContextSetInterpolationQuality(@ptrCast(context), objc.interpolation_none);
    objc.CGContextDrawImage(@ptrCast(context), viewRectFromCanvasRect(display, region), image);
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
extern "c" fn CGImageCreateWithImageInRect(
    image: objc.CGImageRef,
    rect: objc.CGRect,
) ?objc.CGImageRef;

/// Wrap the canvas without copying, then crop CoreGraphics' view of it to the
/// dirty region. The full wrapper keeps every row in bounds at the canvas stride.
fn cgImageFromCanvasRegion(canvas: Canvas, region: Rect) ?objc.CGImageRef {
    const clipped = region.clamped(canvas.width, canvas.height);
    if (clipped.isEmpty()) return null;

    const space = objc.CGColorSpaceCreateDeviceRGB() orelse return null;
    defer objc.CGColorSpaceRelease(space);
    const row_bytes = @as(usize, canvas.width) * 4;
    const length = row_bytes * canvas.height;
    const provider = CGDataProviderCreateWithData(null, canvas.pixels.ptr, length, null) orelse return null;
    defer CGDataProviderRelease(provider);
    const image = CGImageCreate(
        canvas.width,
        canvas.height,
        8,
        32,
        row_bytes,
        space,
        objc.bitmap_info_argb8888,
        provider,
        null,
        false,
        0,
    ) orelse return null;
    defer objc.CGImageRelease(image);

    return CGImageCreateWithImageInRect(image, objc.CGRect.make(
        @floatFromInt(clipped.x),
        @floatFromInt(clipped.y),
        @floatFromInt(clipped.w),
        @floatFromInt(clipped.h),
    ));
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
fn viewPoint(display: *Display, event: id) Point {
    const window_point = objc.msgSend(objc.CGPoint, event, objc.sel("locationInWindow"), .{});
    // The view is not flipped, so the window's y grows upwards.
    return .{ .x = window_point.x, .y = display.logical.h - window_point.y };
}

/// Where the cursor goes for one mouse event: the fine cursor moves by the
/// event's own deltas, or the compositor's pointer position moves it directly.
fn mouseMoved(app: *App, display: *Display, event: id) void {
    if (fineStep(app, display, event)) return;
    updateCursor(app, display, viewPoint(display, event));
}

/// Advance the fine cursor from a mouse event, taking the pointer over on the
/// first move. Returns false when there is no fine cursor to advance, which
/// leaves the caller with the plain cursor position.
fn fineStep(app: *App, display: *Display, event: id) bool {
    const interaction = &(app.interaction orelse return false);
    if (app.gain <= 0) return false;

    if (!interaction.fineActive()) {
        const local = viewPoint(display, event);
        return beginFinePointer(
            app,
            .{ .x = display.logical.x + local.x, .y = display.logical.y + local.y },
        );
    }

    const delta = Point{
        .x = objc.msgSend(f64, event, objc.sel("deltaX"), .{}),
        .y = objc.msgSend(f64, event, objc.sel("deltaY"), .{}),
    };
    if (delta.x == 0 and delta.y == 0) return true;
    interaction_mod.paintDamages(interaction.advanceFine(delta), app, paintDisplay);
    return true;
}

/// One wheel detent is one physical pixel of cursor movement, the same rule the
/// linux frontend applies to `axis_discrete`. A trackpad's smooth scrolling
/// rounds to nothing and is ignored.
fn viewScrollWheel(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = self;
    _ = cmd;
    const app = current_app orelse return;
    const interaction = &(app.interaction orelse return);
    if (!interaction.fineActive()) return;
    const global = interaction.finePosition() orelse return;
    const hit = interaction_mod.hitTest(app.surfaces, global) orelse return;
    const display = app.displays.items[hit.surface];

    const scroll_x = objc.msgSend(f64, event, objc.sel("scrollingDeltaX"), .{});
    const scroll_y = objc.msgSend(f64, event, objc.sel("scrollingDeltaY"), .{});
    const steps_x = std.math.clamp(@round(scroll_x), -10, 10);
    const steps_y = std.math.clamp(@round(scroll_y), -10, 10);
    if (steps_x == 0 and steps_y == 0) return;

    interaction_mod.paintDamages(interaction.nudgeFine(.{
        .x = steps_x / display.scale,
        .y = steps_y / display.scale,
    }), app, paintDisplay);
}

fn viewMouseMoved(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    mouseMoved(app, display, event);
}

fn viewMouseDown(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    mouseMoved(app, display, event);
    beginSelection(app);
}

fn viewMouseDragged(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    mouseMoved(app, display, event);
}

fn viewMouseUp(self: id, cmd: SEL, event: id) callconv(.c) void {
    _ = cmd;
    const app = current_app orelse return;
    const display = displayForView(self) orelse return;
    mouseMoved(app, display, event);
    if (app.interaction.?.isSelecting()) endSelection(app);
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
    if (keycode == objc.escape_keycode) {
        cancel(app);
    } else if (keycode == objc.minus_keycode) {
        adjustGain(app, 1 / cli.gain_step);
    } else if (keycode == objc.equal_keycode) {
        adjustGain(app, cli.gain_step);
    }
}

/// Change the fine cursor's speed on the fly, so it can be found by feel rather
/// than by re-running with another `--gain`.
fn adjustGain(app: *App, factor: f64) void {
    app.gain = cli.adjustedGain(app.gain, factor);
    if (app.interaction) |*interaction| interaction.setFineGain(app.gain);
}

fn beginFinePointer(app: *App, global: Point) bool {
    if (app.gain <= 0) return false;
    const interaction = &(app.interaction orelse return false);
    interaction.beginFine(global, app.gain);
    _ = objc.CGAssociateMouseAndMouseCursorPosition(0);
    app.pointer_detached = true;
    return true;
}

/// Put the system cursor under the fine cursor before reconnecting the mouse.
fn releasePointer(app: *App) void {
    if (!app.pointer_detached) return;
    if (app.interaction) |*interaction| {
        if (interaction.finePosition()) |position| {
            _ = objc.CGWarpMouseCursorPosition(.{ .x = position.x, .y = position.y });
        }
    }
    _ = objc.CGAssociateMouseAndMouseCursorPosition(1);
    app.pointer_detached = false;
}

fn hideCursor() void {
    objc.msgSend(void, objc.class("NSCursor"), objc.sel("hide"), .{});
}

fn showCursor() void {
    objc.msgSend(void, objc.class("NSCursor"), objc.sel("unhide"), .{});
}
