const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../System.zig");
const Physics = @import("Physics.zig");
const World = system.World;

const rocket_damage_multiplier: f32 = 1.5;
const enemy_max_spawn_distance: f32 = 85;
const enemy_min_spawn_distance: f32 = enemy_max_spawn_distance * 0.8;
const lightning = .{
    .max_targets = shared.net.Event.Effect.Lightning.max_targets,
    .max_victims = 256,
};

pub fn updateDirector(world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (world.players.items.len == 0) return;

    const director = &world.director;
    if (world.toggle_spawning_requested) {
        world.toggle_spawning_requested = false;
        director.spawning = !director.spawning;
        std.log.debug("dev: enemy spawning {s}", .{if (director.spawning) "on" else "off"});
    }

    if (director.spawning) {
        if (world.elapsed_time - director.last_salary >= 1.0) {
            director.last_salary = world.elapsed_time;
            director.credits += director.salary_per_second * 15;
        }
        const random = world.prng.random();
        const enemy_kind: shared.entity.EnemyKind = switch (random.uintLessThan(u32, 100)) {
            0...40 => .tubloid,
            41...60 => .tubloida,
            61...75 => .hunkloid,
            76...90 => .blooploid,
            else => .bloorp_lord,
        };
        const cost = shared.entity.spec(.{ .enemy = enemy_kind }).currency;
        if (director.credits >= cost) {
            const player_index = random.uintLessThan(usize, world.players.items.len);
            if (world.getPtr(world.players.items[player_index])) |player| {
                const radius_float = world.planet_radius;
                const surface = shared.planet.surfacePointNear(player.transform.position, radius_float, enemy_min_spawn_distance, enemy_max_spawn_distance, random);
                const spawn_position = surface + nz.vec.scale(nz.vec.normalize(surface), 2);
                if (world.spawn(.{
                    .kind = .{ .enemy = enemy_kind },
                    .transform = .{ .position = spawn_position },
                    .last_attack = world.elapsed_time,
                })) |_| {
                    director.credits -= cost;
                } else |_| {}
            }
        }
    }
}

fn attackLands(world: *World, attacker: *system.Entity, target: *const system.Entity, attack: shared.entity.State) bool {
    const last_used, const range, const cooldown = switch (attack) {
        .attack => .{ &attacker.last_attack, shared.entity.spec(attacker.kind).primary_range, attacker.stat(.primary_cooldown) },
        .utility => .{ &attacker.last_utility, shared.entity.spec(attacker.kind).utility_range, attacker.stat(.utility_cooldown) },
        else => unreachable,
    };
    const distance = nz.vec.distance(attacker.transform.position, target.transform.position);
    if (distance < range and world.elapsed_time - last_used.* >= cooldown) {
        last_used.* = world.elapsed_time;
        world.client_updates.appendAssumeCapacity(.{ .event = .{ .trigger = .{ .id = attacker.id, .state = attack } } });
        return true;
    }
    return false;
}

