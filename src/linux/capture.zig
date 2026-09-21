//! Screen capture through `zwlr_screencopy_manager_v1`.
//!
//! One full-output grab per display at startup provides the baseline everything
//! is composed, sampled, and finally cropped from. The live loupe and completed
//! screenshots therefore show exactly the desktop seen when the program began.
//!
//! The protocol wants regions in *output logical* coordinates; the buffers that
//! come back are in physical pixels.

const std = @import("std");
const wl = @import("wl.zig");
const shm = @import("shm.zig");
const geom = @import("../core/geom.zig");
const canvas_mod = @import("../core/canvas.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geom.Rect;
const FRect = geom.FRect;

pub const Error = error{
    CaptureFailed,
    OutOfMemory,
    UnsupportedFormat,
    Timeout,
    Disconnected,
};

const FrameReader = struct {
    shm: *wl.Obj,
    shm_version: u32,
    buffer: shm.ShmBuffer = .{},
    state: enum { pending, ready, failed } = .pending,
};

const FrameListener = extern struct {
    buffer: *const fn (?*anyopaque, ?*wl.Obj, u32, u32, u32, u32) callconv(.c) void,
    flags: *const fn (?*anyopaque, ?*wl.Obj, u32) callconv(.c) void,
    ready: *const fn (?*anyopaque, ?*wl.Obj, u32, u32, u32) callconv(.c) void,
    failed: *const fn (?*anyopaque, ?*wl.Obj) callconv(.c) void,
    damage: *const fn () callconv(.c) void,
    linux_dmabuf: *const fn () callconv(.c) void,
    buffer_done: *const fn () callconv(.c) void,
};

const frame_listener = FrameListener{
    .buffer = onBuffer,
    .flags = @ptrCast(&wl.noop),
    .ready = onReady,
    .failed = onFailed,
    .damage = @ptrCast(&wl.noop),
    .linux_dmabuf = @ptrCast(&wl.noop),
    .buffer_done = @ptrCast(&wl.noop),
};

fn reader(data: ?*anyopaque) *FrameReader {
    return @ptrCast(@alignCast(data.?));
}

fn onBuffer(
    data: ?*anyopaque,
    frame: ?*wl.Obj,
    format: u32,
    width: u32,
    height: u32,
    stride: u32,
) callconv(.c) void {
    const self = reader(data);
    self.buffer.createUntracked(self.shm, self.shm_version, width, height, format, stride) catch {
        self.state = .failed;
        return;
    };
    wl.screencopyFrameCopy(frame.?, self.buffer.buffer.?);
}

fn onReady(data: ?*anyopaque, frame: ?*wl.Obj, sec_hi: u32, sec_lo: u32, nsec: u32) callconv(.c) void {
    _ = frame;
    _ = sec_hi;
    _ = sec_lo;
    _ = nsec;
    reader(data).state = .ready;
}

fn onFailed(data: ?*anyopaque, frame: ?*wl.Obj) callconv(.c) void {
    _ = frame;
    reader(data).state = .failed;
}

/// Poll for a frame for this long before giving up: 400 tries of 250 ms.
const max_pump_attempts: usize = 400;
const pump_timeout_ms: i32 = 250;

/// Ask for one region of one output (or the whole output, when `region` is
/// null) and block until the pixels have landed. `region` is output-local
/// logical coordinates. The returned buffer is the caller's to destroy.
pub fn capture(
    display: *wl.Obj,
    manager: *wl.Obj,
    manager_version: u32,
    shm_obj: *wl.Obj,
    shm_version: u32,
    output: *wl.Obj,
    region: ?FRect,
) Error!shm.ShmBuffer {
    var context = FrameReader{ .shm = shm_obj, .shm_version = shm_version };
    errdefer context.buffer.destroy();
    const frame = if (region) |requested| blk: {
        const x: i32 = @intFromFloat(@floor(requested.x));
        const y: i32 = @intFromFloat(@floor(requested.y));
        const width: i32 = @max(1, @as(i32, @intFromFloat(@round(requested.w))));
        const height: i32 = @max(1, @as(i32, @intFromFloat(@round(requested.h))));
        break :blk wl.screencopyCaptureOutputRegion(
            manager,
            manager_version,
            0,
            output,
            x,
            y,
            width,
            height,
        );
    } else wl.screencopyCaptureOutput(manager, manager_version, 0, output);
    const requested_frame = frame orelse return Error.CaptureFailed;
    wl.addListener(requested_frame, &frame_listener, @ptrCast(&context));
    defer wl.screencopyFrameDestroy(requested_frame);

    var attempts: usize = 0;
    while (context.state == .pending) {
        attempts += 1;
        if (attempts > max_pump_attempts) return Error.Timeout;
        wl.pump(display, pump_timeout_ms) catch return Error.Disconnected;
    }
    if (context.state == .failed) return Error.CaptureFailed;
    return context.buffer;
}

/// Copy a captured shm buffer into a canvas, normalising the compositor's
/// pixel format and honouring a stride that is not tightly packed.
pub fn toCanvas(allocator: std.mem.Allocator, captured: *shm.ShmBuffer) Error!Canvas {
    var canvas = try Canvas.initUninitialized(allocator, captured.width, captured.height);
    errdefer canvas.deinit();

    const bytes = captured.memory.?;
    var y: u32 = 0;
    while (y < captured.height) : (y += 1) {
        const row_start = @as(usize, y) * captured.stride;
        const row = bytes[row_start .. row_start + @as(usize, captured.width) * 4];
        const source: []align(1) const u32 = @alignCast(std.mem.bytesAsSlice(u32, row));
        const dest_start = @as(usize, y) * captured.width;
        switch (captured.format) {
            wl.shm_format_argb8888 => {
                @memcpy(canvas.pixels[dest_start .. dest_start + captured.width], source);
            },
            wl.shm_format_xrgb8888 => {
                // The compositor leaves alpha undefined; the screen is opaque.
                for (source, 0..) |pixel, i| canvas.pixels[dest_start + i] = pixel | 0xff000000;
            },
            else => return Error.UnsupportedFormat,
        }
    }
    return canvas;
}
