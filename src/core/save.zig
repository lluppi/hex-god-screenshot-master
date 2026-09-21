//! Writing a screenshot out to a directory, for `--save-dir`.
//!
//! Only used when the flag is present: without it a screenshot lives on the
//! clipboard and nowhere else. The clipboard copy is left alone either way, so a
//! saved shot is still pasteable.

const std = @import("std");
const sys = @import("sys.zig");

/// Write `bytes` as a PNG inside `dir` and return the path that was written.
/// The caller owns the returned path and must free it with `allocator`.
///
/// The name is `hgsm-YYYYMMDD-HHMMSS-mmm.png` in UTC, so a directory listing
/// sorts by capture order. An existing name is never overwritten: the file is
/// opened `O_EXCL` and a `-1`, `-2`, ... suffix is tried instead, which matters
/// because the millisecond stamp can repeat across a fast double click.
pub fn writePng(
    allocator: std.mem.Allocator,
    dir: []const u8,
    bytes: []const u8,
) ![]u8 {
    var stamp_buffer: [32]u8 = undefined;
    const stamp = try utcStamp(&stamp_buffer, sys.realMs());

    var suffix: u32 = 0;
    while (suffix <= max_suffix) : (suffix += 1) {
        var name_buffer: [64]u8 = undefined;
        const name = if (suffix == 0)
            try std.fmt.bufPrint(&name_buffer, "hgsm-{s}.png", .{stamp})
        else
            try std.fmt.bufPrint(&name_buffer, "hgsm-{s}-{d}.png", .{ stamp, suffix });

        // Null terminated so the same slice can be handed to `unlinkat` if the
        // write fails part way through.
        const path = try std.fs.path.joinZ(allocator, &.{ dir, name });

        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(std.posix.mode_t, 0o644)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => |other| {
                allocator.free(path);
                return other;
            },
        };

        writeAll(fd, bytes) catch |err| {
            sys.closeFd(fd);
            // Do not leave a truncated PNG behind for the user to trip over.
            _ = std.c.unlinkat(std.posix.AT.FDCWD, path.ptr, 0);
            allocator.free(path);
            return err;
        };
        sys.closeFd(fd);
        return path;
    }
    return error.NameCollision;
}

/// The suffix budget: a millisecond stamp repeated this many times is no longer
/// a timestamp, it is a bug.
const max_suffix: u32 = 1000;

/// Every byte, or an error. Unlike `sys.writeAll`, a short write to a file is
/// worth reporting: it means the PNG on disk is not the one we captured.
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return error.WriteFailed;
        remaining = remaining[@intCast(written)..];
    }
}

/// `YYYYMMDD-HHMMSS-mmm`, UTC, no trailing separator. `ms` may be zero, which is
/// what `sys.realMs` reports when the clock is unavailable; that lands in 1970
/// rather than failing the save.
fn utcStamp(buffer: []u8, ms: i64) ![]const u8 {
    const seconds: u64 = @intCast(@divTrunc(ms, std.time.ms_per_s));
    const millis: u64 = @intCast(@mod(ms, std.time.ms_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d:0>3}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            millis,
        },
    );
}
