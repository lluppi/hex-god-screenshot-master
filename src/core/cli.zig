//! Command line parsing, shared by both frontends so they accept exactly the
//! same flags.

const std = @import("std");
const geom = @import("geom.zig");
const out = @import("out.zig");

/// Single source of truth for the version: the macOS installer reads this line
/// out of the source to fill CFBundleShortVersionString.
pub const version = "0.2.0";

pub const Command = union(enum) {
    /// No option: the overlay. Hover to inspect, click for hex, drag for a shot.
    interactive,
    /// Print and copy the hex of one logical point.
    pick: geom.Point,
    /// Copy one logical rectangle as a PNG.
    shot: geom.FRect,
    /// Print the displays and their scales.
    info,
};

/// Synthetic gestures for development: they drive the very same functions the
/// pointer handlers call, so a click or a drag can be exercised (and
/// screenshotted mid selection) without a mouse or an input injector on the box.
/// Only the Wayland frontend acts on them.
pub const Dev = union(enum) {
    none,
    click: geom.Point,
    drag: struct { start: geom.Point, end: geom.Point, via: ?geom.Point, hold_ms: u64 },
};

const dev_hold_default_ms: u64 = 1000;

pub const Parsed = union(enum) {
    run: struct { command: Command, dev: Dev },
    help,
    version,
    invalid: []const u8,
};

/// `args` excludes argv[0].
pub fn parse(args: []const []const u8) Parsed {
    var command: Command = .interactive;
    var click: ?geom.Point = null;
    var drag: ?geom.FRect = null;
    var via: ?geom.Point = null;
    var hold_ms: u64 = dev_hold_default_ms;

    var rest = Cursor{ .items = args };
    while (rest.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pick")) {
            const value = rest.next() orelse return .{ .invalid = "--pick needs X,Y" };
            command = .{ .pick = parsePoint(value) orelse return .{ .invalid = "--pick needs X,Y" } };
        } else if (std.mem.eql(u8, arg, "--shot")) {
            const value = rest.next() orelse return .{ .invalid = "--shot needs X,Y,W,H" };
            command = .{ .shot = parseRect(value) orelse return .{ .invalid = "--shot needs X,Y,W,H" } };
        } else if (std.mem.eql(u8, arg, "--info")) {
            command = .info;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--dev-click")) {
            const value = rest.next() orelse return .{ .invalid = "--dev-click needs X,Y" };
            click = parsePoint(value) orelse return .{ .invalid = "--dev-click needs X,Y" };
        } else if (std.mem.eql(u8, arg, "--dev-drag")) {
            const value = rest.next() orelse return .{ .invalid = "--dev-drag needs X,Y,W,H" };
            drag = parseRect(value) orelse return .{ .invalid = "--dev-drag needs X,Y,W,H" };
        } else if (std.mem.eql(u8, arg, "--dev-via")) {
            const value = rest.next() orelse return .{ .invalid = "--dev-via needs X,Y" };
            via = parsePoint(value) orelse return .{ .invalid = "--dev-via needs X,Y" };
        } else if (std.mem.eql(u8, arg, "--dev-hold")) {
            const value = rest.next() orelse return .{ .invalid = "--dev-hold needs MS" };
            hold_ms = std.fmt.parseInt(u64, value, 10) catch return .{ .invalid = "--dev-hold needs MS" };
        } else {
            return .{ .invalid = "unknown argument" };
        }
    }

    const dev: Dev = if (drag) |rect|
        .{ .drag = .{
            .start = .{ .x = rect.x, .y = rect.y },
            .end = .{ .x = rect.maxX(), .y = rect.maxY() },
            .via = via,
            .hold_ms = hold_ms,
        } }
    else if (click) |point|
        .{ .click = point }
    else
        .none;
    return .{ .run = .{ .command = command, .dev = dev } };
}

/// Step through the argument list, so a flag can take the value that follows it.
const Cursor = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(self: *Cursor) ?[]const u8 {
        if (self.index >= self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

fn parsePoint(value: []const u8) ?geom.Point {
    const v = parseFloats(2, value) orelse return null;
    return .{ .x = v[0], .y = v[1] };
}

fn parseRect(value: []const u8) ?geom.FRect {
    const v = parseFloats(4, value) orelse return null;
    return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
}

/// Exactly `N` comma-separated floats, no more, no less.
fn parseFloats(comptime N: usize, value: []const u8) ?[N]f64 {
    var result: [N]f64 = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&result) |*slot| {
        slot.* = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    }
    if (parts.next() != null) return null;
    return result;
}

pub fn printVersion() void {
    out.print("hgsm {s}\n", .{version});
}

pub fn printUsage() void {
    out.print(
        \\usage: hgsm [option]
        \\
        \\  (no option)          overlay: hover to inspect, click for hex, drag for a screenshot
        \\  --pick X,Y           print and copy the hex of a pixel, in logical coordinates
        \\  --shot X,Y,W,H       copy a logical rectangle as a PNG screenshot
        \\  --info               print the displays and their scales
        \\  --version            print the version
        \\  --help, -h           print this
        \\
        \\ Development (linux): drive a synthetic gesture through the real handlers,
        \\ so the click and drag paths can be exercised from a script.
        \\  --dev-click X,Y      click at a logical point
        \\  --dev-drag X,Y,W,H   drag from X,Y to X+W,Y+H
        \\  --dev-via X,Y        pause at a mid point during the drag
        \\  --dev-hold MS        how long to hold each step (default 1000)
        \\
    , .{});
}
