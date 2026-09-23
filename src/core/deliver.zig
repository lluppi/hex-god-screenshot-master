//! What happens to a result once it has been decided, by the overlay gesture or
//! by `--pick`/`--shot`: capture, encode, save, copy, and the messages around
//! them. Shared so every frontend reports the same things in the same order and
//! only announces a clipboard copy that actually happened. A frontend supplies
//! the clipboard write and nothing else.
//!
//! Each function returns the exit code the outcome deserves: 0, or 1 when any
//! part of it failed.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const color = @import("color.zig");
const geom = @import("geom.zig");
const interaction = @import("interaction.zig");
const out = @import("out.zig");
const png = @import("png.zig");
const save = @import("save.zig");

const Canvas = canvas_mod.Canvas;

/// Print a picked colour's hex and put it on the clipboard.
pub fn colour(
    rgb: color.Rgb,
    ctx: anytype,
    comptime copyText: fn (@TypeOf(ctx), []const u8) anyerror!void,
) u8 {
    const hex = color.hexString(rgb);
    out.print("{s}\n", .{hex});
    copyText(ctx, &hex) catch |err| {
        out.fail("could not copy to the clipboard: {t}\n", .{err});
        return 1;
    };
    return 0;
}

/// Crop a global logical rectangle out of the baselines, encode it, write it
/// into `save_dir` when there is one, and put it on the clipboard. A failed
/// save is reported but does not stop the copy. `copyImage` receives both the
/// pixels and the encoded PNG, so it can publish whichever formats it wants.
pub fn screenshot(
    allocator: std.mem.Allocator,
    surfaces: []const interaction.Surface,
    rect: geom.FRect,
    save_dir: ?[]const u8,
    ctx: anytype,
    comptime copyImage: fn (@TypeOf(ctx), Canvas, []const u8) anyerror!void,
) u8 {
    var canvas = interaction.captureScreenshot(allocator, surfaces, rect) catch |err| {
        out.fail("screenshot failed: {t}\n", .{err});
        return 1;
    };
    defer canvas.deinit();
    const bytes = png.encode(allocator, canvas) catch |err| {
        out.fail("png encoding failed: {t}\n", .{err});
        return 1;
    };
    defer allocator.free(bytes);

    var code: u8 = 0;
    if (save_dir) |dir| {
        if (save.writePng(allocator, dir, bytes)) |path| {
            defer allocator.free(path);
            out.print("Screenshot saved to {s}\n", .{path});
        } else |err| {
            out.fail("could not save screenshot to {s}: {t}\n", .{ dir, err });
            code = 1;
        }
    }

    if (copyImage(ctx, canvas, bytes)) {
        out.print("Screenshot copied to clipboard\n", .{});
    } else |err| {
        out.fail("could not copy the screenshot to the clipboard: {t}\n", .{err});
        code = 1;
    }
    return code;
}
