const std = @import("std");

const ServerArtifacts = struct {
    exe: *std.Build.Step.Compile,
    system: *std.Build.Step.Compile,
    steam_dep: *std.Build.Dependency,
    ztracy_dep: *std.Build.Dependency,
    render_dep: ?*std.Build.Dependency,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    if (b.release_mode == .any) std.log.warn("--release is forced to ReleaseSafe: bugs crash with a trace instead of silent corruption/UB (pass -Doptimize=... to override)", .{});
    const tracy_enable = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;
    // Off by default: a dedicated server compiles no render package, no windowing and
    // no Vulkan, and rejects --render at startup.
    const render_enable = b.option(bool, "render", "Build the server with its own render window") orelse false;

    const artifacts = addServerArtifacts(b, target, optimize, tracy_enable, render_enable);
    installServerArtifacts(b, b.getInstallStep(), artifacts, target, tracy_enable);

    const windows_step = b.step("windows", "Build Windows server artifacts used by the hosted client");
    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows });
    const windows_artifacts = addServerArtifacts(b, windows_target, optimize, tracy_enable, false);
    installServerArtifacts(b, windows_step, windows_artifacts, windows_target, tracy_enable);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(artifacts.exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}

fn addServerArtifacts(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracy_enable: bool,
    render_enable: bool,
) ServerArtifacts {
    const build_options = b.addOptions();
    build_options.addOption(bool, "render", render_enable);
    const build_options_module = build_options.createModule();
    const ztracy_dep = b.dependency("ztracy", .{ .target = target, .optimize = optimize, .tracy = tracy_enable });
    const ztracy = ztracy_dep.module("ztracy");

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("shared");
    const render_dep: ?*std.Build.Dependency = if (render_enable)
        b.dependency("render", .{ .target = target, .optimize = optimize, .tracy = tracy_enable })
    else
        null;
    const steam_dep = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize });
    const steam_module = steam_dep.module("steamworks");

    const box3d_lib = b.addLibrary(.{
        .name = "box3d",
        .linkage = .static,
        // Box3D's block allocator stores 8-byte pointers into elements that are only
        // 4-byte aligned (fine on x86_64, UB per C standard). Zig's C UBSan aborts on
        // it; box3d's own CMake never runs UBSan. sanitize_c=.off is the real switch —
        // the -fno-sanitize cflag does NOT disable Zig's instrumentation.
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .sanitize_c = .off }),
    });
    box3d_lib.root_module.addIncludePath(b.path("vendor/box3d/include"));
    box3d_lib.root_module.addIncludePath(b.path("vendor/box3d/src"));
    box3d_lib.root_module.addCSourceFiles(.{
        .root = b.path("vendor/box3d/src"),
        .flags = &.{"-std=gnu17"},
        .files = &.{
            "aabb.c",              "arena_allocator.c", "bitset.c",          "block_allocator.c",
            "body.c",              "broad_phase.c",     "capsule.c",         "compound.c",
            "constraint_graph.c",  "contact.c",         "contact_solver.c",  "convex_manifold.c",
            "core.c",              "distance.c",        "distance_joint.c",  "dynamic_tree.c",
            "height_field.c",      "hull.c",            "id_pool.c",         "island.c",
            "joint.c",             "manifold.c",        "math_functions.c",  "mesh.c",
            "mesh_contact.c",      "motor_joint.c",     "mover.c",           "parallel_for.c",
            "parallel_joint.c",    "physics_world.c",   "prismatic_joint.c", "recording.c",
            "recording_replay.c",  "revolute_joint.c",  "scheduler.c",       "sensor.c",
            "shape.c",             "simd.c",            "solver.c",          "solver_set.c",
            "sphere.c",            "spherical_joint.c", "table.c",           "timer.c",
            "triangle_manifold.c", "types.c",           "weld_joint.c",      "wheel_joint.c",
            "world_snapshot.c",
        },
    });
    const box3d_tc = b.addTranslateC(.{
        .root_source_file = b.path("vendor/box3d/include/box3d/box3d.h"),
        .target = target,
        .optimize = optimize,
    });
    box3d_tc.addIncludePath(b.path("vendor/box3d/include"));
    const box3d_mod = box3d_tc.createModule();

    const system = b.addLibrary(.{
        .name = "system_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/System.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "box3d", .module = box3d_mod },
                .{ .name = "build_options", .module = build_options_module },
            },
            .link_libc = true,
        }),
        .linkage = .dynamic,
        .use_lld = true,
        .use_llvm = true,
    });

    if (render_dep) |dep| {
        system.root_module.addImport("render", dep.module("render"));
        system.root_module.addImport("Window", dep.module("Window"));
    }

    system.root_module.linkLibrary(box3d_lib);
    if (target.result.os.tag != .windows) system.link_z_defs = true;

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "system", .module = system.root_module },
                .{ .name = "steamworks", .module = steam_module },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    if (render_dep) |dep| exe.root_module.addImport("Window", dep.module("Window"));

    if (target.result.os.tag != .windows) {
        exe.root_module.addRPath(steam_dep.path("steamworks/public/steam/lib/linux64"));
        exe.root_module.addRPath(steam_dep.path("steamworks/redistributable_bin/linux64"));
    }

    return .{
        .exe = exe,
        .system = system,
        .steam_dep = steam_dep,
        .ztracy_dep = ztracy_dep,
        .render_dep = render_dep,
    };
}

fn installServerArtifacts(
    b: *std.Build,
    step: *std.Build.Step,
    artifacts: ServerArtifacts,
    target: std.Build.ResolvedTarget,
    tracy_enable: bool,
) void {
    step.dependOn(&b.addInstallArtifact(artifacts.system, .{}).step);
    step.dependOn(&b.addInstallArtifact(artifacts.exe, .{}).step);
    if (artifacts.render_dep) |dep| {
        step.dependOn(&b.addInstallArtifact(dep.artifact("render"), .{}).step);
    }
    if (tracy_enable) {
        step.dependOn(&b.addInstallArtifact(artifacts.ztracy_dep.artifact("tracy"), .{}).step);
    }

    if (target.result.os.tag == .windows) {
        step.dependOn(&b.addInstallBinFile(
            artifacts.steam_dep.path("steamworks/redistributable_bin/win64/steam_api64.dll"),
            "steam_api64.dll",
        ).step);
        step.dependOn(&b.addInstallBinFile(
            artifacts.steam_dep.path("steamworks/public/steam/lib/win64/sdkencryptedappticket64.dll"),
            "sdkencryptedappticket64.dll",
        ).step);
    }
}
