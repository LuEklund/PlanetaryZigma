const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const Entity = World.Entity;
const Physics = @import("../system/Physics.zig");
const combat = @import("combat.zig");

pub fn ready(entity: *const Entity, action: shared.entity.Action, now: f32) bool {
    return now - entity.last_used.get(action) >= entity.stat(action.cooldownStat());
}

pub const Outcome = enum { fired, on_cooldown, out_of_range };

pub fn useAction(world: *World, attacker: *Entity, potential_target: ?*const Entity, action: shared.entity.Action) Outcome {
    if (!ready(attacker, action, world.elapsed_time)) return .on_cooldown;

    const assigned = shared.entity.abilities(attacker.kind, attacker.survivor).get(action) orelse return .out_of_range;
    if (potential_target) |target| {
        const distance = nz.vec.distance(attacker.transform.position, target.transform.position);
        if (distance >= assigned.range) return .out_of_range;
    }

    attacker.last_used.set(action, world.elapsed_time);
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .action = .{ .id = attacker.id, .action = action, .skill = assigned.skill } } });
    return .fired;
}

pub const aim_range: f32 = 300;
const freeze_seconds: f32 = 10;
const melee_cone_cosine: f32 = 0.3;
const grenade_speed: f32 = 40;
const railgun_speed: f32 = 200;
const equipment_radius: f32 = 15;
const rocket_speed: f32 = 65;
const bullet_speed: f32 = 100;
const rocket_lifetime: f32 = 2.5;
const bullet_lifetime: f32 = 1;

