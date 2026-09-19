//! The three libc calls the frontends need outside of what `std.posix` still
//! exposes: writing to a file descriptor (stdout, or the clipboard pipe the
//! compositor hands us), closing one, and sleeping.

const std = @import("std");
const builtin = @import("builtin");

const TimeSpec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
extern "c" fn nanosleep(request: *const TimeSpec, remaining: ?*TimeSpec) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn clock_gettime(clock_id: c_int, result: *TimeSpec) c_int;

/// CLOCK_MONOTONIC, which libc numbers differently per platform.
const clock_monotonic: c_int = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd => 6,
    else => 1,
};

pub fn writeAll(fd: c_int, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return;
        remaining = remaining[@intCast(written)..];
    }
}

pub fn closeFd(fd: c_int) void {
    _ = close(fd);
}

pub fn sleepMs(milliseconds: u64) void {
    const request = TimeSpec{
        .tv_sec = @intCast(milliseconds / 1000),
        .tv_nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&request, null);
}

pub fn truncateFd(fd: c_int, length: u64) !void {
    if (ftruncate(fd, @intCast(length)) != 0) return error.TruncateFailed;
}

/// Milliseconds from an arbitrary fixed point; only differences are meaningful.
pub fn monotonicMs() i64 {
    var now: TimeSpec = undefined;
    if (clock_gettime(clock_monotonic, &now) != 0) return 0;
    return @as(i64, now.tv_sec) * std.time.ms_per_s + @divTrunc(@as(i64, now.tv_nsec), std.time.ns_per_ms);
}
