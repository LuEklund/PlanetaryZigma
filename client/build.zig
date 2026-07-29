const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    if (b.release_mode == .any) std.log.warn("--release is forced to ReleaseSafe: bugs crash with a trace instead of silent corruption/UB (pass -Doptimize=... to override)", .{});

    const tracy_enable = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;
    const ztracy_dep = b.dependency("ztracy", .{ .target = target, .optimize = optimize, .tracy = tracy_enable });
    const ztracy = ztracy_dep.module("ztracy");

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("shared");
    const yes = b.dependency("yes", .{ .target = target, .optimize = optimize, .x_backend = .xlib }).module("yes");

    const steam_dep = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize });
    const steam_module = steam_dep.module("steamworks");

    const zgltf = b.dependency("zgltf", .{ .target = target, .optimize = optimize }).module("zgltf");

    const stb_dep = b.dependency("stb", .{});
    const stb_image = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_image.addIncludePath(b.dependency("stb", .{}).path("."));

    const stb_truetype = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_truetype.addIncludePath(b.dependency("stb", .{}).path("."));

    const miniaudio_dep = b.dependency("miniaudio", .{});
    const miniaudio_translate_c = b.addTranslateC(.{
        .root_source_file = miniaudio_dep.path("miniaudio.h"),
        .optimize = optimize,
        .target = target,
    });
    const miniaudio = miniaudio_translate_c.createModule();
    miniaudio.addCSourceFile(.{ .file = miniaudio_dep.path("miniaudio.c") });

    const system = b.addLibrary(.{
        .name = "system_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/System.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "yes", .module = yes },
                .{ .name = "zgltf", .module = zgltf },
                .{ .name = "stb_image", .module = stb_image.createModule() },
                .{ .name = "stb_truetype", .module = stb_truetype.createModule() },
                .{ .name = "ztracy", .module = ztracy },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
        .linkage = .dynamic,
    });

    system.root_module.addCSourceFile(.{
        .file = b.addWriteFiles().add("stbi_impl.c",
            \\#define STB_IMAGE_IMPLEMENTATION
            \\#include "stb_image.h"
            \\#define STB_TRUETYPE_IMPLEMENTATION
            \\#include "stb_truetype.h"
        ),
    });
    system.root_module.addIncludePath(stb_dep.path("."));

    const exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "system", .module = system.root_module },
                .{ .name = "yes", .module = yes },
                .{ .name = "steamworks", .module = steam_module },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "miniaudio", .module = miniaudio },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    const vulkandeps = b.dependency("vulkan_headers", .{});
    const vmadep = b.dependency("vma", .{});

    const vulkan_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("vma_vulkan.h",
            \\#include <vulkan/vulkan.h>
            \\#include <vk_mem_alloc.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    vulkan_c.addIncludePath(vulkandeps.path("include/"));
    vulkan_c.addIncludePath(vmadep.path("include/"));

    const vulkan = vulkan_c.createModule();
    vulkan.link_libcpp = true;
    for (vulkan_c.include_dirs.items) |include_dir| vulkan.addIncludePath(include_dir.path);

    vulkan.addCSourceFile(.{
        .file = b.addWriteFiles().add("vma_impl.cpp",
            \\#define VMA_STATIC_VULKAN_FUNCTIONS 1
            \\#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0
            \\#define VMA_IMPLEMENTATION
            \\#include <vk_mem_alloc.h>
        ),
        .flags = &.{"-std=c++17"},
    });

    compileShaders(b);

    system.root_module.addImport("vulkan", vulkan);

    if (target.result.os.tag == .windows) {
        if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
            const lib_dir = b.pathJoin(&.{ sdk, "Lib" });
            system.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
            exe.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
        } else {
            std.log.warn("VULKAN_SDK not set; vulkan-1 may not be found at link time", .{});
        }
        system.root_module.linkSystemLibrary("vulkan-1", .{});
        exe.root_module.linkSystemLibrary("vulkan-1", .{});
    } else {
        system.root_module.linkSystemLibrary("vulkan", .{});
        exe.root_module.linkSystemLibrary("vulkan", .{});
        system.link_z_defs = true;
    }
    exe.root_module.link_libcpp = true;

    b.installArtifact(system);
    b.installArtifact(exe);

    // Shared Tracy client dll must sit next to the binaries that link it.
    if (tracy_enable) b.installArtifact(ztracy_dep.artifact("tracy"));

    if (target.result.os.tag == .windows) {
        const install_steam_dll = b.addInstallBinFile(steam_dep.path("steamworks/redistributable_bin/win64/steam_api64.dll"), "steam_api64.dll");
        b.getInstallStep().dependOn(&install_steam_dll.step);
    }

    const run_step = b.step("run", "Run the client");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_step = b.step("lib", "Build only the hot-reload library (.so)");
    lib_step.dependOn(&b.addInstallArtifact(system, .{}).step);
}

fn compileShaders(b: *std.Build) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "assets/shaders", .{ .iterate = true }) catch @panic("assets/shaders not found");
    defer dir.close(io);
    const usf = b.addUpdateSourceFiles();
    var walker = dir.walk(b.allocator) catch @panic("walk assets/shaders");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walk assets/shaders")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.basename, ".spv")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".slang")) {
            const cmd = b.addSystemCommand(&.{"slangc"});
            cmd.addFileArg(b.path(b.fmt("assets/shaders/{s}", .{entry.path})));
            cmd.addArgs(&.{ "-target", "spirv" });
            cmd.addArg("-o");
            const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{entry.basename[0 .. entry.basename.len - ".slang".len]}));
            usf.addCopyFileToSource(spv, b.fmt("assets/shaders/{s}.spv", .{entry.path[0 .. entry.path.len - ".slang".len]}));
            continue;
        }
        const cmd = b.addSystemCommand(&.{"glslc"});
        cmd.addFileArg(b.path(b.fmt("assets/shaders/{s}", .{entry.path})));
        cmd.addArg("-o");
        const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{entry.basename}));
        usf.addCopyFileToSource(spv, b.fmt("assets/shaders/{s}.spv", .{entry.path}));
    }
    b.getInstallStep().dependOn(&usf.step);
}