pub fn executeSkill(world: *World, physics: *Physics, caster: *Entity, target: ?*Entity, assigned: shared.entity.AssignedSkill) !void {
    const planet_up = shared.Planet.up(caster.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
    switch (assigned.skill) {
        .shoot => {
            //TODO: muzzle socket per model; every skill assumes position + up * 0.8.
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const start_direction = if (target) |target_entity|
                nz.vec.normalize(target_entity.transform.position - muzzle_position)
            else if (caster.kind == .player) direction: {
                const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
                const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
                const aim_point = aimPoint(world, physics, caster.transform.position, caster.controller.input.camera_position, camera_forward);
                break :direction nz.vec.normalize(aim_point - muzzle_position);
            } else nz.vec.normalize(caster.transform.forward());
            const rocket_chance = caster.stat(.rocket_chance);
            const fires_rocket = rocket_chance > 0 and world.prng.random().float(f32) < rocket_chance;
            const projectile_kind: shared.entity.ProjectileKind = if (fires_rocket) .rocket else .cube;
            _ = try world.spawn(.{
                .kind = switch (projectile_kind) {
                    .cube => .projectile_cube,
                    .rocket => .projectile_rocket,
                },
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(start_direction, 1.0),
                    .rotation = shared.entity.projectileRotation(projectile_kind, start_direction, planet_up),
                },
                .replicated_velocity = nz.vec.scale(start_direction, if (fires_rocket) rocket_speed else bullet_speed),
                .lifetime = if (fires_rocket) rocket_lifetime else bullet_lifetime,
                .damage = caster.stat(.damage),
            });
        },
        .spread_shot => {
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            var start_direction: nz.Vec3(f32) = undefined;
            var spread_right: nz.Vec3(f32) = undefined;
            var spread_up: nz.Vec3(f32) = undefined;
            if (target == null and caster.kind == .player) {
                const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
                const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
                const aim_point = aimPoint(world, physics, caster.transform.position, caster.controller.input.camera_position, camera_forward);
                start_direction = nz.vec.normalize(aim_point - muzzle_position);
                spread_right = nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 }));
                spread_up = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 1, 0 }));
            } else {
                start_direction = if (target) |target_entity|
                    nz.vec.normalize(target_entity.transform.position - muzzle_position)
                else
                    nz.vec.normalize(caster.transform.forward());
                spread_right = nz.vec.normalize(nz.vec.cross(start_direction, planet_up));
                spread_up = nz.vec.cross(spread_right, start_direction);
            }
            const rocket_chance = caster.stat(.rocket_chance);
            const fires_rocket = rocket_chance > 0 and world.prng.random().float(f32) < rocket_chance;
            const projectile_kind: shared.entity.ProjectileKind = if (fires_rocket) .rocket else .cube;
            for (0..10) |_| {
                const theta = world.prng.random().float(f32) * std.math.tau;
                const spread = world.prng.random().float(f32) * 0.1;
                const off_set = nz.vec.scale(spread_right, @cos(theta) * spread) + nz.vec.scale(spread_up, @sin(theta) * spread);
                _ = try world.spawn(.{
                    .kind = switch (projectile_kind) {
                        .cube => .projectile_cube,
                        .rocket => .projectile_rocket,
                    },
                    .owner_id = caster.id,
                    .transform = .{
                        .position = muzzle_position + nz.vec.scale(start_direction, 1.0),
                        .rotation = shared.entity.projectileRotation(projectile_kind, start_direction, planet_up),
                    },
                    .replicated_velocity = nz.vec.scale(start_direction + off_set, if (fires_rocket) rocket_speed else bullet_speed),
                    .lifetime = if (fires_rocket) rocket_lifetime else bullet_lifetime,
                    .damage = caster.stat(.damage),
                    .flags = .{ .invincible = true },
                });
            }
        },
        .dash => {
            const forward = if (target) |target_entity|
                nz.vec.normalize(target_entity.transform.position - caster.transform.position)
            else if (caster.kind == .player) camera: {
                const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
                break :camera nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
            } else nz.vec.normalize(caster.transform.forward());
            const fwd_proj = forward - nz.vec.scale(planet_up, nz.vec.dot(forward, planet_up));
            world.physics_commands.appendAssumeCapacity(.{
                .verb = .{ .teleport = caster.transform.position + nz.vec.scale(fwd_proj, 2 * caster.stat(.speed)) },
                .id = caster.id,
            });
        },
        .use_equipment => {
            const effect = shared.Item.equippedEffect(caster.inventory) orelse return;
            switch (effect) {
                .freeze_world => if (world.world_unstun_at <= world.elapsed_time) {
                    world.world_unstun_at = world.elapsed_time + freeze_seconds;
                },
                .heal_burst => for (world.players.items) |player_id| {
                    const player = world.getPtr(player_id) orelse continue;
                    if (nz.vec.distance(player.transform.position, caster.transform.position) > equipment_radius) continue;
                    _ = combat.addHealth(world, player, player.max_health * 0.5, null);
                },
                .blast_wave => {
                    const damage = caster.stat(.damage) * 5;
                    for (world.entities.values()) |*candidate| {
                        if (candidate.kind != .enemy or candidate.flags.is_dead) continue;
                        if (nz.vec.distance(candidate.transform.position, caster.transform.position) > equipment_radius) continue;
                        _ = combat.removeHealth(world, candidate, damage, caster);
                    }
                    world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = caster.transform.position } } });
                },
            }
        },
        .shoot_cube => {
            const target_entity = target orelse return;
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_dir = nz.vec.normalize(target_entity.transform.position - muzzle_position);
            _ = try world.spawn(.{
                .kind = .projectile_cube,
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                    .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                },
                .replicated_velocity = nz.vec.scale(aim_dir, 50),
                .lifetime = 2,
                .damage = caster.stat(.damage),
            });
        },
        .heal => {
            const target_entity = target orelse return;
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_dir = nz.vec.normalize(target_entity.transform.position - muzzle_position);
            _ = try world.spawn(.{
                .kind = .projectile_heal,
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(aim_dir, 1.0),
                    .rotation = shared.entity.projectileRotation(.cube, aim_dir, planet_up),
                },
                .replicated_velocity = nz.vec.scale(aim_dir, 50),
                .lifetime = 2,
                .damage = caster.stat(.damage),
            });
        },
        .melee => {
            const target_entity = target orelse return;
            _ = combat.removeHealth(world, target_entity, caster.stat(.damage), caster);
        },
        .arc_jump => {
            const target_entity = target orelse return;
            world.act(.{ .id = caster.id, .verb = .{ .arc_jump = target_entity.transform.position } });
        },
        .plant, .charge, .explode => {},
        .melee_cone => {
            const forward = aimDirection(caster, target, planet_up);
            const damage = caster.stat(.damage) * assigned.damage_multiplier;
            for (world.entities.values()) |*candidate| {
                if (candidate.max_health <= 0 or candidate.flags.is_dead or candidate.kind.eql(caster.kind)) continue;
                const offset = candidate.transform.position - caster.transform.position;
                const distance = nz.vec.length(offset);
                if (distance > assigned.range or distance < 0.0001) continue;
                if (nz.vec.dot(nz.vec.scale(offset, 1 / distance), forward) < melee_cone_cosine) continue;
                _ = combat.removeHealth(world, candidate, damage, caster);
            }
        },
        .ground_slam => {
            blastAt(world, caster, caster.transform.position, assigned.radius, caster.stat(.damage) * assigned.damage_multiplier);
        },
        .grenade => {
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_point = if (target) |target_entity| target_entity.transform.position else if (caster.kind == .player) playerAimPoint(world, physics, caster) else caster.transform.position + nz.vec.scale(caster.transform.forward(), 20);
            const direction = nz.vec.normalize(aim_point - muzzle_position);
            _ = try world.spawn(.{
                .kind = .projectile_rocket,
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + direction,
                    .rotation = shared.entity.projectileRotation(.rocket, direction, planet_up),
                },
                .replicated_velocity = nz.vec.scale(direction, grenade_speed),
                .lifetime = rocket_lifetime,
                .damage = caster.stat(.damage) * assigned.damage_multiplier,
            });
        },
        .railgun => {
            const muzzle_position = caster.transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_point = if (target) |target_entity| target_entity.transform.position else if (caster.kind == .player) playerAimPoint(world, physics, caster) else caster.transform.position + nz.vec.scale(caster.transform.forward(), 20);
            const direction = nz.vec.normalize(aim_point - muzzle_position);
            _ = try world.spawn(.{
                .kind = .projectile_cube,
                .owner_id = caster.id,
                .transform = .{
                    .position = muzzle_position + direction,
                    .rotation = shared.entity.projectileRotation(.cube, direction, planet_up),
                },
                .replicated_velocity = nz.vec.scale(direction, railgun_speed),
                .lifetime = bullet_lifetime,
                .damage = caster.stat(.damage) * assigned.damage_multiplier,
                .flags = .{ .invincible = true },
            });
        },
        .blink => {
            const forward = aimDirection(caster, target, planet_up);
            world.physics_commands.appendAssumeCapacity(.{
                .verb = .{ .teleport = caster.transform.position + nz.vec.scale(forward, assigned.range) + nz.vec.scale(planet_up, 0.5) },
                .id = caster.id,
            });
        },
        .heal_pulse => for (world.entities.values()) |*ally| {
            if (!ally.kind.eql(caster.kind) or ally.flags.is_dead) continue;
            if (nz.vec.distance(ally.transform.position, caster.transform.position) > assigned.radius) continue;
            _ = combat.addHealth(world, ally, ally.max_health * assigned.damage_multiplier, null);
        },
        .artillery => {
            const aim_point = if (target) |target_entity| target_entity.transform.position else if (caster.kind == .player) playerAimPoint(world, physics, caster) else caster.transform.position;
            blastAt(world, caster, aim_point, assigned.radius, caster.stat(.damage) * assigned.damage_multiplier);
        },
    }
}

