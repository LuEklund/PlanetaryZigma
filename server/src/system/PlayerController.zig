const std = @import("std");
const shared = @import("shared");
const system = @import("../System.zig");
const World = system.World;
const Physics = @import("Physics.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

pub const aim_range: f32 = 300;
const rocket_speed: f32 = 65;
const bullet_speed: f32 = 100;
const rocket_lifetime: f32 = 2.5;
const bullet_lifetime: f32 = 1;

pub fn update(world: *World, physics: *Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id).?;
        if (player.flags.is_dead) continue;
        const camera = &player.camera;
        const transform = &player.transform;
        const controller = &player.controller;
        const input = &controller.input;

        const planet_up = nz.vec.normalize(transform.position);
        const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(input.camera_rotation);

        switch (input.dev_command) {
            .f1 => {
                // _ = world.giveItem(player, .freezer, 1);
                _ = try world.spawn(.{ .kind = .{ .enemy = .acorn }, .transform = player.transform });
            },
            .f2 => {
                _ = world.giveItem(player, .rocket, 1);
                _ = world.giveItem(player, .lightning, 1);
            },
            .f3 => {
                world.toggle_spawning_requested = true;
                for (world.entities.values()) |*entity| {
                    if (entity.kind == .enemy) _ = world.addHealth(entity, -entity.max_health, null);
                }
            },
            .f4 => if (world.getPtr(world.teleporter_id)) |teleporter| {
                const teleporter_up = shared.Planet.up(teleporter.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
                const random = world.prng.random();
                _ = world.spawn(.{
                    .kind = .{ .item = random.enumValue(shared.Item.Kind) },
                    .transform = .{
                        .position = teleporter.transform.position + nz.vec.scale(teleporter_up, 10),
                        .rotation = teleporter.transform.rotation,
                    },
                    .spawn_impulse = shared.Planet.surfaceLaunch(
                        teleporter.transform.position,
                        nz.vec.randomUnitVector(nz.Vec3(f32), world.prng.random()),
                        system.World.item_launch_angle,
                        system.World.item_throw_speed,
                    ),
                }) catch {};
            },
            .f5 => {
                world.next_stage_requested = true;
            },
            .f6 => {
                _ = world.addHealth(player, -player.health, null);
            },
            .f7 => {
                player.flags.invincible = !player.flags.invincible;
            },
            .f8 => if (world.getPtr(world.teleporter_id)) |teleporter| {
                const teleporter_up = shared.Planet.up(teleporter.transform.position) orelse .{ 0, 1, 0 };
                Physics.setPosition(player.collider.body_id.?, teleporter.transform.position + nz.vec.scale(teleporter_up, 10));
            },
            .f9 => world.start_round_requested = true,

            else => {},
        }
        input.dev_command = .none;

        const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
        const player_depth = nz.vec.dot(player.transform.position - input.camera_position, camera_forward);
        const ray_position_start = input.camera_position + nz.vec.scale(camera_forward, player_depth);
        const ray_position_end = nz.vec.scale(camera_forward, 5);
        const hit_id: shared.entity.Id = if (Physics.Ray.cast(physics, ray_position_start, ray_position_end)) |hit| hit.id else .none;
        if (player.interacting != hit_id) {
            player.interacting = hit_id;
            const interact_id: shared.entity.Id = if (world.getPtr(hit_id)) |hit_entity|
                switch (hit_entity.kind) {
                    .lootbox, .item => hit_id,
                    .teleporter => switch (hit_entity.teleporter.state) {
                        .active => .none,
                        else => hit_id,
                    },
                    else => .none,
                }
            else
                .none;
            world.client_updates.appendAssumeCapacity(.{ .event = .{ .interact = .{ .interactor = player_id, .interacted = interact_id } } });
        }

        if (player.controller.input.keys.interact and world.elapsed_time - player.last_attack >= player.stat(.primary_cooldown)) if (world.getPtr(player.interacting)) |entity| {
            player.last_attack = world.elapsed_time;
            switch (entity.kind) {
                .lootbox => if (player.currency >= entity.currency) {
                    world.queueDespawn(entity.id);

                    const random = world.prng.random();
                    var item_kind = random.enumValue(shared.Item.Kind);
                    if (item_kind == .lightning) item_kind = .oxygen_tank;
                    const chest_up = shared.Planet.up(entity.transform.position) orelse nz.Vec3(f32){ 0, 1, 0 };
                    _ = try world.spawn(.{
                        .kind = .{ .item = item_kind },
                        .transform = .{
                            .position = entity.transform.position + nz.vec.scale(chest_up, 1),
                            .rotation = entity.transform.rotation,
                        },
                        .spawn_impulse = nz.vec.scale(chest_up, system.World.item_throw_speed),
                    });
                    player.currency -= entity.currency;
                    world.client_updates.appendAssumeCapacity(.{ .currency = .{ .id = player_id, .amount = player.currency } });
                },
                .teleporter => {
                    const teleporter = &entity.teleporter;
                    if (teleporter.state == .idle) {
                        teleporter.state = .active;
                        world.client_updates.appendAssumeCapacity(.{ .event = .teleport_start });
                        world.client_updates.appendAssumeCapacity(.{ .event = .{ .interact = .{ .interactor = player_id, .interacted = .none } } });
                        const boss_surface = world.planet.surfacePointNear(entity.transform.position, 15, 25, world.prng.random());
                        _ = try world.spawn(.{
                            .kind = .{ .enemy = .bloorp_lord },
                            .transform = .{ .position = boss_surface + nz.vec.scale(nz.vec.normalize(boss_surface), 3) },
                            .flags = .{ .is_teleporter_boss = true },
                            .last_attack = world.elapsed_time,
                        });
                    } else {
                        if (teleporter.charged == teleporter.max_charge and world.teleport_bosses.items.len == 0) {
                            world.next_stage_requested = true;
                        }
                    }
                },
                .item => |item_kind| {
                    _ = world.giveItem(player, item_kind, 1) orelse continue;
                    world.queueDespawn(entity.id);
                },
                else => {},
            }
        };

        const fwd_proj = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
        const move_fwd = if (nz.vec.length(fwd_proj) > 0.0001)
            nz.vec.normalize(fwd_proj)
        else
            nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 }));
        const move_right = nz.vec.normalize(nz.vec.cross(move_fwd, planet_up));
        camera.yaw_rotation = .lookAt(move_fwd, planet_up);

        if (player.collider.body_id) |id| {
            var dir: nz.Vec3(f32) = .{ 0, 0, 0 };
            if (input.keys.move_forward) dir += move_fwd;
            if (input.keys.move_backward) dir -= move_fwd;
            if (input.keys.move_right) dir += move_right;
            if (input.keys.move_left) dir -= move_right;

            const speed = player.stat(.speed);

            if (input.keys.jump and player.mode == .walking) Physics.jump(player, 20);

            Physics.moveOnPlanet(player, dir, speed, world.delta_time);

            Physics.setRotation(id, camera.yaw_rotation);
            transform.rotation = camera.yaw_rotation;

            if (input.keys.reload) {
                camera.* = .{};
                transform.* = .{};
                Physics.setLinearVelocity(id, .{ 0, 0, 0 });
                Physics.setPosition(id, .{ 0, 0, 0 });
                Physics.setRotation(id, transform.rotation);
            }
        }
        if (input.keys.use_equipment and player.inventory.get(.freezer) > 0) {
            world.world_unstun_at = world.elapsed_time + 10;
        }

        if (input.keys.attack and world.elapsed_time - player.last_attack >= player.stat(.primary_cooldown)) {
            // _ = try world.spawn(.{ .kind = .{ .enemy = .healer }, .transform = player.transform });
            player.last_attack = world.elapsed_time;
            //TODO: hardcoded capsule half-height; becomes a muzzle socket.
            const muzzle_position = transform.position + nz.vec.scale(planet_up, 0.8);
            const aim_point = aimPoint(physics, &world.planet, transform.position, input.camera_position, camera_forward);
            const start_direction = nz.vec.normalize(aim_point - muzzle_position);
            const rocket_chance = player.stat(.rocket_chance);
            const fires_rocket = rocket_chance > 0 and world.prng.random().float(f32) < rocket_chance;
            const projectile_kind: shared.entity.ProjectileKind = if (fires_rocket) .rocket else .cube;
            const projectile_velocity = nz.vec.scale(start_direction, if (fires_rocket) rocket_speed else bullet_speed);
            _ = try world.spawn(.{
                .kind = switch (projectile_kind) {
                    .cube => .projectile_cube,
                    .rocket => .projectile_rocket,
                },
                .owner_id = player.id,
                .transform = .{
                    .position = muzzle_position + nz.vec.scale(start_direction, 1.0),
                    .rotation = shared.entity.projectileRotation(projectile_kind, start_direction, planet_up),
                },
                .replicated_velocity = projectile_velocity,
                .lifetime = if (fires_rocket) rocket_lifetime else bullet_lifetime,
                .damage = player.stat(.damage),
            });
            world.client_updates.appendAssumeCapacity(.{ .event = .{ .trigger = .{ .id = player_id, .state = .attack } } });
        }
    }
}

fn aimPoint(physics: *Physics, planet: *const shared.Planet, player_position: nz.Vec3(f32), camera_position: nz.Vec3(f32), camera_forward: nz.Vec3(f32)) nz.Vec3(f32) {
    const player_depth = nz.vec.dot(player_position - camera_position, camera_forward);
    const ray_start = camera_position + nz.vec.scale(camera_forward, player_depth);
    const translation = nz.vec.scale(camera_forward, aim_range);
    const entity_distance: f32 = if (Physics.Ray.cast(physics, ray_start, translation)) |hit| nz.vec.length(hit.point - ray_start) else aim_range;

    var terrain_distance: f32 = aim_range;
    var traveled: f32 = 0;
    for (0..128) |_| {
        const sample = ray_start + nz.vec.scale(camera_forward, traveled);
        const distance = planet.sample(sample);
        if (distance < 0.05) {
            terrain_distance = traveled;
            break;
        }
        traveled += @max(distance * 0.5, 0.05);
        if (traveled >= aim_range) break;
    }
    return ray_start + nz.vec.scale(camera_forward, @min(entity_distance, terrain_distance));
}
