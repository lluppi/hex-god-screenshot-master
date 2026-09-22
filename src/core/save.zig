//! Writing a screenshot out to a directory, for `--save-dir`.
//!
//! Only used when the flag is present: without it a screenshot lives on the
//! clipboard and nowhere else. The clipboard copy is left alone either way, so a
//! saved shot is still pasteable.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const win32 = if (builtin.os.tag == .windows) @import("../windows/win32.zig") else struct {};

/// An open file created exclusively, holding no bytes yet.
const Destination = if (builtin.os.tag == .windows) struct {
    handle: win32.HANDLE,
    /// The path as UTF-16, kept so the file can be deleted if the write fails
    /// part way through. Windows deletes by name, not by descriptor.
    wide: [:0]u16,
} else struct {
    descriptor: std.posix.fd_t,
};

/// Create `path`, failing with `error.PathAlreadyExists` when it is taken.
/// `O_EXCL` on the unix side, `CREATE_NEW` on the windows one.
fn createExclusive(allocator: std.mem.Allocator, path: [:0]const u8) !Destination {
    if (builtin.os.tag == .windows) {
        // WTF-8: a windows command line can carry unpaired surrogates, and the
        // directory came from one.
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        errdefer allocator.free(wide);
        const handle = win32.CreateFileW(
            wide.ptr,
            win32.generic_write,
            win32.file_share_read,
            null,
            win32.create_new,
            win32.file_attribute_normal,
            null,
        ) orelse switch (win32.GetLastError()) {
            win32.error_file_exists, win32.error_already_exists => return error.PathAlreadyExists,
            win32.error_access_denied => return error.AccessDenied,
            win32.error_path_not_found, win32.error_file_not_found => return error.FileNotFound,
            else => return error.CreateFailed,
        };
        return .{ .handle = handle, .wide = wide };
    }

    return .{
        .descriptor = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(std.posix.mode_t, 0o644)),
    };
}

fn closeDestination(allocator: std.mem.Allocator, destination: Destination) void {
    if (builtin.os.tag == .windows) {
        _ = win32.CloseHandle(destination.handle);
        allocator.free(destination.wide);
    } else {
        sys.closeFd(destination.descriptor);
    }
}

/// Write every byte, or an error. Unlike `sys.writeAll`, a short write to a file
/// is worth reporting: it means the PNG on disk is not the one we captured.
fn writeAll(destination: Destination, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        if (builtin.os.tag == .windows) {
            var written: u32 = 0;
            if (win32.WriteFile(destination.handle, remaining.ptr, @intCast(remaining.len), &written, null) == 0) {
                return error.WriteFailed;
            }
            if (written == 0) return error.WriteFailed;
            remaining = remaining[written..];
        } else {
            const written = std.c.write(destination.descriptor, remaining.ptr, remaining.len);
            if (written <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(written)..];
        }
    }
}

/// Close the file and delete it, so a failed write leaves nothing behind.
fn abandon(allocator: std.mem.Allocator, destination: Destination) void {
    if (builtin.os.tag == .windows) {
        _ = win32.CloseHandle(destination.handle);
        _ = win32.DeleteFileW(destination.wide.ptr);
        allocator.free(destination.wide);
    } else {
        sys.closeFd(destination.descriptor);
    }
}

/// Write `bytes` as a PNG inside `dir` and return the path that was written.
/// The caller owns the returned path and must free it with `allocator`.
///
/// The name is `hgsm-YYYYMMDD-HHMMSS-mmm.png` in UTC, so a directory listing
/// sorts by capture order. An existing name is never overwritten: the file is
/// opened exclusively and a `-1`, `-2`, ... suffix is tried instead, which
/// matters because the millisecond stamp can repeat across a fast double click.
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

        // Null terminated so the same slice can name the file to delete when the
        // write fails part way through.
        const path = try std.fs.path.joinZ(allocator, &.{ dir, name });

        const destination = createExclusive(allocator, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => |other| {
                allocator.free(path);
                return other;
            },
        };

        writeAll(destination, bytes) catch |err| {
            // Do not leave a truncated PNG behind for the user to trip over.
            abandon(allocator, destination);
            allocator.free(path);
            return err;
        };
        closeDestination(allocator, destination);
        return path;
    }
    return error.NameCollision;
}


/// The suffix budget: a millisecond stamp repeated this many times is no longer
/// a timestamp, it is a bug.
const max_suffix: u32 = 1000;

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
