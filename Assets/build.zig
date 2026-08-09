const std = @import("std");

// Its own package because none of it is rendering: it watches the game's asset files,
// parses them with `assets`, and pushes the result through whatever renderer is loaded.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy_enable = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("shared");
    const numz = b.dependency("numz", .{ .target = target, .optimize = optimize }).module("numz");
    const zgltf = b.dependency("zgltf", .{ .target = target, .optimize = optimize }).module("zgltf");
    const ztracy = b.dependency("ztracy", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("ztracy");

    const stb_dep = b.dependency("stb", .{});
    const stb_truetype = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_truetype.addIncludePath(stb_dep.path("."));

    const stb_image = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_image.addIncludePath(stb_dep.path("."));

    const module = b.addModule("Assets", .{
        .root_source_file = b.path("Watcher.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared", .module = shared },
            .{ .name = "numz", .module = numz },
            .{ .name = "zgltf", .module = zgltf },
            .{ .name = "ztracy", .module = ztracy },
            .{ .name = "stb_image", .module = stb_image.createModule() },
            .{ .name = "stb_truetype", .module = stb_truetype.createModule() },
        },
        .link_libc = true,
    });
    module.addIncludePath(stb_dep.path("."));
    module.addCSourceFile(.{
        .file = b.addWriteFiles().add("stbi_impl.c",
            \\#define STB_IMAGE_IMPLEMENTATION
            \\#include "stb_image.h"
            \\#define STB_TRUETYPE_IMPLEMENTATION
            \\#include "stb_truetype.h"
        ),
        .flags = &.{"-fvisibility=hidden"},
    });
}