pub fn updateEnemies(world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (world.players.items.len == 0) return;

    world.navmesh.deleteUnused(world.gpa, world.elapsed_time);

    for (world.entities.values()) |*enemy| {
        if (enemy.kind != .enemy) continue;
        // std.log.debug("elapsed_time = {d}, un_stun_at {d}", .{ world.elapsed_time, enemy.un_stun_at });
        if (enemy.un_stun_at > world.elapsed_time) continue;
        const body_id = enemy.collider.body_id orelse continue;

        var closest_player: ?*system.Entity = null;
        var closest_distance: f32 = std.math.floatMax(f32);
        for (world.players.items) |player_id| {
            const current_player = world.getPtr(player_id) orelse continue;
            if (current_player.flags.is_dead) continue;
            const player_distance = nz.vec.distance(current_player.transform.position, enemy.transform.position);
            if (player_distance >= closest_distance) continue;
            closest_distance = player_distance;
            closest_player = current_player;
        }
        const player = closest_player orelse return;
        try world.navmesh.ensure(world.gpa, enemy.transform.position, world.planet_radius, world.elapsed_time);
        try world.navmesh.ensure(world.gpa, player.transform.position, world.planet_radius, world.elapsed_time);
        const to_player = player.transform.position - enemy.transform.position;
        const distance_to_player = nz.vec.length(to_player);

        if (distance_to_player > enemy_max_spawn_distance * 1.7) {
            const surface = shared.planet.surfacePointNear(player.transform.position, world.planet_radius, enemy_max_spawn_distance, enemy_max_spawn_distance, world.prng.random());
            const leash_position = surface + nz.vec.scale(nz.vec.normalize(surface), 2);
            enemy.transform.position = leash_position;
            Physics.setPosition(body_id, leash_position);
            continue;
        }

        const planet_up = shared.planet.up(enemy.transform.position) orelse continue;

        const fwd_proj = to_player - nz.vec.scale(planet_up, nz.vec.dot(to_player, planet_up));
        if (nz.vec.length(fwd_proj) > 0.0001) {
            const forward = nz.vec.normalize(fwd_proj);
            const rot = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
            Physics.setRotation(body_id, rot);
        }

        const forward_dir = enemy.transform.forward();
        const speed = enemy.stat(.speed);
        const damage = enemy.stat(.damage);
        const range = shared.entity.spec(enemy.kind).primary_range;
        switch (enemy.kind.enemy) {
            .tubloida => {
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveOnPlanet(enemy, chase_dir, speed, world.delta_time);
                if (attackLands(world, enemy, player, .attack)) {
                    //TODO: hardcoded capsule half-height; becomes a muzzle socket.
                    const muzzle_position = enemy.transform.position + nz.vec.scale(planet_up, 0.8);
                    const aim_dir = nz.vec.normalize(player.transform.position - muzzle_position);
                    const muzzle_velocity = nz.vec.scale(aim_dir, 50);
                    _ = try world.spawn(.{
                        .kind = .projectile_cube,
                        .owner_id = enemy.id,
                        .transform = .{
                            .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                            .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                        },
                        .replicated_velocity = muzzle_velocity,
                        .lifetime = 2,
                        .damage = damage,
                    });
                }
            },
            .tubloid => {
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveOnPlanet(enemy, chase_dir, speed, world.delta_time);
                if (attackLands(world, enemy, player, .attack)) {
                    if (distance_to_player < range) {
                        _ = world.removeHealth(player, damage, enemy);
                    }
                }
            },
            .bloorp_lord => {
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) forward_dir else .{ 0, 0, 0 };
                Physics.floatOnPlanet(enemy, chase_dir, speed, world.planet_radius, 14, world.delta_time);
                if (attackLands(world, enemy, player, .attack)) {
                    _ = world.spawn(.{
                        .kind = .{ .enemy = .tubloid },
                        .transform = .{ .position = enemy.transform.position },
                        .last_attack = world.elapsed_time,
                    }) catch {};
                }
            },
            .hunkloid => {
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) forward_dir else .{ 0, 0, 0 };
                if (enemy.mode == .walking) Physics.moveOnPlanet(enemy, chase_dir, speed, world.delta_time);
                const utility_range = shared.entity.spec(enemy.kind).utility_range;
                if (distance_to_player > utility_range * 0.75 and attackLands(world, enemy, player, .utility)) {
                    Physics.arcJumpTo(enemy, player.transform.position);
                }

                if (attackLands(world, enemy, player, .attack)) {
                    if (distance_to_player < range) {
                        _ = world.removeHealth(player, damage, enemy);
                    }
                }
            },
            .blooploid => {
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) forward_dir else .{ 0, 0, 0 };
                Physics.floatOnPlanet(enemy, chase_dir, speed, world.planet_radius, 7, world.delta_time);
                if (attackLands(world, enemy, player, .attack)) {
                    //TODO: hardcoded capsule half-height; becomes a muzzle socket.
                    const muzzle_position = enemy.transform.position + nz.vec.scale(planet_up, 0.8);
                    const aim_dir = nz.vec.normalize(player.transform.position - muzzle_position);
                    const muzzle_velocity = nz.vec.scale(aim_dir, 50);
                    _ = try world.spawn(.{
                        .kind = .projectile_cube,
                        .owner_id = enemy.id,
                        .transform = .{
                            .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                            .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                        },
                        .replicated_velocity = muzzle_velocity,
                        .lifetime = 2,
                        .damage = damage,
                    });
                }
            },
        }
    }
}

