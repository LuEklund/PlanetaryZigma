const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const skills = @import("skills.zig");
const combat = @import("combat.zig");

const heading_blend_seconds: f32 = 0.15;

fn steer(
    navmesh: *const system.Navmesh,
    planet: *const shared.Planet,
    enemy_position: nz.Vec3(f32),
    enemy_forward: nz.Vec3(f32),
    player_position: nz.Vec3(f32),
    delta_time: f32,
    flee: bool,
) nz.Vec3(f32) {
    const to_player = player_position - enemy_position;
    const toward = if (nz.vec.dot(
        to_player,
        to_player,
    ) < system.Navmesh.rebuild_distance * system.Navmesh.rebuild_distance)
        to_player
    else
        navmesh.direction(planet, enemy_position) orelse to_player;
    const goal = if (flee) -toward else toward;
    const up = shared.Planet.up(enemy_position) orelse return enemy_forward;
    const goal_tangent = goal - nz.vec.scale(up, nz.vec.dot(goal, up));
    if (nz.vec.dot(goal_tangent, goal_tangent) <= 0.000001) return enemy_forward;
    const forward_tangent = enemy_forward - nz.vec.scale(up, nz.vec.dot(enemy_forward, up));
    const heading = forward_tangent + nz.vec.scale(
        nz.vec.normalize(goal_tangent) - forward_tangent,
        1 - @exp(-delta_time / heading_blend_seconds),
    );
    if (nz.vec.dot(heading, heading) <= 0.000001) return nz.vec.normalize(goal_tangent);
    return nz.vec.normalize(heading);
}

pub fn updateEnemies(world: *World, physics: *system.Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (world.players.items.len == 0) return;

    for (world.entities.values()) |*enemy| {
        if (enemy.kind != .enemy or enemy.flags.is_dead) continue;
        if (enemy.un_stun_at > world.elapsed_time) continue;

        var closest_player: ?*system.Entity = null;
        var closest_distance: f32 = std.math.floatMax(f32);
        for (world.players.items) |player_id| {
            const current_player = world.getPtr(player_id) orelse continue;
            const player_distance = nz.vec.distance(
                current_player.transform.position,
                enemy.transform.position,
            );
            if (player_distance >= closest_distance) continue;
            closest_distance = player_distance;
            closest_player = current_player;
        }
        if (world.world_unstun_at > world.elapsed_time) {
            continue;
        }

        const player = closest_player orelse continue;
        const to_player = player.transform.position - enemy.transform.position;
        const distance_to_player = nz.vec.length(to_player);

        const forward_dir = enemy.transform.forward();
        const speed = enemy.stat(.speed);
        const spec = enemy.kind.spec();
        const enemy_skills = spec.skills;
        const primary = enemy_skills.get(.primary) orelse continue;
        const context: Context = .{
            .world = world,
            .physics = physics,
            .enemy = enemy,
            .player = player,
            .distance = distance_to_player,
            .forward = forward_dir,
            .speed = speed,
            .primary = primary,
        };
        switch (spec.behavior) {
            .idle => {},
            .chase => try chase(context, .walk),
            .hover => |height| try chase(context, .{ .hover = height }),
            .leap => try leap(context),
            .plant => plant(context),
            .heal => |height| try heal(context, height),
            .kite => |kite_range| try kite(
                context,
                kite_range.min_distance,
                kite_range.max_distance,
            ),
            .orbit => |orbit_shape| try orbit(context, orbit_shape.radius, orbit_shape.height),
            .charge => |charge_tuning| charge(
                context,
                charge_tuning.trigger_distance,
                charge_tuning.windup_seconds,
                charge_tuning.dash_seconds,
                charge_tuning.speed_multiplier,
            ),
            .fuse => |fuse_tuning| fuse(
                context,
                fuse_tuning.fuse_seconds,
                fuse_tuning.blast_radius,
            ),
        }
    }
}

const Context = struct {
    world: *World,
    physics: *system.Physics,
    enemy: *system.Entity,
    player: *system.Entity,
    distance: f32,
    forward: nz.Vec3(f32),
    speed: f32,
    primary: shared.entity.AssignedSkill,
};

const Locomotion = union(enum) { walk, hover: f32 };

fn steerTo(context: Context, flee: bool) nz.Vec3(f32) {
    const world = context.world;
    return steer(
        &world.navmesh,
        &world.planet,
        context.enemy.transform.position,
        context.forward,
        context.player.transform.position,
        world.delta_time,
        flee,
    );
}

