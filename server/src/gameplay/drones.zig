//! RoR2-style ally drones: hover beside their owner, shoot the nearest monster in range.
const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const skills = @import("skills.zig");

const hover_height: f32 = 3;
const follow_slack: f32 = 2.5;
const side_offset: f32 = 2.5;

pub fn updateDrones(world: *World, physics: *system.Physics) !void {
    for (world.entities.values()) |*drone| {
        if (drone.kind != .drone or drone.flags.is_dead) continue;
        const owner = world.getPtr(drone.owner_id) orelse continue;
        follow(world, drone, owner);
        const primary = drone.kind.spec().skills.get(.primary) orelse continue;
        const target = nearestMonster(world, drone.transform.position, primary.range) orelse continue;
        if (!clearShot(physics, drone, target)) continue;
        if (skills.useAction(world, drone, target, .primary) == .fired) {
            try skills.executeSkill(world, physics, drone, target, primary);
        }
    }
}

fn follow(world: *World, drone: *World.Entity, owner: *World.Entity) void {
    const up = shared.Planet.surfaceUp(owner.transform.position);
    const side = nz.vec.normalize(shared.math.projectOnPlane(.{ 1, 0, 0 }, up));
    const lane: f32 = if (@intFromEnum(drone.id) % 2 == 0) 1 else -1;
    const anchor = owner.transform.position + nz.vec.scale(side, side_offset * lane);
    const to_anchor = shared.math.projectOnPlane(anchor - drone.transform.position, up);
    const distance = nz.vec.length(to_anchor);
    const direction: nz.Vec3(f32) = if (distance > follow_slack) nz.vec.scale(to_anchor, 1 / distance) else .{ 0, 0, 0 };
    const speed = drone.stat(.speed) * @max(1, distance / 10);
    world.act(.{ .id = drone.id, .verb = .{ .hover = .{ .direction = direction, .speed = speed, .height = hover_height } } });
}

/// Fire only with nothing between the drone and its target (pillars, teleporter, terrain).
fn clearShot(physics: *system.Physics, drone: *const World.Entity, target: *const World.Entity) bool {
    const start = drone.transform.position + nz.vec.scale(shared.Planet.surfaceUp(drone.transform.position), 0.8);
    const hit = World.rayCast(physics, start, target.transform.position - start) orelse return true;
    return hit.id == target.id or hit.id == drone.id;
}

fn nearestMonster(world: *World, position: nz.Vec3(f32), range: f32) ?*World.Entity {
    var best: ?*World.Entity = null;
    var best_distance = range;
    for (world.entities.values()) |*entity| {
        if (entity.kind != .enemy or entity.flags.is_dead) continue;
        const distance = nz.vec.distance(entity.transform.position, position);
        if (distance >= best_distance) continue;
        best_distance = distance;
        best = entity;
    }
    return best;
}
