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

pub fn useAction(
    world: *World,
    attacker: *Entity,
    potential_target: ?*const Entity,
    action: shared.entity.Action,
) Outcome {
    if (!ready(attacker, action, world.elapsed_time)) return .on_cooldown;

    const assigned = shared.entity.abilities(
        attacker.kind,
        attacker.survivor,
    ).get(action) orelse return .out_of_range;
    if (potential_target) |target| {
        const distance = nz.vec.distance(attacker.transform.position, target.transform.position);
        if (distance >= assigned.range) return .out_of_range;
    }

    attacker.last_used.set(action, world.elapsed_time);
    world.client_updates.appendAssumeCapacity(
        .{
            .event = .{
                .action = .{ .id = attacker.id, .action = action, .skill = assigned.skill },
            },
        },
    );
    return .fired;
}

pub const aim_range: f32 = 300;
const freeze_seconds: f32 = 3;
const melee_cone_cosine: f32 = 0.3;
const grenade_speed: f32 = 40;
const railgun_speed: f32 = 200;
const equipment_radius: f32 = 15;
const rocket_speed: f32 = 65;
const bullet_speed: f32 = 100;
const rocket_lifetime: f32 = 2.5;
const bullet_lifetime: f32 = 1;

const muzzle_height: f32 = 0.8;

const Cast = struct {
    world: *World,
    physics: *Physics,
    caster: *Entity,
    target: ?*Entity,
    assigned: shared.entity.AssignedSkill,
    up: nz.Vec3(f32),
    muzzle: nz.Vec3(f32),

    fn damage(cast: Cast) f32 {
        return cast.caster.stat(.damage) * cast.assigned.damage_multiplier;
    }
};

pub fn executeSkill(
    world: *World,
    physics: *Physics,
    caster: *Entity,
    target: ?*Entity,
    assigned: shared.entity.AssignedSkill,
) !void {
    const up = shared.Planet.surfaceUp(caster.transform.position);
    const cast: Cast = .{
        .world = world,
        .physics = physics,
        .caster = caster,
        .target = target,
        .assigned = assigned,
        .up = up,
        .muzzle = caster.transform.position + nz.vec.scale(up, muzzle_height),
    };
    switch (assigned.skill) {
        .shoot => try shoot(cast),
        .spread_shot => try spreadShot(cast),
        .dash => dash(cast),
        .use_equipment => useEquipment(cast),
        .shoot_cube => if (target) |aim| try spawnProjectile(
            cast,
            .projectile_cube,
            directionTo(cast, aim),
            50,
            2,
            .{},
        ),
        .heal => if (target) |aim| try spawnProjectile(
            cast,
            .projectile_heal,
            directionTo(cast, aim),
            50,
            2,
            .{},
        ),
        .melee => if (target) |victim| {
            _ = combat.removeHealth(world, victim, cast.damage(), caster);
        },
        .arc_jump => if (target) |destination| {
            world.act(
                .{ .id = caster.id, .verb = .{ .arc_jump = destination.transform.position } },
            );
        },
        .plant, .charge, .explode => {},
        .melee_cone => meleeCone(cast),
        .ground_slam => blastAt(
            world,
            caster,
            caster.transform.position,
            assigned.radius,
            cast.damage(),
        ),
        .grenade => {
            const direction = nz.vec.normalize(aimTarget(cast, 20) - cast.muzzle);
            try spawnProjectile(
                cast,
                .projectile_rocket,
                direction,
                grenade_speed,
                rocket_lifetime,
                .{},
            );
        },
        .railgun => {
            const direction = nz.vec.normalize(aimTarget(cast, 20) - cast.muzzle);
            try spawnProjectile(cast, .projectile_cube, direction, railgun_speed, bullet_lifetime, .{
                .invincible = true,
            });
        },
        .blink => {
            const forward = aimDirection(caster, target, up);
            const destination = caster.transform.position + nz.vec.scale(forward, assigned.range);
            world.physics_commands.appendAssumeCapacity(.{
                .verb = .{ .teleport = destination + nz.vec.scale(up, 0.5) },
                .id = caster.id,
            });
        },
        .heal_pulse => healPulse(cast),
        .artillery => blastAt(world, caster, aimTarget(cast, 0), assigned.radius, cast.damage()),
    }
}

fn directionTo(cast: Cast, aim: *const Entity) nz.Vec3(f32) {
    return nz.vec.normalize(aim.transform.position - cast.muzzle);
}

