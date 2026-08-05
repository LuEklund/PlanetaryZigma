const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Shader = @import("render").Shader;
const Renderer = @import("render").Renderer;
const Emitter = @import("render").Emitter;

const particle_kind: Shader.Kind = .item_effect;
const surface_point: nz.Vec3(f32) = .{ 0, 20, 0 };
const ribbon_target: nz.Vec3(f32) = .{ 3, 20, 3 };
const camera_position: nz.Vec3(f32) = .{ 0, 21, 8 };

pub fn populate(world: *World) !void {
    try world.planet.sync(world.gpa, 0);
    world.camera = .{ .transform = .{ .position = camera_position } };
}

pub fn update(renderer: *Renderer, elapsed_time: f32) void {
    const particle_info = Shader.particleInfo(particle_kind);
    if (particle_info.duration == null) {
        renderer.keepAliveEffect(particle_kind, .none, surface_point, elapsed_time);
        return;
    }
    for (&renderer.emitters) |emitter| {
        if (emitter.effect == particle_kind and emitter.alive(elapsed_time)) return;
    }
    renderer.spawnEffect(.{
        .effect = particle_kind,
        .origin = surface_point,
        .target = if (particle_info.topology == .ribbon) ribbon_target else surface_point,
    }, elapsed_time);
}
