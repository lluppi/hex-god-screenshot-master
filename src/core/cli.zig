//! Command line parsing, shared by both frontends so they accept exactly the
//! same flags.

const std = @import("std");
const geom = @import("geom.zig");
const out = @import("out.zig");

pub const Mode = enum { interactive, pick, shot, info };

pub const Options = struct {
    mode: Mode = .interactive,
    pick: ?geom.Point = null,
    shot: ?geom.FRect = null,
};

pub const Result = union(enum) {
    options: Options,
    help,
    invalid,
};

/// `args` excludes argv[0].
pub fn parse(args: []const []const u8) Result {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--pick")) {
            index += 1;
            if (index >= args.len) return invalid("--pick needs X,Y");
            options.pick = parsePoint(args[index]) orelse return invalid("--pick needs X,Y");
            options.mode = .pick;
        } else if (std.mem.eql(u8, arg, "--shot")) {
            index += 1;
            if (index >= args.len) return invalid("--shot needs X,Y,W,H");
            options.shot = parseRect(args[index]) orelse return invalid("--shot needs X,Y,W,H");
            options.mode = .shot;
        } else if (std.mem.eql(u8, arg, "--info")) {
            options.mode = .info;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else {
            return invalid("unknown argument");
        }
    }
    return .{ .options = options };
}

fn invalid(message: []const u8) Result {
    out.fail("{s}\n", .{message});
    return .invalid;
}

pub fn parsePoint(value: []const u8) ?geom.Point {
    var parts = std.mem.splitScalar(u8, value, ',');
    const x = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    const y = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    if (parts.next() != null) return null;
    return .{ .x = x, .y = y };
}

pub fn parseRect(value: []const u8) ?geom.FRect {
    var parts = std.mem.splitScalar(u8, value, ',');
    const x = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    const y = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    const w = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    const h = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    if (parts.next() != null) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn printUsage() void {
    out.print(
        \\usage: hex-god-screenshot-master [option]
        \\
        \\  (no option)          overlay: hover to inspect, click for hex, drag for a screenshot
        \\  --pick X,Y           print and copy the hex of a pixel, in logical coordinates
        \\  --shot X,Y,W,H       copy a logical rectangle as a PNG screenshot
        \\  --info               print the displays and their scales
        \\
        \\ Development: drive a synthetic gesture through the real handlers,
        \\ so the click and drag paths can be exercised from a script.
        \\  --dev-click X,Y      click at a logical point
        \\  --dev-drag X,Y,W,H   drag from X,Y to X+W,Y+H
        \\  --dev-via X,Y        pause at a mid point during the drag
        \\  --dev-hold MS        how long to hold each step (default 1000)
        \\
    , .{});
}