/// Target position, else where the player's camera points, else `fallback_distance` ahead.
fn aimTarget(cast: Cast, fallback_distance: f32) nz.Vec3(f32) {
    const caster = cast.caster;
    if (cast.target) |aim| return aim.transform.position;
    if (caster.kind == .player) return playerAimPoint(cast.world, cast.physics, caster);
    return caster.transform.position + nz.vec.scale(caster.transform.forward(), fallback_distance);
}

fn cameraRotation(caster: *const Entity) nz.quat.Hamiltonian(f32) {
    return .fromVec(caster.controller.input.camera_rotation);
}

fn spawnProjectile(
    cast: Cast,
    kind: shared.entity.Kind,
    direction: nz.Vec3(f32),
    speed: f32,
    lifetime: f32,
    flags: Entity.Flags,
) !void {
    const projectile_kind: shared.entity.ProjectileKind = if (kind == .projectile_rocket) .rocket else .cube;
    _ = try cast.world.spawn(.{
        .kind = kind,
        .owner_id = cast.caster.id,
        .transform = .{
            .position = cast.muzzle + direction,
            .rotation = shared.entity.projectileRotation(projectile_kind, direction, cast.up),
        },
        .replicated_velocity = nz.vec.scale(direction, speed),
        .lifetime = lifetime,
        .damage = cast.damage(),
        .flags = flags,
    });
}

fn rollsRocket(cast: Cast) bool {
    const chance = cast.caster.stat(.rocket_chance);
    return chance > 0 and cast.world.prng.random().float(f32) < chance;
}

fn shoot(cast: Cast) !void {
    const direction = nz.vec.normalize(aimTarget(cast, 20) - cast.muzzle);
    if (rollsRocket(cast)) return spawnProjectile(
        cast,
        .projectile_rocket,
        direction,
        rocket_speed,
        rocket_lifetime,
        .{},
    );
    try spawnProjectile(cast, .projectile_cube, direction, bullet_speed, bullet_lifetime, .{});
}

fn spreadShot(cast: Cast) !void {
    const direction = nz.vec.normalize(aimTarget(cast, 20) - cast.muzzle);
    const aimed_by_camera = cast.target == null and cast.caster.kind == .player;
    const right = if (aimed_by_camera)
        nz.vec.normalize(cameraRotation(cast.caster).rotateVec(.{ 1, 0, 0 }))
    else
        nz.vec.normalize(nz.vec.cross(direction, cast.up));
    const up = nz.vec.cross(right, direction);
    const rocket = rollsRocket(cast);
    const random = cast.world.prng.random();
    for (0..cast.assigned.hits) |_| {
        const theta = random.float(f32) * std.math.tau;
        const spread = random.float(f32) * 0.1;
        const offset = nz.vec.scale(
            right,
            @cos(theta) * spread,
        ) + nz.vec.scale(up, @sin(theta) * spread);
        const pellet = nz.vec.normalize(direction + offset);
        const speed_scale = nz.vec.length(direction + offset);
        if (rocket) {
            try spawnProjectile(
                cast,
                .projectile_rocket,
                pellet,
                rocket_speed * speed_scale,
                rocket_lifetime,
                .{ .invincible = true },
            );
        } else {
            try spawnProjectile(
                cast,
                .projectile_cube,
                pellet,
                bullet_speed * speed_scale,
                bullet_lifetime,
                .{ .invincible = true },
            );
        }
    }
}

fn dash(cast: Cast) void {
    const caster = cast.caster;
    const forward = if (cast.target) |aim|
        nz.vec.normalize(aim.transform.position - caster.transform.position)
    else if (caster.kind == .player)
        nz.vec.normalize(cameraRotation(caster).rotateVec(.{ 0, 0, -1 }))
    else
        nz.vec.normalize(caster.transform.forward());
    const along_ground = shared.math.projectOnPlane(forward, cast.up);
    cast.world.physics_commands.appendAssumeCapacity(.{
        .verb = .{
            .teleport = caster.transform.position + nz.vec.scale(along_ground, 2 * caster.stat(.speed)),
        },
        .id = caster.id,
    });
}

