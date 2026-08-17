const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const contract = @import("renderer_contract");
const Particle = @import("graphics").Particle;

const particle_effect: contract.ParticleEffect = .item_effect;
const surface_point: nz.Vec3(f32) = .{ 0, 20, 0 };
const ribbon_target: nz.Vec3(f32) = .{ 3, 20, 3 };
const camera_position: nz.Vec3(f32) = .{ 0, 21, 8 };

pub fn populate(world: *World) !void {
    try world.planet.sync(world.gpa, 0);
    world.camera = .{ .transform = .{ .position = camera_position } };
}

pub fn update(particles: *Particle, elapsed_time: f32) void {
    const params: contract.EffectParams = contract.effect_params.get(particle_effect);
    if (params.lifetime == 0) {
        particles.keepAlive(particle_effect, 0, surface_point, elapsed_time);
        return;
    }
    for (particles.emitters) |emitter| {
        if (emitter.effect == particle_effect and emitter.alive(elapsed_time)) return;
    }
    particles.spawn(.{
        .effect = particle_effect,
        .origin = surface_point,
        .target = if (params.placement == @intFromEnum(contract.Placement.line)) ribbon_target else surface_point,
    }, elapsed_time);
}