fn aimPoint(world: *World, physics: *Physics, player_position: nz.Vec3(f32), camera_position: nz.Vec3(f32), camera_forward: nz.Vec3(f32)) nz.Vec3(f32) {
    const player_depth = nz.vec.dot(player_position - camera_position, camera_forward);
    const ray_start = camera_position + nz.vec.scale(camera_forward, player_depth);
    const translation = nz.vec.scale(camera_forward, aim_range);
    const entity_distance: f32 = if (World.rayCast(physics, ray_start, translation)) |hit| nz.vec.length(hit.point - ray_start) else aim_range;

    var terrain_distance: f32 = aim_range;
    var traveled: f32 = 0;
    for (0..128) |_| {
        const sample = ray_start + nz.vec.scale(camera_forward, traveled);
        const distance = world.planet.sample(sample);
        if (distance < 0.05) {
            terrain_distance = traveled;
            break;
        }
        traveled += @max(distance * 0.5, 0.05);
        if (traveled >= aim_range) break;
    }
    return ray_start + nz.vec.scale(camera_forward, @min(entity_distance, terrain_distance));
}

fn aimDirection(caster: *const Entity, target: ?*const Entity, planet_up: nz.Vec3(f32)) nz.Vec3(f32) {
    const forward = if (target) |target_entity|
        nz.vec.normalize(target_entity.transform.position - caster.transform.position)
    else if (caster.kind == .player) camera: {
        const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
        break :camera nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
    } else nz.vec.normalize(caster.transform.forward());
    const flat = forward - nz.vec.scale(planet_up, nz.vec.dot(forward, planet_up));
    if (nz.vec.length(flat) < 0.0001) return nz.vec.normalize(caster.transform.forward());
    return nz.vec.normalize(flat);
}

fn playerAimPoint(world: *World, physics: *Physics, caster: *const Entity) nz.Vec3(f32) {
    const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(caster.controller.input.camera_rotation);
    const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
    return aimPoint(world, physics, caster.transform.position, caster.controller.input.camera_position, camera_forward);
}

fn blastAt(world: *World, caster: *Entity, center: nz.Vec3(f32), radius: f32, damage: f32) void {
    for (world.entities.values()) |*candidate| {
        if (candidate.max_health <= 0 or candidate.flags.is_dead or candidate.kind.eql(caster.kind)) continue;
        const distance = nz.vec.distance(candidate.transform.position, center);
        if (distance > radius) continue;
        _ = combat.removeHealth(world, candidate, damage * (1 - 0.5 * distance / radius), caster);
    }
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .effect = .{ .rocket_impact = center } } });
}
