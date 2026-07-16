const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const Director = @import("Director.zig");
const Info = system.Info;

const rocket_explosion_radius: f32 = 8;
const rocket_damage_multiplier: f32 = 1.5;

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

        const up_len = nz.vec.length(enemy.transform.position);
        if (up_len < 0.0001) continue;
        const planet_up = nz.vec.scale(enemy.transform.position, 1.0 / up_len);

        const fwd_proj = to_player - nz.vec.scale(planet_up, nz.vec.dot(to_player, planet_up));
        if (nz.vec.length(fwd_proj) > 0.0001) {
            const forward = nz.vec.normalize(fwd_proj);
            const rot = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
            Physics.setRotation(body_id, rot);
        }

        const forward_dir = enemy.transform.forward();
        const speed = enemy.stats.get(.speed).current;
        const damage = enemy.stats.get(.damage).current;
        const range = enemy.stats.get(.range).current;
        switch (enemy.kind.enemy) {
            .tubloida => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    const muzzle_velocity = nz.vec.scale(forward_dir, 50);
                    const bullet = try info.world.spawn(.{
                        .kind = .projectile_cube,
                        .owner_id = enemy.id,
                        .transform = .{
                            .position = enemy.transform.position + nz.vec.scale(forward_dir, 1.5),
                            .rotation = projectileRotation(.cube, forward_dir, planet_up),
                        },
                        .velocity = muzzle_velocity,
                        .lifetime = 2,
                    });
                    bullet.stats.setCurrent(.damage, damage);
                    info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
            .tubloid => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    if (!info.world.removeHealth(player, damage)) std.log.debug("did not take damage", .{});
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
        entity.transform.rotation = projectileRotation(projectile_kind, entity.velocity, surfaceUp(entity.transform.position));
        entity.transform.position += nz.vec.scale(entity.velocity, info.delta_time);
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
            .cube => _ = info.world.removeHealth(hit_entity, entity.stats.get(.damage).current),
            .rocket => {
                damageRocketImpact(info, owner_entity, impact_position, entity.stats.get(.damage).current);
                info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .rocket_impact = impact_position } });
            },
        }
        info.world.queueDespawn(entity.id);
    }
}

fn surfaceUp(position: nz.Vec3(f32)) nz.Vec3(f32) {
    const distance = nz.vec.length(position);
    return if (distance > 0.001) nz.vec.scale(position, 1.0 / distance) else .{ 0, 1, 0 };
}

fn projectileRotation(kind: shared.entity.ProjectileKind, direction: nz.Vec3(f32), up_hint: nz.Vec3(f32)) nz.quat.Hamiltonian(f32) {
    if (nz.vec.length(direction) < 0.001) return .identity;
    const base = nz.quat.Hamiltonian(f32).lookAt(direction, up_hint).normalize();
    return switch (kind) {
        .cube => base,
        .rocket => base.mul(nz.quat.Hamiltonian(f32).angleAxis(-std.math.pi / 2.0, .{ 1, 0, 0 })).normalize(),
    };
}

fn damageRocketImpact(info: *const Info, owner_entity: *const system.Entity, impact_position: nz.Vec3(f32), base_damage: f32) void {
    for (info.world.entities.values()) |*candidate| {
        if (!candidate.kind.hasHealth()) continue;
        if (candidate.id == owner_entity.id) continue;
        if (owner_entity.kind.eql(candidate.kind)) continue;

        const distance = nz.vec.distance(candidate.transform.position, impact_position);
        if (distance > rocket_explosion_radius) continue;

        const falloff = 1.0 - distance / rocket_explosion_radius;
        const damage = base_damage * rocket_damage_multiplier * (0.5 + falloff * 0.5);
        _ = info.world.removeHealth(candidate, damage);
    }
}

pub fn updateItems(info: *const Info) !void {
    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .item) continue;
        const item_kind = entity.kind.item;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            const length = player.transform.position - entity.transform.position;
            if (nz.vec.length(length) >= 2) continue;

            const item_count = player.inventory.add(item_kind, 1);
            player.stats.gain(item_kind, 1);
            player.stats.refresh(player.inventory);
            info.world.client_updates.appendAssumeCapacity(.{ .inventory = .{
                .id = player_id,
                .item_kind = item_kind,
                .set = item_count,
            } });
            for (std.enums.values(shared.Stat.Kind)) |stat_kind| {
                if (item_kind.getAttributeValues().get(stat_kind) == 0) continue;
                const stat = player.stats.get(stat_kind);
                info.world.client_updates.appendAssumeCapacity(.{ .stat = .{ .id = player_id, .stat_kind = stat_kind, .amount = .{ .set_max = @floatCast(stat.max) } } });
                info.world.client_updates.appendAssumeCapacity(.{ .stat = .{ .id = player_id, .stat_kind = stat_kind, .amount = .{ .set_current = @floatCast(stat.current) } } });
            }

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
        return;
    }
    for (info.world.players.items) |player_id| {
        const player = info.world.getPtr(player_id) orelse continue;
        if (teleporter.active and nz.vec.distance(player.transform.position, entity.transform.position) < shared.teleporter.charge_distance) {
            teleporter.charged += info.delta_time + 100;
            teleporter.charged = @min(teleporter.charged, teleporter.max_charge);
        }
    }
    info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .teleporter_charge = @floatCast(teleporter.charged) } });
}

pub fn updateLifetimes(info: *const Info) void {
    for (info.world.entities.values()) |*entity| {
        if (entity.lifetime) |*lifetime| {
            lifetime.* -= info.delta_time;
            if (lifetime.* <= 0) info.world.queueDespawn(entity.id);
        }
    }
}
