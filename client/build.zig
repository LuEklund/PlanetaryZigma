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
    const graphics = render_dep.module("graphics");
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

                .{ .name = "miniaudio", .module = miniaudio },
                .{ .name = "graphics", .module = graphics },
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
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    const shaders = compileShaders(b);
    exportModels(b);

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
    var dir = b.build_root.handle.openDir(io, "../assets/shaders", .{ .iterate = true }) catch @panic("../assets/shaders not found");
    defer dir.close(io);
    const usf = b.addUpdateSourceFiles();
    var walker = dir.walk(b.allocator) catch @panic("walk ../assets/shaders");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walk ../assets/shaders")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".slang")) continue;
        if (std.mem.eql(u8, entry.basename, "scene.slang")) continue;
        const cmd = b.addSystemCommand(&.{"slangc"});
        cmd.addFileArg(b.path(b.fmt("../assets/shaders/{s}", .{entry.path})));
        cmd.addArgs(&.{ "-target", "spirv" });
        cmd.addPrefixedDirectoryArg("-I", b.path("../assets/shaders"));
        cmd.addArg("-o");
        const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{entry.basename[0 .. entry.basename.len - ".slang".len]}));
        usf.addCopyFileToSource(spv, b.fmt("../assets/shaders/{s}.spv", .{entry.path[0 .. entry.path.len - ".slang".len]}));
    }
    b.getInstallStep().dependOn(&usf.step);
    return &usf.step;
}

fn exportModels(b: *std.Build) void {
    const io = b.graph.io;

    const home = b.graph.environ_map.get("HOME") orelse "";
    const candidates = [_][]const u8{
        "blender",
        b.pathJoin(&.{ home, ".steam", "steam", "steamapps", "common", "Blender", "blender" }),
    };
    var dir = b.build_root.handle.openDir(io, "../assets/objects/", .{ .iterate = true }) catch @panic("../assets/objects not found");
    defer dir.close(io);
    var it = dir.iterate();
    var candidate_index: usize = 0;
    while (it.next(io) catch @panic("iterate objects")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".blend")) continue;
        const glb_name = b.fmt("{s}.glb", .{entry.name[0 .. entry.name.len - ".blend".len]});
        const blend_stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (dir.statFile(io, glb_name, .{})) |glb_stat| {
            if (glb_stat.mtime.nanoseconds >= blend_stat.mtime.nanoseconds) continue;
        } else |_| {}

        var exported = false;
        while (candidate_index < candidates.len) {
            const result = std.process.run(b.allocator, io, .{
                .argv = &.{ candidates[candidate_index], "--background", "--factory-startup", "--python-exit-code", "1", entry.name, "--python", "export_glb.py", "--", glb_name },
                .cwd = .{ .dir = dir },
                .environ_map = &b.graph.environ_map,
            }) catch {
                candidate_index += 1;
                continue;
            };
            if (result.term == .exited and result.term.exited == 0) {
                exported = true;
                break;
            }
            candidate_index += 1;
        }
        if (!exported) {
            std.log.warn("models NOT auto-compiled — see {s} in build.zig", .{@src().fn_name});
            return;
        }
    }
}
