const std = @import("std");

// Standalone build for the Box3D spike. Compiles the vendored Box3D at
// ../vendor/box3d (shared with the server, not duplicated) and links the spike.
// Run: `zig build run` from this directory.
pub fn build(b: *std.Build) void {
    // Same pinned target as the server build — native default hits an
    // R_X86_64_PC64 linker error with the host GCC 16.1.1 / newer glibc.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 39, .patch = 0 },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const box3d = "../vendor/box3d";

    const box3d_lib = b.addLibrary(.{
        .name = "box3d",
        .linkage = .static,
        // sanitize_c=.off matches the server build; the real alignment fix is the
        // source patch in block_allocator.c, so this passes even with UBSan on.
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .sanitize_c = .off }),
    });
    box3d_lib.root_module.addIncludePath(b.path(box3d ++ "/include"));
    box3d_lib.root_module.addIncludePath(b.path(box3d ++ "/src"));
    box3d_lib.root_module.addCSourceFiles(.{
        .root = b.path(box3d ++ "/src"),
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
        .root_source_file = b.path(box3d ++ "/include/box3d/box3d.h"),
        .target = target,
        .optimize = optimize,
    });
    box3d_tc.addIncludePath(b.path(box3d ++ "/include"));

    const exe = b.addExecutable(.{
        .name = "box3d_spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "box3d", .module = box3d_tc.createModule() }},
        }),
    });
    exe.root_module.linkLibrary(box3d_lib);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the Box3D spike").dependOn(&run.step);
}
