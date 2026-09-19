//! Minimal PNG encoder. Screenshots go onto the clipboard as PNG, so we need a
//! real encoder; `std.compress.flate` supplies the zlib stream and we write the
//! four chunks a PNG reader actually requires.

const std = @import("std");
const flate = std.compress.flate;
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");

const Canvas = canvas_mod.Canvas;

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub fn encode(allocator: std.mem.Allocator, canvas: Canvas) ![]u8 {
    const raw = try scanlines(allocator, canvas);
    defer allocator.free(raw);

    const compressed = try deflate(allocator, raw);
    defer allocator.free(compressed);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], canvas.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], canvas.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: truecolour with alpha
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(allocator, &out, "IHDR", &ihdr);
    try writeChunk(allocator, &out, "IDAT", compressed);
    try writeChunk(allocator, &out, "IEND", &.{});

    return out.toOwnedSlice(allocator);
}

/// RGBA8 scanlines with filter byte 0, un-premultiplied.
fn scanlines(allocator: std.mem.Allocator, canvas: Canvas) ![]u8 {
    const stride = @as(usize, canvas.width) * 4 + 1;
    const raw = try allocator.alloc(u8, stride * canvas.height);
    var row: usize = 0;
    while (row < canvas.height) : (row += 1) {
        const base = row * stride;
        raw[base] = 0;
        var column: usize = 0;
        while (column < canvas.width) : (column += 1) {
            const pixel = canvas.pixels[row * canvas.width + column];
            const alpha: u8 = @intCast((pixel >> 24) & 0xff);
            const rgb = color.rgbOf(pixel);
            var r = rgb.r;
            var g = rgb.g;
            var b = rgb.b;
            if (alpha != 0 and alpha != 255) {
                r = @intCast(@min(255, (@as(u32, r) * 255) / alpha));
                g = @intCast(@min(255, (@as(u32, g) * 255) / alpha));
                b = @intCast(@min(255, (@as(u32, b) * 255) / alpha));
            }
            const offset = base + 1 + column * 4;
            raw[offset] = r;
            raw[offset + 1] = g;
            raw[offset + 2] = b;
            raw[offset + 3] = alpha;
        }
    }
    return raw;
}

fn deflate(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, raw.len + raw.len / 64 + 4096);
    var writer: std.Io.Writer = .fixed(output);
    var window: [flate.max_window_len * 2]u8 = undefined;
    var compressor = try flate.Compress.init(&writer, &window, .zlib, .default);
    try compressor.writer.writeAll(raw);
    try compressor.finish();
    const written = writer.buffered().len;
    return allocator.realloc(output, written);
}

fn writeChunk(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: *const [4]u8,
    payload: []const u8,
) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len), .big);
    try out.appendSlice(allocator, &length);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, payload);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(payload);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try out.appendSlice(allocator, &checksum);
}