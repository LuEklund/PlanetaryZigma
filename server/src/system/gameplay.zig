const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const Director = @import("Director.zig");
const Info = system.Info;

const rocket_damage_multiplier: f32 = 1.5;
const lightning = .{
    .chain_range = @as(f32, 12),
    .max_targets = shared.net.Event.Effect.Lightning.max_targets,
    .max_victims = 256,
};

pub fn updateEnemies(info: *const Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (info.world.players.items.len == 0) return;

    for (info.world.entities.values()) |*enemy| {
        if (enemy.kind != .enemy) continue;
        const body_id = enemy.collider.body_id orelse continue;

        var closet: f32 = std.math.floatMax(f32);
        var player: *system.Entity = undefined;
        for (info.world.players.items) |player_id| {
            const current_player = info.world.getPtr(player_id) orelse continue;
            const distance = nz.vec.distance(current_player.transform.position, enemy.transform.position);
            if (distance < closet) {
                closet = distance;
                player = current_player;
            }
        }
        const to_player = player.transform.position - enemy.transform.position;
        const distance = nz.vec.length(to_player);

        const planet_up = shared.planetUp(enemy.transform.position) orelse continue;

        const fwd_proj = to_player - nz.vec.scale(planet_up, nz.vec.dot(to_player, planet_up));
        if (nz.vec.length(fwd_proj) > 0.0001) {
            const forward = nz.vec.normalize(fwd_proj);
            const rot = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
            Physics.setRotation(body_id, rot);
        }

        const forward_dir = enemy.transform.forward();
        const speed = enemy.stats.current.get(.speed);
        const damage = enemy.stats.current.get(.damage);
        const range = enemy.stats.current.get(.range);
        switch (enemy.kind.enemy) {
            .tubloida => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    //TODO: hardcoded capsule half-height; becomes a muzzle socket.
                    const muzzle_position = enemy.transform.position + nz.vec.scale(planet_up, 0.8);
                    const aim_dir = nz.vec.normalize(player.transform.position - muzzle_position);
                    const muzzle_velocity = nz.vec.scale(aim_dir, 50);
                    const bullet = try info.world.spawn(.{
                        .kind = .projectile_cube,
                        .owner_id = enemy.id,
                        .transform = .{
                            .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                            .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                        },
                        .replicated_velocity = muzzle_velocity,
                        .lifetime = 2,
                    });
                    bullet.stats.current.set(.damage, damage);
                    info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
            .tubloid => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    if (info.world.removeHealth(player, damage, enemy) == .ignored) std.log.debug("did not take damage", .{});
                    info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
            .bloorpLord => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack > enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    _ = info.world.spawn(.{
                        .kind = .{ .enemy = .tubloid },
                        .transform = .{ .position = enemy.transform.position },
                        .last_attack = info.elapsed_time,
                    }) catch {};
                    info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
        }
    }
}

pub fn updateProjectiles(info: *const Info, physics: *Physics) void {
    for (info.world.entities.values()) |*entity| {
        const projectile_kind = entity.kind.projectileKind() orelse continue;
        const previous_position = entity.transform.position;
        entity.transform.rotation = shared.entity.projectileRotation(projectile_kind, entity.replicated_velocity, shared.planetUp(entity.transform.position) orelse .{ 0, 1, 0 });
        entity.transform.position += nz.vec.scale(entity.replicated_velocity, info.delta_time);
        const travel = entity.transform.position - previous_position;

        const ray_hit = Physics.c.b3World_CastRayClosest(
            physics.world,
            .{ .x = previous_position[0], .y = previous_position[1], .z = previous_position[2] },
            .{ .x = travel[0], .y = travel[1], .z = travel[2] },
            Physics.c.b3DefaultQueryFilter(),
        );
        if (!ray_hit.hit) continue;
        const impact_position = Physics.toVec(ray_hit.point);

        const hit_body = Physics.c.b3Shape_GetBody(ray_hit.shapeId);
        const hit_id: shared.entity.Id = @enumFromInt(@as(u32, @intCast(@intFromPtr(Physics.c.b3Body_GetUserData(hit_body)))));
        if (hit_id == entity.owner_id) continue;

        const owner_entity = info.world.getPtr(entity.owner_id) orelse continue;
        const hit_entity = info.world.getPtr(hit_id) orelse continue;
        if (owner_entity.kind.eql(hit_entity.kind)) continue;

        switch (projectile_kind) {
            .cube => {
                if (info.world.removeHealth(hit_entity, entity.stats.current.get(.damage), owner_entity) != .ignored) {
                    tryProcLightning(info, owner_entity, hit_entity.transform.position, hit_entity);
                }
            },
            .rocket => {
                damageRocketImpact(info, owner_entity, impact_position);
                info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = impact_position } } });
            },
        }
        info.world.queueDespawn(entity.id);
    }
}

