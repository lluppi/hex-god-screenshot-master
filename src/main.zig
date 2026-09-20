const builtin = @import("builtin");
const std = @import("std");
const out = @import("core/out.zig");

pub fn main(minimal: std.process.Init.Minimal) !void {
    switch (builtin.os.tag) {
        .linux => try @import("linux/app.zig").run(minimal),
        .macos => try @import("macos/app.zig").run(minimal),
        else => {
            out.fail("hgsm: unsupported platform {s}\n", .{@tagName(builtin.os.tag)});
            std.process.exit(2);
        },
    }
}
