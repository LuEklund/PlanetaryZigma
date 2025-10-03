const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_glfw = b.dependency("zig_glfw", .{
        .target = target,
        .optimize = optimize,
    }).module("zig_glfw");

    const zig_opengl = b.dependency("zig_opengl", .{
        .target = target,
        .optimize = optimize,
    }).module("zig_opengl");

    const numz = b.dependency("numz", .{
        .target = target,
        .optimize = optimize,
    }).module("numz");

    const stb = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add(
            "c.h",
            \\#define STBI_ONLY_PNG
            \\#define STB_IMAGE_IMPLEMENTATION
            \\#include "stb_image.h"
            ,
        ),
        .target = target,
        .optimize = optimize,
    });
    stb.addIncludePath(b.dependency("stb", .{}).path("."));

    const exe = b.addExecutable(.{
        .name = "PlanetaryZigma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glfw", .module = zig_glfw },
                .{ .name = "gl", .module = zig_opengl },
                .{ .name = "numz", .module = numz },
                .{ .name = "stb", .module = stb.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const render_lib = b.addLibrary(.{
        .name = "render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glfw", .module = zig_glfw },
                .{ .name = "gl", .module = zig_opengl },
                .{ .name = "numz", .module = numz },
                .{ .name = "stb", .module = stb.createModule() },
            },
        }),
        .linkage = .dynamic,
    });

    b.installArtifact(render_lib);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