fn move(context: Context, locomotion: Locomotion, direction: nz.Vec3(f32), speed: f32) void {
    const id = context.enemy.id;
    switch (locomotion) {
        .walk => context.world.act(
            .{ .id = id, .verb = .{ .walk = .{ .direction = direction, .speed = speed } } },
        ),
        .hover => |height| context.world.act(
            .{
                .id = id,
                .verb = .{ .hover = .{ .direction = direction, .speed = speed, .height = height } },
            },
        ),
    }
}

fn firePrimary(context: Context, target: *system.Entity) !void {
    if (skills.useAction(context.world, context.enemy, target, .primary) == .fired) {
        try skills.executeSkill(
            context.world,
            context.physics,
            context.enemy,
            target,
            context.primary,
        );
    }
}

fn chase(context: Context, locomotion: Locomotion) !void {
    const direction = steerTo(context, false);
    context.world.act(.{ .id = context.enemy.id, .verb = .{ .face = direction } });
    const chase_direction: nz.Vec3(
        f32,
    ) = if (context.distance >= context.primary.range) direction else .{
        0,
        0,
        0,
    };
    move(context, locomotion, chase_direction, context.speed);
    try firePrimary(context, context.player);
}

fn leap(context: Context) !void {
    const enemy = context.enemy;
    const direction = steerTo(context, false);
    context.world.act(.{ .id = enemy.id, .verb = .{ .face = direction } });
    const chase_direction: nz.Vec3(
        f32,
    ) = if (context.distance >= context.primary.range) direction else .{
        0,
        0,
        0,
    };
    if (enemy.mode == .walking) move(context, .walk, chase_direction, context.speed);
    if (enemy.kind.spec().skills.get(.utility)) |utility| {
        if (context.distance > utility.range * 0.75 and skills.useAction(
            context.world,
            enemy,
            context.player,
            .utility,
        ) == .fired) {
            try skills.executeSkill(context.world, context.physics, enemy, context.player, utility);
        }
    }
    try firePrimary(context, context.player);
}

fn plant(context: Context) void {
    const enemy = context.enemy;
    if (context.distance < 10) {
        const direction = steerTo(context, true);
        context.world.act(.{ .id = enemy.id, .verb = .{ .face = direction } });
        const chase_direction: nz.Vec3(
            f32,
        ) = if (context.distance >= context.primary.range) direction else .{
            0,
            0,
            0,
        };
        move(context, .walk, chase_direction, context.speed);
        enemy.lifetime = 0;
        return;
    }
    if (enemy.lifetime > 3) _ = skills.useAction(context.world, enemy, null, .utility);
    enemy.lifetime += context.world.delta_time;
}

fn heal(context: Context, height: f32) !void {
    const world = context.world;
    const enemy = context.enemy;
    const direction = steerTo(context, false);
    world.act(.{ .id = enemy.id, .verb = .{ .face = direction } });
    const chase_direction: nz.Vec3(
        f32,
    ) = if (context.distance >= context.primary.range) direction else .{
        0,
        0,
        0,
    };
    move(context, .{ .hover = height }, chase_direction, context.speed);
    if (!skills.ready(enemy, .primary, world.elapsed_time)) return;

    var best: ?*system.Entity = null;
    var best_distance_sqr: f32 = std.math.floatMax(f32);
    for (world.entities.values()) |*entity| {
        if (entity.kind != .enemy or enemy.id == entity.id) continue;
        const offset = entity.transform.position - enemy.transform.position;
        const distance_sqr = nz.vec.dot(offset, offset);
        if (distance_sqr >= best_distance_sqr) continue;
        if (entity.health >= entity.max_health) continue;
        best_distance_sqr = distance_sqr;
        best = entity;
    }
    if (best) |heal_target| try firePrimary(context, heal_target);
}

fn kite(context: Context, min_distance: f32, max_distance: f32) !void {
    const flee = context.distance < min_distance;
    const direction = steerTo(context, flee);
    const face_direction = if (flee) steerTo(context, false) else direction;
    context.world.act(.{ .id = context.enemy.id, .verb = .{ .face = face_direction } });
    const move_direction: nz.Vec3(
        f32,
    ) = if (flee or context.distance > max_distance) direction else .{
        0,
        0,
        0,
    };
    move(context, .walk, move_direction, context.speed);
    try firePrimary(context, context.player);
}

