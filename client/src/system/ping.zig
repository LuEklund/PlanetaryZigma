const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Vec3 = nz.Vec3(f32);

const max_distance: f32 = 300;
const entity_cone: f32 = 0.995;

/// What the crosshair points at: the visible entity closest to screen center, else the terrain hit.
pub fn aim(world: *World) shared.net.PingRequest {
    const origin = world.camera.transform.position;
    const forward = world.camera.transform.rotation.rotateVec(.{ 0, 0, -1 });
    var best_target: shared.entity.Id = .none;
    var best_alignment: f32 = entity_cone;
    var best_position: Vec3 = undefined;
    for (world.entities.values()) |*entity| {
        if (entity.id == world.player_id or entity.kind == .unknown) continue;
        if (entity.kind.projectileKind() != null) continue;
        const to_entity = entity.transform.position - origin;
        const distance = nz.vec.length(to_entity);
        if (distance < 0.5 or distance > max_distance) continue;
        const alignment = nz.vec.dot(nz.vec.scale(to_entity, 1 / distance), forward);
        if (alignment <= best_alignment) continue;
        const to_direction = nz.vec.scale(to_entity, 1 / distance);
        if (terrainDistance(&world.planet, origin, to_direction) < distance - 1) continue;
        best_alignment = alignment;
        best_target = entity.id;
        best_position = entity.transform.position;
    }
    if (best_target != .none) return .{ .position = best_position, .target = best_target };
    return .{
        .position = origin + nz.vec.scale(forward, terrainDistance(&world.planet, origin, forward)),
        .target = .none,
    };
}

fn terrainDistance(planet: *const shared.Planet, origin: Vec3, direction: Vec3) f32 {
    if (planet.planet_radius == 0) return 20;
    var distance: f32 = 0;
    for (0..128) |_| {
        const clearance = planet.sdf(origin + nz.vec.scale(direction, distance));
        if (clearance <= 0.05) return distance;
        distance += clearance;
        if (distance >= max_distance) return max_distance;
    }
    return distance;
}
