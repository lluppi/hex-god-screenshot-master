//! Stdout/stderr without dragging in the Io interface: these are one-line
//! prints from a short lived tool.

const std = @import("std");
const sys = @import("sys.zig");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch {
        std.debug.print("hgsm: output truncated\n", .{});
        return;
    };
    sys.writeAll(1, text);
}

pub fn fail(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch {
        std.debug.print("hgsm: output truncated\n", .{});
        return;
    };
    sys.writeAll(2, text);
}
