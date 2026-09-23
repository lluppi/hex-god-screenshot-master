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
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = write(fd, remaining.ptr, remaining.len);
        // Best effort: the callers are a one-line print and a clipboard pipe,
        // and neither has anything useful to do about a short write.
        if (written <= 0) return;
        remaining = remaining[@intCast(written)..];
    }
}

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
