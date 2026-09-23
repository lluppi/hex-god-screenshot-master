//! The libc calls the frontends need outside of what `std` still exposes
//! without dragging in the Io interface: writing to a file descriptor (stdout,
//! or the clipboard pipe the compositor hands us), closing one, truncating one,
//! and the clocks.

const std = @import("std");
const builtin = @import("builtin");

const TimeSpec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn clock_gettime(clock_id: c_int, result: *TimeSpec) c_int;

/// CLOCK_MONOTONIC, which libc numbers differently per platform.
const clock_monotonic: c_int = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd => 6,
    else => 1,
};

/// CLOCK_REALTIME, which is 0 on every platform we build for.
const clock_realtime: c_int = 0;

pub fn writeAll(fd: c_int, bytes: []const u8) void {
    if (builtin.os.tag == .windows) return windows.writeAll(fd, bytes);
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = write(fd, remaining.ptr, remaining.len);
        // Best effort: the callers are a one-line print and a clipboard pipe,
        // and neither has anything useful to do about a short write.
        if (written <= 0) return;
        remaining = remaining[@intCast(written)..];
    }
}

/// Stdout and stderr on windows go straight to the standard handles. A
/// windows-subsystem process started from a shortcut, explorer or a hotkey has
/// no standard handles, and the CRT treats a write to an unbound descriptor as
/// an invalid parameter and kills the process on the spot - after a screenshot
/// was saved but before it was copied, or before a picked colour was copied at
/// all. With no handle there is nowhere to print, so the line is dropped.
const windows = struct {
    const HANDLE = *anyopaque;
    const std_output_handle: u32 = 0xFFFF_FFF5;
    const std_error_handle: u32 = 0xFFFF_FFF4;
    const invalid_handle_value: usize = std.math.maxInt(usize);

    extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn WriteFile(
        file: HANDLE,
        buffer: [*]const u8,
        count: u32,
        written: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;

    fn writeAll(fd: c_int, bytes: []const u8) void {
        const which = switch (fd) {
            1 => std_output_handle,
            2 => std_error_handle,
            else => return,
        };
        const handle = GetStdHandle(which) orelse return;
        if (@intFromPtr(handle) == invalid_handle_value) return;
        var remaining = bytes;
        while (remaining.len > 0) {
            var written: u32 = 0;
            const count: u32 = @intCast(@min(remaining.len, std.math.maxInt(u32)));
            if (WriteFile(handle, remaining.ptr, count, &written, null) == 0 or written == 0) return;
            remaining = remaining[written..];
        }
    }
};

pub fn closeFd(fd: c_int) void {
    _ = close(fd);
}

pub fn truncateFd(fd: c_int, length: u64) !void {
    if (ftruncate(fd, @intCast(length)) != 0) return error.TruncateFailed;
}

/// Milliseconds from an arbitrary fixed point; only differences are meaningful.
pub fn monotonicMs() i64 {
    return readMs(clock_monotonic);
}

/// Milliseconds since the unix epoch, for stamping a saved screenshot. Zero if
/// the clock is unavailable, which the caller treats as 1970.
pub fn realMs() i64 {
    return readMs(clock_realtime);
}

fn readMs(clock_id: c_int) i64 {
    var now: TimeSpec = undefined;
    if (clock_gettime(clock_id, &now) != 0) return 0;
    return @as(i64, now.tv_sec) * std.time.ms_per_s + @divTrunc(@as(i64, now.tv_nsec), std.time.ns_per_ms);
}
