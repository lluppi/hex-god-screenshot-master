const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // This is an interactive full-screen overlay, so ordinary `zig build` has to
    // produce the responsive binary used by the compositor keybind; a debug
    // build of this thing is unusably laggy. Do not swap this for
    // `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })`:
    // that returns Debug unless the caller also passes `-Drelease`. Developers
    // can still request a debug build explicitly with `-Doptimize=Debug`.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseFast;

    const exe = addExe(b, "hgsm", "src/main.zig", target, optimize, true);
    linkPlatform(b, exe.root_module, target.result.os.tag);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "build and run");
    run_step.dependOn(&run_cmd.step);

    // Renderer preview: no compositor required, writes zig-out/preview.png.
    const preview = addExe(b, "hex-god-preview", "src/preview.zig", target, optimize, false);
    const preview_cmd = b.addRunArtifact(preview);
    if (b.args) |args| preview_cmd.addArgs(args);
    const preview_step = b.step("preview", "render the overlay to zig-out/preview.png");
    preview_step.dependOn(&preview_cmd.step);
}

fn addExe(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_libc: bool,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
        }),
    });
}

/// Link what the platform's frontend needs.
fn linkPlatform(b: *std.Build, module: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
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
                    "protocol/generated/pointer-constraints-unstable-v1.c",
                    "protocol/generated/relative-pointer-unstable-v1.c",
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
        else => std.debug.panic(
            "hgsm supports linux (wayland) and macos; target is {s}",
            .{@tagName(os_tag)},
        ),
    }
}