fn tryProcLightning(info: *const Info, owner_entity: *const system.Entity, origin: nz.Vec3(f32), hit_entity: ?*const system.Entity) void {
    const lightning_count = owner_entity.inventory.get(.lightning);
    var lightning_jumps = lightning_count;
    const damage = owner_entity.stats.current.get(.damage) * lightning_count * 0.1;
    const lightning_chance = shared.Item.lightning.attributes().get(.lightning_chance);
    if (!(owner_entity.kind == .player or lightning_jumps > 0 and info.world.prng.random().float(f32) < lightning_chance)) return;

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
        for (info.world.entities.values()) |*candidate| {
            if (candidate.kind.eql(owner_entity.kind) or !candidate.kind.hasHealth()) continue;
            if (std.mem.indexOfScalar(shared.entity.Id, visited[0..visited_count], candidate.id) != null) continue;
            const candidate_distance = nz.vec.distance(candidate.transform.position, source.position);
            if (candidate_distance > lightning.chain_range) continue;
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
            _ = info.world.removeHealth(kept.entity, damage, owner_entity);
            queue[queue_tail] = .{ .position = kept.entity.transform.position };
            queue_tail += 1;
        }
        info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .lightning = .{
            .start_position = source.position,
            .targets = targets,
        } } } });
    }
}

fn damageRocketImpact(info: *const Info, owner_entity: *const system.Entity, impact_position: nz.Vec3(f32)) void {
    const base_damage = owner_entity.stats.current.get(.damage);
    const blast_radius: f32 = @as(f32, owner_entity.inventory.get(.rocket)) * 0.5 + 2;
    for (info.world.entities.values()) |*candidate| {
        if (!candidate.kind.hasHealth()) continue;
        if (candidate.id == owner_entity.id) continue;
        if (owner_entity.kind.eql(candidate.kind)) continue;

        const distance = nz.vec.distance(candidate.transform.position, impact_position);
        if (distance > blast_radius) continue;

        const falloff = 1.0 - distance / blast_radius;
        const damage = base_damage * rocket_damage_multiplier * (0.5 + falloff * 0.5);
        _ = info.world.removeHealth(candidate, damage, owner_entity);
    }
    tryProcLightning(info, owner_entity, impact_position, null);
}

pub fn updateItems(info: *const Info) !void {
    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .item) continue;
        const item_kind = entity.kind.item;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            const length = player.transform.position - entity.transform.position;
            if (nz.vec.length(length) >= 2) continue;

            const item_count = info.world.giveItem(player, item_kind, 1) orelse continue;
            info.world.queueDespawn(entity.id);
            std.log.debug("item {t}, count: {d}", .{ item_kind, item_count });
        }
    }
}

pub fn updateTeleporter(info: *const Info, director: *Director) void {
    const entity = info.world.getPtr(info.world.teleporter_id) orelse return;
    const teleporter = &entity.teleporter;
    if (teleporter.charged == teleporter.max_charge) {
        director.spawning = false;
        teleporter.state = .completed;
        return;
    }
    const old_teleporter_charge = teleporter.charged;
    for (info.world.players.items) |player_id| {
        const player = info.world.getPtr(player_id) orelse continue;
        if (teleporter.state == .active and nz.vec.distance(player.transform.position, entity.transform.position) < shared.teleporter.charge_distance) {
            teleporter.charged += info.delta_time * 10;
            teleporter.charged = @min(teleporter.charged, teleporter.max_charge);
        }
    }
    if (old_teleporter_charge != teleporter.charged) {
        info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .teleporter_charge = @floatCast(teleporter.charged) } });
    }
}

pub fn updateLifetimes(info: *const Info) void {
    for (info.world.entities.values()) |*entity| {
        if (entity.lifetime) |*lifetime| {
            lifetime.* -= info.delta_time;
            if (lifetime.* <= 0) info.world.queueDespawn(entity.id);
        }
    }
}

pub fn playerRegen(info: *const Info) void {
    for (info.world.players.items) |player_id| {
        const player = info.world.getPtr(player_id) orelse continue;
        player.regen_carry += info.delta_time * player.stats.current.get(.regen);
        if (player.regen_carry < 1) continue;
        const whole_points = @floor(player.regen_carry);
        player.regen_carry -= whole_points;
        _ = info.world.addHealth(player, whole_points, null);
    }
}
