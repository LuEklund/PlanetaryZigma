const std = @import("std");

pub fn build(b: *std.Build) void {
    // const target = b.standardTargetOptions(.{});
    //TODO: remove once Zig 0.16.0 works properly with GCC 16.1.1
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 39, .patch = 0 },
        },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    if (b.release_mode == .any) std.log.warn("--release is forced to ReleaseSafe: bugs crash with a trace instead of silent corruption/UB (pass -Doptimize=... to override)", .{});
    const tracy_enable = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;
    const ztracy_dep = b.dependency("ztracy", .{ .target = target, .optimize = optimize, .tracy = tracy_enable });
    const ztracy = ztracy_dep.module("ztracy");

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("shared");
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
            .root_source_file = b.path("src/system.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "box3d", .module = box3d_mod },
            },
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });

    system.root_module.linkLibrary(box3d_lib);

    b.installArtifact(system);

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
            },
        }),
    });
    if (target.result.os.tag == .linux) {
        exe.root_module.addRPath(steam_dep.path("steamworks/public/steam/lib/linux64"));
        exe.root_module.addRPath(steam_dep.path("steamworks/redistributable_bin/linux64"));
    }

    b.installArtifact(exe);
    if (target.result.os.tag == .windows) {
        const install_steam_dll = b.addInstallBinFile(steam_dep.path("steamworks/redistributable_bin/win64/steam_api64.dll"), "steam_api64.dll");
        const install_ticket_dll = b.addInstallBinFile(steam_dep.path("steamworks/public/steam/lib/win64/sdkencryptedappticket64.dll"), "sdkencryptedappticket64.dll");
        b.getInstallStep().dependOn(&install_steam_dll.step);
        b.getInstallStep().dependOn(&install_ticket_dll.step);
    }
    if (tracy_enable) b.installArtifact(ztracy_dep.artifact("tracy"));

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
