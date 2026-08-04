const std = @import("std");
const render_build = @import("render");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    if (b.release_mode == .any) std.log.warn("--release is forced to ReleaseSafe: bugs crash with a trace instead of silent corruption/UB (pass -Doptimize=... to override)", .{});

    const tracy_enable = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;
    const ztracy_dep = b.dependency("ztracy", .{ .target = target, .optimize = optimize, .tracy = tracy_enable });
    const ztracy = ztracy_dep.module("ztracy");

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("shared");

    const render_dep = b.dependency("render", .{ .target = target, .optimize = optimize, .tracy = tracy_enable });
    const render = render_dep.module("render");
    const window = render_dep.module("Window");

    const steam_dep = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize });
    const steam_module = steam_dep.module("steamworks");

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
                .{ .name = "render", .module = render },
                .{ .name = "Window", .module = window },
                .{ .name = "ztracy", .module = ztracy },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
        .linkage = .dynamic,
    });

    const exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "system", .module = system.root_module },
                .{ .name = "render", .module = render },
                .{ .name = "Window", .module = window },
                .{ .name = "steamworks", .module = steam_module },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "miniaudio", .module = miniaudio },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    compileShaders(b);

    render_build.linkVulkan(b, system, target);
    render_build.linkVulkan(b, exe, target);
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
        if (!std.mem.endsWith(u8, entry.basename, ".slang")) continue;
        const cmd = b.addSystemCommand(&.{"slangc"});
        cmd.addFileArg(b.path(b.fmt("assets/shaders/{s}", .{entry.path})));
        cmd.addArgs(&.{ "-target", "spirv" });
        cmd.addArg("-o");
        const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{entry.basename[0 .. entry.basename.len - ".slang".len]}));
        usf.addCopyFileToSource(spv, b.fmt("assets/shaders/{s}.spv", .{entry.path[0 .. entry.path.len - ".slang".len]}));
    }
    b.getInstallStep().dependOn(&usf.step);
}
