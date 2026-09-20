//! Stdout/stderr without dragging in the Io interface: these are one-line
//! prints from a short lived tool.

const std = @import("std");
const sys = @import("sys.zig");

/// One line, max 1024 bytes before it is reported as truncated.
const buffer_bytes = 1024;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    emit(1, fmt, args);
}

pub fn fail(comptime fmt: []const u8, args: anytype) void {
    emit(2, fmt, args);
}

fn emit(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buffer: [buffer_bytes]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch {
        std.debug.print("hgsm: output truncated\n", .{});
        return;
    };
    sys.writeAll(fd, text);
}
