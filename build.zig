const std = @import("std");

// Consumer build for zig-diablo: link the static raylib artifact built from C
// source by raylib-zig (Zig's bundled clang compiles it — no MSVC, no runtime
// raylib.dll), and import the raylib + raygui Zig binding modules.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // Zig bindings
    const raygui = raylib_dep.module("raygui"); // GUI bindings (may be unused)
    const raylib_artifact = raylib_dep.artifact("raylib"); // static C library

    const exe = b.addExecutable(.{
        .name = "zig-diablo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);
    b.installArtifact(exe);

    // `zig build run` — launch the game (exe installed to zig-out/bin first).
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run zig-diablo");
    run_step.dependOn(&run_cmd.step);
}
