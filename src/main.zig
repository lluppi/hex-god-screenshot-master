const builtin = @import("builtin");
const std = @import("std");

pub fn main(minimal: std.process.Init.Minimal) !void {
    switch (builtin.os.tag) {
        .linux => try @import("linux/app.zig").run(minimal),
        .macos => try @import("macos/app.zig").run(minimal),
        .windows => try @import("windows/app.zig").run(minimal),
        else => @compileError("hgsm supports linux (wayland), macos and windows only"),
    }
}
