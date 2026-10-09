const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const skills = @import("skills.zig");

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
    const toward = if (nz.vec.dot(to_player, to_player) < system.Navmesh.rebuild_distance * system.Navmesh.rebuild_distance)
        to_player
    else
        navmesh.direction(planet, enemy_position) orelse to_player;
    const goal = if (flee) -toward else toward;
    const up = shared.Planet.up(enemy_position) orelse return enemy_forward;
    const goal_tangent = goal - nz.vec.scale(up, nz.vec.dot(goal, up));
    if (nz.vec.dot(goal_tangent, goal_tangent) <= 0.000001) return enemy_forward;
    const forward_tangent = enemy_forward - nz.vec.scale(up, nz.vec.dot(enemy_forward, up));
    const heading = forward_tangent + nz.vec.scale(nz.vec.normalize(goal_tangent) - forward_tangent, 1 - @exp(-delta_time / heading_blend_seconds));
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
            const player_distance = nz.vec.distance(current_player.transform.position, enemy.transform.position);
            if (player_distance >= closest_distance) continue;
            closest_distance = player_distance;
            closest_player = current_player;
        }
        if (world.world_unstun_at > world.elapsed_time and closest_distance < 10) {
            continue;
        }

        const player = closest_player orelse continue;
        const to_player = player.transform.position - enemy.transform.position;
        const distance_to_player = nz.vec.length(to_player);

        const forward_dir = enemy.transform.forward();
        const speed = enemy.stat(.speed);
        const enemy_skills = enemy.kind.spec().skills;
        const range = enemy_skills.get(.primary).?.range;
        switch (enemy.kind.enemy) {
            .grass_tank => {},
            .tubloida => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                world.act(.{ .id = enemy.id, .verb = .{ .walk = .{ .direction = chase_dir, .speed = speed } } });
                if (skills.useAction(world, enemy, player, .primary) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, enemy_skills.get(.primary).?.skill);
                }
            },
            .tubloid => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                world.act(.{ .id = enemy.id, .verb = .{ .walk = .{ .direction = chase_dir, .speed = speed } } });
                if (skills.useAction(world, enemy, player, .primary) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, enemy_skills.get(.primary).?.skill);
                }
            },
            .bloorp_lord => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                world.act(.{ .id = enemy.id, .verb = .{ .hover = .{ .direction = chase_dir, .speed = speed, .height = 14 } } });
                if (skills.useAction(world, enemy, player, .primary) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, enemy_skills.get(.primary).?.skill);
                }
            },
            .hunkloid => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                if (enemy.mode == .walking) world.act(.{ .id = enemy.id, .verb = .{ .walk = .{ .direction = chase_dir, .speed = speed } } });
                const utility = enemy_skills.get(.utility).?;
                if (distance_to_player > utility.range * 0.75 and skills.useAction(world, enemy, player, .utility) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, utility.skill);
                }
                if (skills.useAction(world, enemy, player, .primary) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, enemy_skills.get(.primary).?.skill);
                }
            },
            .blooploid => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                world.act(.{ .id = enemy.id, .verb = .{ .hover = .{ .direction = chase_dir, .speed = speed, .height = 7 } } });
                if (skills.useAction(world, enemy, player, .primary) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, enemy_skills.get(.primary).?.skill);
                }
            },
            .acorn => {
                if (distance_to_player < 10) {
                    const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, true);
                    world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                    const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                    world.act(.{ .id = enemy.id, .verb = .{ .walk = .{ .direction = chase_dir, .speed = speed } } });
                    enemy.lifetime = 0;
                } else {
                    if (enemy.lifetime > 3)
                        _ = skills.useAction(world, enemy, null, .utility);
                    enemy.lifetime += world.delta_time;
                    continue;
                }
            },
            .grass1 => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                world.act(.{ .id = enemy.id, .verb = .{ .walk = .{ .direction = chase_dir, .speed = speed } } });
                if (skills.useAction(world, enemy, player, .primary) == .fired) {
                    try skills.executeSkill(world, physics, enemy, player, enemy_skills.get(.primary).?.skill);
                }
            },
            .healer => {
                const heading = steer(&world.navmesh, &world.planet, enemy.transform.position, forward_dir, player.transform.position, world.delta_time, false);
                world.act(.{ .id = enemy.id, .verb = .{ .face = heading } });
                const chase_dir: nz.Vec3(f32) = if (distance_to_player >= range) heading else .{ 0, 0, 0 };
                world.act(.{ .id = enemy.id, .verb = .{ .hover = .{ .direction = chase_dir, .speed = speed, .height = 7 } } });
                if (!skills.ready(enemy, .primary, world.elapsed_time)) continue;

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
                if (best) |heal_target| {
                    if (skills.useAction(world, enemy, heal_target, .primary) == .fired)
                        try skills.executeSkill(world, physics, enemy, heal_target, enemy_skills.get(.primary).?.skill);
                }
            },
        }
    }
}