fn useEquipment(cast: Cast) void {
    const world = cast.world;
    const caster = cast.caster;
    const effect = shared.Item.equippedEffect(caster.inventory) orelse return;
    switch (effect) {
        .freeze_world => {
            if (world.world_unstun_at > world.elapsed_time) return;
            world.world_unstun_at = world.elapsed_time + freeze_seconds;
        },
        .heal_burst => for (world.players.items) |player_id| {
            const player = world.getPtr(player_id) orelse continue;
            if (nz.vec.distance(
                player.transform.position,
                caster.transform.position,
            ) > equipment_radius) continue;
            _ = combat.addHealth(world, player, player.max_health * 0.5, null);
        },
        .blast_wave => {
            const damage = caster.stat(.damage) * 5;
            for (world.entities.values()) |*candidate| {
                if (candidate.kind != .enemy or candidate.flags.is_dead) continue;
                if (nz.vec.distance(
                    candidate.transform.position,
                    caster.transform.position,
                ) > equipment_radius) continue;
                _ = combat.removeHealth(world, candidate, damage, caster);
            }
            world.client_updates.appendAssumeCapacity(.{
                .event = .{ .effect = .{ .rocket_impact = caster.transform.position } },
            });
        },
    }
}

fn meleeCone(cast: Cast) void {
    const caster = cast.caster;
    const forward = aimDirection(caster, cast.target, cast.up);
    for (cast.world.entities.values()) |*candidate| {
        if (!isFoe(caster, candidate)) continue;
        const offset = candidate.transform.position - caster.transform.position;
        const distance = nz.vec.length(offset);
        if (distance > cast.assigned.range or distance < 0.0001) continue;
        if (nz.vec.dot(nz.vec.scale(offset, 1 / distance), forward) < melee_cone_cosine) continue;
        _ = combat.removeHealth(cast.world, candidate, cast.damage(), caster);
    }
}

fn healPulse(cast: Cast) void {
    const caster = cast.caster;
    for (cast.world.entities.values()) |*ally| {
        if (!ally.kind.eql(caster.kind) or ally.flags.is_dead) continue;
        if (nz.vec.distance(
            ally.transform.position,
            caster.transform.position,
        ) > cast.assigned.radius) continue;
        _ = combat.addHealth(
            cast.world,
            ally,
            ally.max_health * cast.assigned.damage_multiplier,
            null,
        );
    }
}

fn isFoe(caster: *const Entity, candidate: *const Entity) bool {
    return candidate.max_health > 0 and !candidate.flags.is_dead and !candidate.kind.eql(
        caster.kind,
    );
}

fn aimPoint(
    world: *World,
    physics: *Physics,
    player_position: nz.Vec3(f32),
    camera_position: nz.Vec3(f32),
    camera_forward: nz.Vec3(f32),
) nz.Vec3(f32) {
    const player_depth = nz.vec.dot(player_position - camera_position, camera_forward);
    const ray_start = camera_position + nz.vec.scale(camera_forward, player_depth);
    const translation = nz.vec.scale(camera_forward, aim_range);
    const entity_distance: f32 = if (World.rayCast(
        physics,
        ray_start,
        translation,
    )) |hit| nz.vec.length(hit.point - ray_start) else aim_range;

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

fn aimDirection(
    caster: *const Entity,
    target: ?*const Entity,
    planet_up: nz.Vec3(f32),
) nz.Vec3(f32) {
    const forward = if (target) |target_entity|
        nz.vec.normalize(target_entity.transform.position - caster.transform.position)
    else if (caster.kind == .player) camera: {
        const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(
            caster.controller.input.camera_rotation,
        );
        break :camera nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
    } else nz.vec.normalize(caster.transform.forward());
    const flat = forward - nz.vec.scale(planet_up, nz.vec.dot(forward, planet_up));
    if (nz.vec.length(flat) < 0.0001) return nz.vec.normalize(caster.transform.forward());
    return nz.vec.normalize(flat);
}

fn playerAimPoint(world: *World, physics: *Physics, caster: *const Entity) nz.Vec3(f32) {
    const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(
        caster.controller.input.camera_rotation,
    );
    const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
    return aimPoint(
        world,
        physics,
        caster.transform.position,
        caster.controller.input.camera_position,
        camera_forward,
    );
}

fn blastAt(world: *World, caster: *Entity, center: nz.Vec3(f32), radius: f32, damage: f32) void {
    for (world.entities.values()) |*candidate| {
        if (!isFoe(caster, candidate)) continue;
        const distance = nz.vec.distance(candidate.transform.position, center);
        if (distance > radius) continue;
        _ = combat.removeHealth(world, candidate, damage * (1 - 0.5 * distance / radius), caster);
    }
    world.client_updates.appendAssumeCapacity(
        .{ .event = .{ .effect = .{ .rocket_impact = center } } },
    );
}