fn orbit(context: Context, radius: f32, height: f32) !void {
    const enemy = context.enemy;
    const up = shared.Planet.up(enemy.transform.position) orelse return;
    const to_player = context.player.transform.position - enemy.transform.position;
    const flat = to_player - nz.vec.scale(up, nz.vec.dot(to_player, up));
    const flat_length = nz.vec.length(flat);
    if (flat_length < 0.0001) return;
    const inward = nz.vec.scale(flat, 1 / flat_length);
    const tangent = nz.vec.cross(up, inward);
    const radial_error = std.math.clamp((flat_length - radius) / radius, -1, 1);
    const direction = nz.vec.normalize(tangent + nz.vec.scale(inward, radial_error * 2));
    context.world.act(.{ .id = enemy.id, .verb = .{ .face = inward } });
    move(context, .{ .hover = height }, direction, context.speed);
    try firePrimary(context, context.player);
}

fn charge(
    context: Context,
    trigger_distance: f32,
    windup_seconds: f32,
    dash_seconds: f32,
    speed_multiplier: f32,
) void {
    const world = context.world;
    const enemy = context.enemy;
    const ai = &enemy.ai;
    switch (ai.phase) {
        .approach, .fuse => {
            const direction = steerTo(context, false);
            world.act(.{ .id = enemy.id, .verb = .{ .face = direction } });
            move(context, .walk, direction, context.speed);
            if (context.distance > trigger_distance) return;
            if (skills.useAction(world, enemy, context.player, .primary) != .fired) return;
            const up = shared.Planet.up(enemy.transform.position) orelse return;
            const to_player = context.player.transform.position - enemy.transform.position;
            const flat = to_player - nz.vec.scale(up, nz.vec.dot(to_player, up));
            if (nz.vec.length(flat) < 0.0001) return;
            ai.* = .{
                .phase = .windup,
                .phase_until = world.elapsed_time + windup_seconds,
                .direction = nz.vec.normalize(flat),
                .struck = false,
            };
        },
        .windup => {
            world.act(.{ .id = enemy.id, .verb = .{ .face = ai.direction } });
            move(context, .walk, .{ 0, 0, 0 }, context.speed);
            if (world.elapsed_time >= ai.phase_until) {
                ai.phase = .dash;
                ai.phase_until = world.elapsed_time + dash_seconds;
            }
        },
        .dash => {
            move(context, .walk, ai.direction, context.speed * speed_multiplier);
            if (!ai.struck) for (world.players.items) |player_id| {
                const player = world.getPtr(player_id) orelse continue;
                if (nz.vec.distance(
                    player.transform.position,
                    enemy.transform.position,
                ) > contact_distance) continue;
                _ = combat.removeHealth(world, player, enemy.stat(.damage), enemy);
                ai.struck = true;
                break;
            };
            if (world.elapsed_time >= ai.phase_until) ai.phase = .approach;
        },
    }
}

const contact_distance: f32 = 2;

fn fuse(context: Context, fuse_seconds: f32, blast_radius: f32) void {
    const world = context.world;
    const enemy = context.enemy;
    const ai = &enemy.ai;
    switch (ai.phase) {
        .approach, .windup, .dash => {
            const direction = steerTo(context, false);
            world.act(.{ .id = enemy.id, .verb = .{ .face = direction } });
            move(context, .walk, direction, context.speed);
            if (context.distance > context.primary.range) return;
            if (skills.useAction(world, enemy, context.player, .primary) != .fired) return;
            ai.phase = .fuse;
            ai.phase_until = world.elapsed_time + fuse_seconds;
            skills.telegraph(world, enemy.transform.position, blast_radius);
        },
        .fuse => {
            move(context, .walk, .{ 0, 0, 0 }, context.speed);
            if (world.elapsed_time < ai.phase_until) return;
            const damage = enemy.stat(.damage);
            for (world.players.items) |player_id| {
                const player = world.getPtr(player_id) orelse continue;
                const distance = nz.vec.distance(
                    player.transform.position,
                    enemy.transform.position,
                );
                if (distance > blast_radius) continue;
                _ = combat.removeHealth(
                    world,
                    player,
                    damage * (1 - 0.5 * distance / blast_radius),
                    enemy,
                );
            }
            world.client_updates.appendAssumeCapacity(
                .{ .event = .{ .effect = .{ .rocket_impact = enemy.transform.position } } },
            );
            _ = combat.addHealth(world, enemy, -enemy.health, null);
        },
    }
}
