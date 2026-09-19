//! Hex God Screenshot Master - one gesture, three outcomes.
//!
//!   hover -> live pixel loupe with the hex under the cursor
//!   click -> that pixel's hex goes to the clipboard
//!   drag  -> that rectangle goes to the clipboard as a PNG screenshot
//!   escape / right click -> bail out
//!
//! Built with zig, one shared core (src/core) and a thin platform frontend per
//! OS: Wayland (layer-shell + wlr-screencopy + wl_data_source) on Linux,
//! AppKit/CoreGraphics on macOS.

const builtin = @import("builtin");
const std = @import("std");
const out = @import("core/out.zig");

pub fn main(minimal: std.process.Init.Minimal) !void {
    switch (builtin.os.tag) {
        .linux => try @import("linux/app.zig").run(minimal),
        .macos => try @import("macos/app.zig").run(minimal),
        else => {
            out.fail("hex-god-screenshot-master: unsupported platform {s}\n", .{@tagName(builtin.os.tag)});
            std.process.exit(2);
        },
    }
}