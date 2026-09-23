//! Command line parsing, shared by every frontend so they accept exactly the
//! same flags.

const std = @import("std");
const geom = @import("geom.zig");
const out = @import("out.zig");

/// Single source of truth for the version, printed by `--version`.
pub const version = "0.1.0";

/// Logical pixels of overlay cursor travel per unit of raw pointer delta. At 1
/// it moves as fast as the compositor's own cursor; below 1 it is deliberately
/// slower, which buys back the pixels the integer logical grid throws away.
pub const default_gain: f64 = 0.5;

/// Bounds on `--gain`. Zero means "no fine cursor at all", which is the same as
/// `--no-fine`; the upper bound is there to stop a typo turning the cursor into
/// something that crosses the screen in one twitch.
pub const max_gain: f64 = 20;

/// How much one press of `-` or `=` changes the fine cursor's speed, and how
/// slow it is allowed to get.
pub const gain_step: f64 = 1.25;
pub const gain_min: f64 = 0.02;

const gain_range_error = std.fmt.comptimePrint(
    "--gain must be between 0 and {d}",
    .{max_gain},
);

/// Apply one keyboard gain adjustment without re-enabling an explicitly
/// disabled fine cursor.
pub fn adjustedGain(gain: f64, factor: f64) f64 {
    if (gain == 0) return 0;
    return std.math.clamp(gain * factor, gain_min, max_gain);
}

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
    run: struct { command: Command, dev: Dev, gain: f64, save_dir: ?[]const u8 },
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
    var gain: f64 = default_gain;
    var save_dir: ?[]const u8 = null;

    var rest = Cursor{ .items = args };
    while (rest.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pick")) {
            const value = rest.next() orelse return .{ .invalid = "--pick needs X,Y" };
            command = .{ .pick = parsePoint(value) orelse return .{ .invalid = "--pick needs X,Y" } };
        } else if (std.mem.eql(u8, arg, "--shot")) {
            const value = rest.next() orelse return .{ .invalid = "--shot needs X,Y,W,H" };
            const rect = parseRect(value) orelse return .{ .invalid = "--shot needs X,Y,W,H" };
            if (rect.isEmpty()) return .{ .invalid = "--shot needs a positive W and H" };
            command = .{ .shot = rect };
        } else if (std.mem.eql(u8, arg, "--save-dir")) {
            const value = rest.next() orelse return .{ .invalid = "--save-dir needs a directory" };
            if (value.len == 0) return .{ .invalid = "--save-dir needs a directory" };
            save_dir = value;
        } else if (std.mem.eql(u8, arg, "--info")) {
            command = .info;
        } else if (std.mem.eql(u8, arg, "--gain")) {
            const value = rest.next() orelse return .{ .invalid = "--gain needs a number" };
            gain = std.fmt.parseFloat(f64, value) catch return .{ .invalid = "--gain needs a number" };
            if (!std.math.isFinite(gain) or gain < 0 or gain > max_gain) {
                return .{ .invalid = gain_range_error };
            }
        } else if (std.mem.eql(u8, arg, "--no-fine")) {
            gain = 0;
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
    return .{ .run = .{
        .command = command,
        .dev = dev,
        .gain = gain,
        .save_dir = save_dir,
    } };
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

/// Largest magnitude a logical coordinate or size may have. Far beyond any real
/// desktop, and small enough that scaling it to physical pixels and rounding it
/// into an `i32`/`u32` can never overflow (which would be undefined behaviour
/// in a release build, not an error).
const max_coordinate: f64 = 1_000_000;

/// Exactly `N` comma-separated finite floats within `max_coordinate`, no more,
/// no less.
fn parseFloats(comptime N: usize, value: []const u8) ?[N]f64 {
    var result: [N]f64 = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&result) |*slot| {
        const number = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
        if (!std.math.isFinite(number) or @abs(number) > max_coordinate) return null;
        slot.* = number;
    }
    if (parts.next() != null) return null;
    return result;
}

pub fn printVersion() void {
    out.print("hgsm {s}\n", .{version});
}

pub fn printUsage() void {
    // Two prints on purpose: one line comes out of a fixed 1024 byte buffer, and
    // the whole list no longer fits in one of them.
    out.print(
        \\usage: hgsm [option]
        \\
        \\  (no option)          overlay: hover to inspect, click for hex, drag for a screenshot
        \\  --pick X,Y           print and copy the hex of a pixel, in logical coordinates
        \\  --shot X,Y,W,H       copy a logical rectangle as a PNG screenshot
        \\  --save-dir DIR       also write each screenshot into DIR as a PNG, named
        \\                       hgsm-YYYYMMDD-HHMMSS-mmm.png, alongside the clipboard copy
        \\  --gain N             overlay cursor speed, in logical pixels per raw pointer
        \\                       delta (default 0.5). 1 matches the compositor's own
        \\                       cursor, lower is finer, and 0 is --no-fine
        \\  --no-fine            drive the overlay cursor from the compositor's cursor
        \\                       positions, like a compositor without relative-pointer
        \\  --info               print the displays, their scales and the fine pointer
        \\                       protocols on offer
        \\  --version            print the version
        \\  --help, -h           print this
        \\
    , .{});
    out.print(
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
