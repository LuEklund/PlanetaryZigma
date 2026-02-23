const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize }).module("shared");

    // const zphysics = b.dependency("zphysics", .{
    //     .use_double_precision = false,
    //     .enable_cross_platform_determinism = true,
    // });

    //NOTE: hot reloading.
    const system = b.addLibrary(.{
        .name = "system",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/System.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                // .{ .name = "zphy", .module = zphysics.module("root") },
            },
        }),
        .linkage = .dynamic,
    });
    b.installArtifact(system);
    // system.root_module.linkLibrary(zphysics.artifact("joltc"));

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "System", .module = system.root_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
