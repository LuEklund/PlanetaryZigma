const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize }).module("shared");

    const glfw_headers = b.dependency("glfw_headers", .{});
    const glfw_translate_c = b.addTranslateC(.{
        .root_source_file = glfw_headers.path("include/GLFW/glfw3.h"),
        // b.addWriteFiles().add("c.h",
        // \\#define GLFW_INCLUDE_NONE
        // \\#include <GLFW/glfw3.h>
        // ),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "glfw", .module = glfw_translate_c.createModule() },
            },
        }),
    });

    exe.root_module.linkLibrary(b.dependency("glfw", .{ .target = target, .optimize = optimize }).artifact("glfw3"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the client");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
