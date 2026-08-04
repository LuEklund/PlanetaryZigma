const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Shader = @import("render").Shader;
const Rendering = @import("render").Rendering;
const Emitter = @import("render").Emitter;

const particle_kind: Shader.Kind = .item_effect;
const surface_point: nz.Vec3(f32) = .{ 0, 20, 0 };
const ribbon_target: nz.Vec3(f32) = .{ 3, 20, 3 };
const camera_position: nz.Vec3(f32) = .{ 0, 21, 8 };
const camera_fov_rad: f32 = 1.25;

pub fn populate(world: *World) void {
    world.camera = .{ .transform = .{ .position = camera_position }, .fov_rad = camera_fov_rad };
}

pub fn update(world: *World, rendering: *Rendering) void {
    const particle_info = Shader.particleInfo(particle_kind);
    if (particle_info.duration == null) {
        rendering.keepAliveEffect(particle_kind, .none, surface_point, world.elapsed_time);
        return;
    }
    for (&rendering.emitters) |emitter| {
        if (emitter.effect == particle_kind and emitter.alive(world.elapsed_time)) return;
    }
    rendering.spawnEffect(.{
        .effect = particle_kind,
        .origin = surface_point,
        .target = if (particle_info.topology == .ribbon) ribbon_target else surface_point,
    }, world.elapsed_time);
}
