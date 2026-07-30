const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Shader = @import("../Renderer/Vulkan/Shader.zig");
const Emitter = @import("Emitter.zig");

const surface_point: nz.Vec3(f32) = .{ 0, 20, 0 };
const ribbon_target: nz.Vec3(f32) = .{ 3, 20, 3 };
const camera_position: nz.Vec3(f32) = .{ 0, 21, 8 };
const camera_fov_rad: f32 = 1.25;

pub fn populate(world: *World) void {
    world.camera = .{ .transform = .{ .position = camera_position }, .fov_rad = camera_fov_rad };
}

pub fn update(world: *World) void {
    const particle_info = Shader.particleInfo(.explosion);
    if (particle_info.duration == null) {
        Emitter.keepAlive(world, .explosion, .none, surface_point);
        return;
    }
    for (&world.emitters) |emitter| {
        if (emitter.effect == .explosion and emitter.alive(world.elapsed_time)) return;
    }
    switch (particle_info.topology) {
        .quad => Emitter.spawnQuad(world, .explosion, surface_point),
        .ribbon => Emitter.spawnRibbon(world, .explosion, surface_point, ribbon_target),
    }
}