pub fn updateProjectiles(world: *World, physics: *Physics) void {
    for (world.entities.values()) |*entity| {
        const projectile_kind = entity.kind.projectileKind() orelse continue;
        const previous_position = entity.transform.position;
        entity.transform.rotation = shared.entity.projectileRotation(projectile_kind, entity.replicated_velocity, shared.planet.up(entity.transform.position) orelse .{ 0, 1, 0 });
        entity.transform.position += nz.vec.scale(entity.replicated_velocity, world.delta_time);
        const travel = entity.transform.position - previous_position;

        const ray_hit = Physics.c.b3World_CastRayClosest(
            physics.world,
            .{ .x = previous_position[0], .y = previous_position[1], .z = previous_position[2] },
            .{ .x = travel[0], .y = travel[1], .z = travel[2] },
            Physics.c.b3DefaultQueryFilter(),
        );
        if (!ray_hit.hit) {
            if (shared.planet.sdf.sampled(entity.transform.position, world.planet_radius) < 0) {
                if (world.getPtr(entity.owner_id)) |owner_entity| {
                    switch (projectile_kind) {
                        .cube => {},
                        .rocket => {
                            damageRocketImpact(world, owner_entity, entity.transform.position);
                            world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = entity.transform.position } } });
                        },
                    }
                }
                world.queueDespawn(entity.id);
            }
            continue;
        }
        const impact_position = Physics.toVec(ray_hit.point);

        const hit_body = Physics.c.b3Shape_GetBody(ray_hit.shapeId);
        const hit_id: shared.entity.Id = @enumFromInt(@as(u32, @intCast(@intFromPtr(Physics.c.b3Body_GetUserData(hit_body)))));
        if (hit_id == entity.owner_id) continue;

        const owner_entity = world.getPtr(entity.owner_id) orelse continue;
        const hit_entity = world.getPtr(hit_id) orelse continue;
        if (owner_entity.kind.eql(hit_entity.kind)) continue;

        switch (projectile_kind) {
            .cube => {
                if (world.removeHealth(hit_entity, entity.damage, owner_entity) != .ignored) {
                    tryProcLightning(world, owner_entity, hit_entity.transform.position, hit_entity);
                }
            },
            .rocket => {
                damageRocketImpact(world, owner_entity, impact_position);
                world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = impact_position } } });
            },
        }
        world.queueDespawn(entity.id);
    }
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
            if (candidate.kind.eql(owner_entity.kind) or !candidate.kind.hasHealth()) continue;
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
            _ = world.removeHealth(kept.entity, damage, owner_entity);
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
        if (!candidate.kind.hasHealth()) continue;
        if (candidate.id == owner_entity.id) continue;
        if (owner_entity.kind.eql(candidate.kind)) continue;

        const distance = nz.vec.distance(candidate.transform.position, impact_position);
        if (distance > blast_radius) continue;

        const falloff = 1.0 - distance / blast_radius;
        const damage = base_damage * rocket_damage_multiplier * (0.5 + falloff * 0.5);
        _ = world.removeHealth(candidate, damage, owner_entity);
    }
    tryProcLightning(world, owner_entity, impact_position, null);
}

pub fn updateWipe(world: *World, physics: *Physics) !void {
    if (world.players.items.len == 0) return;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        if (!player.flags.is_dead) return;
    }
    std.log.info("wipe: go again -> ship", .{});
    world.stage = 0;
    world.director.spawning = false;
    try world.loadPlace(.ship, physics);
}

pub fn updateItems(world: *World) !void {
    for (world.entities.values()) |*entity| {
        if (entity.kind != .item) continue;
        const item_kind = entity.kind.item;
        for (world.players.items) |player_id| {
            const player = world.getPtr(player_id) orelse return error.PlayerNotFound;
            if (player.flags.is_dead) continue;
            const length = player.transform.position - entity.transform.position;
            if (nz.vec.length(length) >= 2) continue;

            const item_count = world.giveItem(player, item_kind, 1) orelse continue;
            world.queueDespawn(entity.id);
            std.log.debug("item {t}, count: {d}", .{ item_kind, item_count });
            break;
        }
    }
}

pub fn updateTeleporter(world: *World) void {
    const entity = world.getPtr(world.teleporter_id) orelse return;
    const teleporter = &entity.teleporter;
    if (teleporter.charged == teleporter.max_charge) {
        world.director.spawning = false;
        teleporter.state = .completed;
        return;
    }
    const old_teleporter_charge = teleporter.charged;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        if (player.flags.is_dead) continue;
        if (teleporter.state == .active and nz.vec.distance(player.transform.position, entity.transform.position) < shared.teleporter.charge_distance) {
            teleporter.charged += world.delta_time * 10;
            teleporter.charged = @min(teleporter.charged, teleporter.max_charge);
        }
    }
    if (old_teleporter_charge != teleporter.charged) {
        world.client_updates.appendAssumeCapacity(.{ .event = .{ .teleporter_charge = @floatCast(teleporter.charged) } });
    }
}

pub fn updateLifetimes(world: *World) void {
    for (world.entities.values()) |*entity| {
        if (entity.lifetime) |*lifetime| {
            lifetime.* -= world.delta_time;
            if (lifetime.* <= 0) world.queueDespawn(entity.id);
        }
    }
}

pub fn playerRegen(world: *World) void {
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        player.regen_carry += world.delta_time * player.stat(.regen);
        if (player.regen_carry < 1) continue;
        const whole_points = @floor(player.regen_carry);
        player.regen_carry -= whole_points;
        _ = world.addHealth(player, whole_points, null);
    }
}
