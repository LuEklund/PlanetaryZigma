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
    const contract = render_dep.module("contract");
        const render_system = render_dep.module("render_system");
    const assets_watcher = b.dependency("Assets", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("Assets");
    const window = render_dep.module("Window");
    const ui = render_dep.module("ui");

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
                .{ .name = "contract", .module = contract },
                
                .{ .name = "render_system", .module = render_system },
                .{ .name = "Assets", .module = assets_watcher },
                .{ .name = "Window", .module = window },
                .{ .name = "ui", .module = ui },
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
                
                .{ .name = "Window", .module = window },
                .{ .name = "ui", .module = ui },
                .{ .name = "steamworks", .module = steam_module },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "miniaudio", .module = miniaudio },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    const shaders = compileShaders(b);

    render_build.linkVulkan(b, system, target);
    render_build.linkVulkan(b, exe, target);
    exe.root_module.link_libcpp = true;

    // One install step, reused: two of them write the same path, so a single rebuild
    // landed twice and the running client hot-reloaded twice per build.
    const install_system = b.addInstallArtifact(system, .{});
    b.getInstallStep().dependOn(&install_system.step);
    b.installArtifact(exe);
    const install_render = b.addInstallArtifact(render_dep.artifact("render"), .{});
    b.getInstallStep().dependOn(&install_render.step);

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
    lib_step.dependOn(&install_system.step);

    const render_step = b.step("render", "Build only the hot-reload renderer (.so) and shaders");
    render_step.dependOn(&install_render.step);
    render_step.dependOn(shaders);

    const shader_step = b.step("shaders", "Compile shaders only");
    shader_step.dependOn(shaders);
}

fn compileShaders(b: *std.Build) *std.Build.Step {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "../Assets/shaders", .{ .iterate = true }) catch @panic("../Assets/shaders not found");
    defer dir.close(io);
    const usf = b.addUpdateSourceFiles();
    var walker = dir.walk(b.allocator) catch @panic("walk ../Assets/shaders");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walk ../Assets/shaders")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".slang")) continue;
        if (std.mem.eql(u8, entry.basename, "scene.slang")) continue;
        const cmd = b.addSystemCommand(&.{"slangc"});
        cmd.addFileArg(b.path(b.fmt("../Assets/shaders/{s}", .{entry.path})));
        cmd.addArgs(&.{ "-target", "spirv" });
        cmd.addPrefixedDirectoryArg("-I", b.path("../Assets/shaders"));
        cmd.addArg("-o");
        const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{entry.basename[0 .. entry.basename.len - ".slang".len]}));
        usf.addCopyFileToSource(spv, b.fmt("../Assets/shaders/{s}.spv", .{entry.path[0 .. entry.path.len - ".slang".len]}));
    }
    b.getInstallStep().dependOn(&usf.step);
    return &usf.step;
}
