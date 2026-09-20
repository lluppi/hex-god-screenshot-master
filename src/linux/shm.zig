//! `wl_shm` buffers: anonymous memory the compositor can read pixels from.
//!
//! Every drawing surface gets two of these so a frame can be composed while the
//! compositor still reads the previous one. A buffer only becomes writable
//! again after `wl_buffer.release`, which is why `released` is tracked here.

const std = @import("std");
const wl = @import("wl.zig");
const sys = @import("../core/sys.zig");
const canvas_mod = @import("../core/canvas.zig");

const Canvas = canvas_mod.Canvas;

pub const ShmBuffer = struct {
    /// Stable address: it is the listener data for wl_buffer events.
    buffer: ?*wl.Obj = null,
    pool: ?*wl.Obj = null,
    fd: std.posix.fd_t = -1,
    memory: ?[]align(std.heap.page_size_min) u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    /// Set when the compositor says it is done with this buffer. Informational:
    /// frame pacing is done with `wl_surface.frame` (see linux/app.zig), because
    /// a compositor may hold the buffer it is displaying indefinitely.
    released: bool = true,

    /// A drawing view over the mapped memory. Only valid when `stride` is
    /// exactly `width * 4`, which is what `create` guarantees for our own
    /// buffers; capture buffers are read row by row instead. This canvas does
    /// not own the pixels, so it must never be passed to `Canvas.deinit`.
    pub fn canvas(self: *ShmBuffer) Canvas {
        const bytes = self.memory.?[0 .. @as(usize, self.stride) * self.height];
        const pixels: []u32 = @alignCast(std.mem.bytesAsSlice(u32, bytes));
        return .{
            .width = self.width,
            .height = self.height,
            .pixels = pixels,
            .allocator = undefined,
        };
    }

    /// Create a buffer and observe its release events. Must not be called on a
    /// copy: the listener data is this struct's own address.
    pub fn create(
        self: *ShmBuffer,
        shm: *wl.Obj,
        shm_version: u32,
        width: u32,
        height: u32,
        format: u32,
        stride: u32,
    ) !void {
        try self.init(shm, shm_version, width, height, format, stride);
        wl.addListener(self.buffer.?, &buffer_listener, @ptrCast(self));
    }

    /// Create a buffer whose release state is not observed. Capture buffers use
    /// this because they are returned by value and destroyed immediately.
    pub fn createUntracked(
        self: *ShmBuffer,
        shm: *wl.Obj,
        shm_version: u32,
        width: u32,
        height: u32,
        format: u32,
        stride: u32,
    ) !void {
        try self.init(shm, shm_version, width, height, format, stride);
    }

    fn init(
        self: *ShmBuffer,
        shm: *wl.Obj,
        shm_version: u32,
        width: u32,
        height: u32,
        format: u32,
        stride: u32,
    ) !void {
        const size = @as(u64, stride) * height;
        if (size == 0 or size > std.math.maxInt(i32)) return error.TooLarge;

        const fd = try std.posix.memfd_create("hgsm", std.posix.MFD.CLOEXEC);
        errdefer sys.closeFd(fd);
        try sys.truncateFd(fd, size);

        const memory = try std.posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(memory);

        const pool = wl.shmCreatePool(shm, shm_version, fd, @intCast(size)) orelse
            return error.CreatePoolFailed;
        const buffer = wl.shmPoolCreateBuffer(
            pool,
            shm_version,
            @intCast(0),
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            format,
        ) orelse return error.CreateBufferFailed;

        self.* = .{
            .buffer = buffer,
            .pool = pool,
            .fd = fd,
            .memory = memory,
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
            .released = true,
        };
    }

    /// A drawing view over the mapped memory, only valid when the stride is
    /// tightly packed.
    pub fn destroy(self: *ShmBuffer) void {
        if (self.buffer) |buffer| wl.bufferDestroy(buffer);
        if (self.pool) |pool| wl.shmPoolDestroy(pool);
        if (self.memory) |memory| std.posix.munmap(memory);
        if (self.fd >= 0) sys.closeFd(self.fd);
        self.* = .{};
    }
};

const BufferListener = extern struct {
    release: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
};

var buffer_listener = BufferListener{ .release = onRelease };

fn onRelease(data: ?*anyopaque, buffer: ?*wl.Obj) callconv(.c) void {
    _ = buffer;
    const self: *ShmBuffer = @ptrCast(@alignCast(data.?));
    self.released = true;
}
