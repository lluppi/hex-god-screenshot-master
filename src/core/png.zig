//! Minimal PNG encoder. Screenshots go onto the clipboard as PNG, so we need a
//! real encoder; `std.compress.flate` supplies the zlib stream and we write the
//! four chunks a PNG reader actually requires.
//!
//! Truecolour without alpha: screens are opaque (see color.zig), and dropping
//! the channel is a quarter less data in every scanline.

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
    ihdr[9] = 2; // colour type: truecolour
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(allocator, &out, "IHDR", &ihdr);
    try writeChunk(allocator, &out, "IDAT", compressed);
    try writeChunk(allocator, &out, "IEND", &.{});

    return out.toOwnedSlice(allocator);
}

/// RGB8 scanlines with filter byte 0.
fn scanlines(allocator: std.mem.Allocator, canvas: Canvas) ![]u8 {
    const stride = @as(usize, canvas.width) * 3 + 1;
    const raw = try allocator.alloc(u8, stride * canvas.height);
    var row: usize = 0;
    while (row < canvas.height) : (row += 1) {
        const base = row * stride;
        raw[base] = 0;
        var column: usize = 0;
        while (column < canvas.width) : (column += 1) {
            const rgb = color.rgbOf(canvas.pixels[row * canvas.width + column]);
            const offset = base + 1 + column * 3;
            raw[offset] = rgb.r;
            raw[offset + 1] = rgb.g;
            raw[offset + 2] = rgb.b;
        }
    }
    return raw;
}

/// `flate.Compress` rebases inside its output writer, so the writer's buffer has
/// to be stable; a growing writer is not an option here. The slack covers
/// deflate's worst case (stored blocks add ~5 bytes per 64 KiB) with room to
/// spare, and the realloc below trims the excess.
const deflate_slack = 4096;

fn deflate(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const capacity = raw.len + raw.len / 64 + deflate_slack;
    const output = try allocator.alloc(u8, capacity);
    errdefer allocator.free(output);

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
