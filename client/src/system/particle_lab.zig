const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Shader = @import("renderer_contract").Shader;
const Particle = @import("graphics").Particle;

const particle_kind: Shader.Kind = .item_effect;
const surface_point: nz.Vec3(f32) = .{ 0, 20, 0 };
const ribbon_target: nz.Vec3(f32) = .{ 3, 20, 3 };
const camera_position: nz.Vec3(f32) = .{ 0, 21, 8 };

pub fn populate(world: *World) !void {
    try world.planet.sync(world.gpa, 0);
    world.camera = .{ .transform = .{ .position = camera_position } };
}

pub fn update(particles: *Particle, elapsed_time: f32) void {
    const particle_info = Shader.particleInfo(particle_kind);
    if (particle_info.duration == null) {
        particles.keepAlive(particle_kind, 0, surface_point, elapsed_time);
        return;
    }
    for (particles.emitters) |emitter| {
        if (emitter.effect == particle_kind and emitter.alive(elapsed_time)) return;
    }
    particles.spawn(.{
        .effect = particle_kind,
        .origin = surface_point,
        .target = if (particle_info.topology == .ribbon) ribbon_target else surface_point,
    }, elapsed_time);
}
