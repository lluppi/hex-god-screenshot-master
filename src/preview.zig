//! Dev harness: renders the overlay + loupe for a synthetic screen into a PNG
//! so the shared renderer can be eyeballed without booting a compositor.
//!
//! zig build preview   ->  zig-out/preview.png
//!
//! Not part of the shipped binary; kept because the macOS frontend cannot be
//! run on Linux and this is the only way to see what it will draw.

const std = @import("std");
const canvas_mod = @import("core/canvas.zig");
const color = @import("core/color.zig");
const geom = @import("core/geom.zig");
const magnifier = @import("core/magnifier.zig");
const overlay = @import("core/overlay.zig");
const png = @import("core/png.zig");
const sampling = @import("core/sampling.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Optional `--scale N`: render at a display scale other than 1 so fractional
    // scale behaviour (the loupe metrics, the ring, the glyph filtering) can be
    // inspected without a compositor that scales.
    var ui_scale: f64 = 1;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scale")) {
            const value = args.next() orelse return error.MissingScale;
            ui_scale = std.fmt.parseFloat(f64, value) catch return error.BadScale;
        }
    }

    const width: u32 = 900;
    const height: u32 = 620;
    var baseline = try canvas_mod.Canvas.init(allocator, width, height);
    defer baseline.deinit();

    // Synthetic desktop: gradient plus a few solid blocks, so the loupe has
    // real pixel structure to magnify.
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            baseline.set(
                @intCast(x),
                @intCast(y),
                color.solid(.{
                    .r = @intCast((x * 255) / width),
                    .g = @intCast((y * 255) / height),
                    .b = @intCast(255 - ((x + y) % 256)),
                }),
            );
        }
    }
    baseline.fillRect(.{ .x = 120, .y = 90, .w = 160, .h = 90 }, color.solid(.{ .r = 0x1d, .g = 0x4e, .b = 0xd8 }));
    baseline.fillRect(.{ .x = 420, .y = 200, .w = 120, .h = 120 }, color.solid(.{ .r = 0x16, .g = 0xa3, .b = 0x4a }));
    baseline.fillRect(.{ .x = 620, .y = 420, .w = 200, .h = 60 }, color.solid(.{ .r = 0xf5, .g = 0x9e, .b = 0x0b }));

    var frame = try canvas_mod.Canvas.init(allocator, width, height);
    defer frame.deinit();

    const selection = geom.Rect{ .x = 300, .y = 240, .w = 260, .h = 180 };
    const cursor = geom.Point{ .x = 560, .y = 420 };

    overlay.renderRegion(&frame, .{
        .baseline = &baseline,
        .selection = selection,
        .cursor = cursor,
        .ui_scale = ui_scale,
    }, frame.rect());

    var sample = try canvas_mod.Canvas.init(allocator, magnifier.sample_side, magnifier.sample_side);
    defer sample.deinit();
    sampling.fillSample(&sample, &baseline, 1, cursor);
    overlay.renderMagnifier(&frame, magnifier.windowOrigin(cursor, ui_scale), sample, ui_scale);

    const bytes = try png.encode(allocator, frame);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "zig-out/preview.png", .data = bytes });
    std.debug.print("wrote zig-out/preview.png ({d} bytes)\n", .{bytes.len});
}
