const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const combat = @import("combat.zig");

const rocket_damage_multiplier: f32 = 1.5;
const lightning = .{
    .max_targets = shared.net.Event.Effect.Lightning.max_targets,
    .max_victims = 256,
};

pub fn updateProjectiles(world: *World) void {
    for (world.impacts.items) |impact| {
        const projectile = world.getPtr(impact.projectile) orelse continue;
        const projectile_kind = projectile.kind.projectileKind() orelse continue;
        switch (impact.what) {
            .terrain => {
                if (!projectile.flags.invincible) world.queueDespawn(projectile.id);
                const owner_entity = world.getPtrRaw(projectile.owner_id) orelse continue;
                switch (projectile_kind) {
                    .cube => {},
                    .rocket => {
                        damageRocketImpact(world, owner_entity, impact.point);
                        world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = impact.point } } });
                    },
                }
            },
            .entity => |hit_id| {
                const owner_entity = world.getPtrRaw(projectile.owner_id) orelse {
                    if (!projectile.flags.invincible) world.queueDespawn(projectile.id);
                    continue;
                };
                const hit_entity = world.getPtr(hit_id) orelse continue;
                if (owner_entity.kind.eql(hit_entity.kind)) continue;

                switch (projectile_kind) {
                    .cube => {
                        if (combat.removeHealth(world, hit_entity, projectile.damage, owner_entity) != .ignored) {
                            tryProcLightning(world, owner_entity, hit_entity.transform.position, hit_entity);
                        }
                    },
                    .rocket => {
                        damageRocketImpact(world, owner_entity, impact.point);
                        world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = impact.point } } });
                    },
                }
                if (!projectile.flags.invincible) world.queueDespawn(projectile.id);
            },
        }
    }
    world.impacts.clearRetainingCapacity();
}

fn tryProcLightning(world: *World, owner_entity: *const system.Entity, origin: nz.Vec3(f32), hit_entity: ?*const system.Entity) void {
    const lightning_count = owner_entity.inventory.get(.lightning);
    var lightning_jumps = lightning_count;
    const damage = owner_entity.stat(.damage) * lightning_count * 0.1;
    const lightning_chance = owner_entity.stat(.lightning_chance);
    if (!(owner_entity.kind == .player or lightning_jumps > 0 and world.prng.random().float(f32) < lightning_chance)) return;

    var visited: [lightning.max_victims]shared.entity.Id = undefined;
    var visited_count: usize = 0;
    if (hit_entity) |hit| {
        visited[0] = hit.id;
        visited_count = 1;
    }
    const Source = struct { position: nz.Vec3(f32) };
    var queue: [1 + lightning.max_victims]Source = undefined;
    queue[0] = .{ .position = origin };
    var queue_head: usize = 0;
    var queue_tail: usize = 1;

    while (queue_head < queue_tail) {
        const source = queue[queue_head];
        queue_head += 1;
        if (lightning_jumps == 0 or visited_count >= visited.len) continue;

        const Chained = struct { entity: *system.Entity, distance: f32 };
        var chained: [lightning.max_targets]Chained = undefined;
        var chained_count: usize = 0;
        const max_targets = @min(chained.len, visited.len - visited_count);
        for (world.entities.values()) |*candidate| {
            if (candidate.kind.eql(owner_entity.kind) or candidate.max_health <= 0) continue;
            if (std.mem.indexOfScalar(shared.entity.Id, visited[0..visited_count], candidate.id) != null) continue;
            const candidate_distance = nz.vec.distance(candidate.transform.position, source.position);
            if (candidate_distance > lightning_count + 5) continue;
            if (chained_count < max_targets) {
                chained_count += 1;
            } else if (candidate_distance >= chained[chained_count - 1].distance) {
                continue;
            }
            var index = chained_count - 1;
            while (index > 0 and chained[index - 1].distance > candidate_distance) : (index -= 1) {
                chained[index] = chained[index - 1];
            }
            chained[index] = .{ .entity = candidate, .distance = candidate_distance };
        }
        if (chained_count == 0) continue;

        var targets: [lightning.max_targets]shared.entity.Id = @splat(.none);
        for (chained[0..chained_count], targets[0..chained_count]) |kept, *slot| {
            if (lightning_jumps == 0) break;
            lightning_jumps -= 1;
            slot.* = kept.entity.id;
            visited[visited_count] = kept.entity.id;
            visited_count += 1;
            _ = combat.removeHealth(world, kept.entity, damage, owner_entity);
            queue[queue_tail] = .{ .position = kept.entity.transform.position };
            queue_tail += 1;
        }
        world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .lightning = .{
            .start_position = source.position,
            .targets = targets,
        } } } });
    }
}

fn damageRocketImpact(world: *World, owner_entity: *const system.Entity, impact_position: nz.Vec3(f32)) void {
    const base_damage = owner_entity.stat(.damage);
    const blast_radius: f32 = @as(f32, owner_entity.inventory.get(.rocket)) * 0.5 + 2;
    for (world.entities.values()) |*candidate| {
        if (candidate.max_health <= 0) continue;
        if (candidate.id == owner_entity.id) continue;
        if (owner_entity.kind.eql(candidate.kind)) continue;

        const distance = nz.vec.distance(candidate.transform.position, impact_position);
        if (distance > blast_radius) continue;

        const falloff = 1.0 - distance / blast_radius;
        const damage = base_damage * rocket_damage_multiplier * (0.5 + falloff * 0.5);
        _ = combat.removeHealth(world, candidate, damage, owner_entity);
    }
    tryProcLightning(world, owner_entity, impact_position, null);
}
