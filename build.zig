const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os_tag = target.result.os.tag;

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "hex-god-screenshot-master",
        .root_module = module,
    });

    switch (os_tag) {
        .linux => {
            // Vendored protocol bindings, generated with wayland-scanner from
            // protocol/xml (see protocol/README.md). Committed so that a build
            // needs nothing but libwayland-client and libxkbcommon.
            module.addIncludePath(b.path("protocol/generated"));
            module.addCSourceFiles(.{
                .files = &.{
                    "protocol/generated/xdg-shell.c",
                    "protocol/generated/xdg-output-unstable-v1.c",
                    "protocol/generated/viewporter.c",
                    "protocol/generated/wlr-layer-shell-unstable-v1.c",
                    "protocol/generated/wlr-screencopy-unstable-v1.c",
                },
                .flags = &.{ "-std=gnu11", "-Wno-unused-parameter" },
            });
            module.linkSystemLibrary("wayland-client", .{});
            module.linkSystemLibrary("xkbcommon", .{});
        },
        .macos => {
            module.linkFramework("AppKit", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("CoreGraphics", .{});
            module.linkSystemLibrary("objc", .{});
        },
        else => {
            std.debug.print(
                "hex-god-screenshot-master supports linux (wayland) and macos; target is {s}\n",
                .{@tagName(os_tag)},
            );
            @panic("unsupported target");
        },
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "build and run");
    run_step.dependOn(&run_cmd.step);

    // Renderer preview: no compositor required, writes zig-out/preview.png.
    const preview_module = b.createModule(.{
        .root_source_file = b.path("src/preview.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const preview = b.addExecutable(.{
        .name = "hex-god-preview",
        .root_module = preview_module,
    });
    const preview_cmd = b.addRunArtifact(preview);
    if (b.args) |args| preview_cmd.addArgs(args);
    const preview_step = b.step("preview", "render the overlay to zig-out/preview.png");
    preview_step.dependOn(&preview_cmd.step);
}
