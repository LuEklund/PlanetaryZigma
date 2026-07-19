const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

const Director = @import("../system/Director.zig");

pub const aim_range: f32 = 300;
const rocket_speed: f32 = 65;
const bullet_speed: f32 = 100;
const rocket_lifetime: f32 = 2.5;
const bullet_lifetime: f32 = 1;

pub fn update(info: *const system.Info, physics: *Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (info.world.players.items) |player_id| {
        const player = info.world.getPtr(player_id).?;
        const camera = &player.camera;
        const transform = &player.transform;
        const controller = &player.controller;
        const input = &controller.input;

        const planet_up = nz.vec.normalize(transform.position);
        const camera_rotation: nz.quat.Hamiltonian(f32) = .fromVec(input.camera_rotation);

        if (player.controller.input.keys.k and info.elapsed_time - player.last_attack >= 0.1) {
            std.log.debug("pres", .{});
            player.last_attack = info.elapsed_time;
            _ = try info.world.spawn(
                .{
                    .kind = .{ .item = .lightning },
                    .transform = player.transform,
                },
            );
            _ = try info.world.spawn(
                .{
                    .kind = .{ .item = .rocket },
                    .transform = player.transform,
                },
            );
            // _ = info.world.spawn(.{
            //     .kind = .{ .enemy = .tubloida },
            //     .transform = .{ .position = player.transform.position },
            //     .last_attack = info.elapsed_time,
            // });
        }

        const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
        const player_depth = nz.vec.dot(player.transform.position - input.camera_position, camera_forward);
        const ray_position_start = input.camera_position + nz.vec.scale(camera_forward, player_depth);
        const ray_position_end = nz.vec.scale(camera_forward, 5);
        const ray_hit = Physics.c.b3World_CastRayClosest(
            physics.world,
            .{ .x = ray_position_start[0], .y = ray_position_start[1], .z = ray_position_start[2] },
            .{ .x = ray_position_end[0], .y = ray_position_end[1], .z = ray_position_end[2] },
            Physics.c.b3DefaultQueryFilter(),
        );
        var hit_id: shared.entity.Id = .none;
        if (ray_hit.hit) {
            const hit_body = Physics.c.b3Shape_GetBody(ray_hit.shapeId);
            hit_id = @enumFromInt(@as(u32, @intCast(@intFromPtr(Physics.c.b3Body_GetUserData(hit_body)))));
        }
        if (player.interacting != hit_id) {
            player.interacting = hit_id;
            const interact_id: shared.entity.Id = if (info.world.getPtr(hit_id)) |hit_entity|
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
            info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .interact = .{ .interactor = player_id, .interacted = interact_id } } });
        }

        if (player.controller.input.keys.e) {
            if (info.world.getPtr(player.interacting)) |entity| {
                switch (entity.kind) {
                    .lootbox => {
                        if (player.currency >= entity.currency) {
                            info.world.queueDespawn(entity.id);

                            const random = info.world.prng.random();
                            const item_kind = random.enumValue(shared.Item.Kind);
                            try Director.spawnItem(info.world, item_kind, entity.transform.position);
                            player.currency -= entity.currency;
                            info.world.client_updates.appendAssumeCapacity(.{ .currency = .{ .id = player_id, .amount = player.currency } });
                        }
                    },
                    .teleporter => {
                        const teleporter = &entity.teleporter;
                        if (teleporter.state == .idle) {
                            teleporter.state = .active;
                            info.world.client_updates.appendAssumeCapacity(.{ .event = .teleport_start });
                            info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .interact = .{ .interactor = player_id, .interacted = .none } } });
                            const boss_surface = shared.planetSurfacePointNear(entity.transform.position, @floatFromInt(info.world.planet_radius), 15, 25, info.world.prng.random());
                            _ = try info.world.spawn(.{
                                .kind = .{ .enemy = .bloorpLord },
                                .transform = .{ .position = boss_surface + nz.vec.scale(nz.vec.normalize(boss_surface), 3) },
                                .flags = .{ .is_teleporter_boss = true },
                                .last_attack = info.elapsed_time,
                            });
                        } else {
                            if (teleporter.charged == teleporter.max_charge and info.world.teleport_bosses.items.len == 0) {
                                info.world.next_stage_requested = true;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        const fwd_proj = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
        const move_fwd = if (nz.vec.length(fwd_proj) > 0.0001)
            nz.vec.normalize(fwd_proj)
        else
            nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 }));
        const move_right = nz.vec.normalize(nz.vec.cross(move_fwd, planet_up));
        camera.yaw_rotation = .lookAt(move_fwd, planet_up);

        if (player.collider.body_id) |id| {
            var dir: nz.Vec3(f32) = .{ 0, 0, 0 };
            if (input.keys.w) dir += move_fwd;
            if (input.keys.s) dir -= move_fwd;
            if (input.keys.d) dir += move_right;
            if (input.keys.a) dir -= move_right;

            const speed = player.stats.get(.speed).current;

            var vertical: f32 = 0;
            if (input.keys.space) vertical += speed;
            if (input.keys.l_shift) vertical -= speed;

            Physics.moveOnPlanet(id, planet_up, dir, speed, vertical);

            Physics.setRotation(id, camera.yaw_rotation);
            transform.rotation = camera.yaw_rotation;

            if (input.keys.r) {
                camera.* = .{};
                transform.* = .{};
                Physics.setLinearVelocity(id, .{ 0, 0, 0 });
                Physics.setPosition(id, .{ 0, 0, 0 });
                Physics.setRotation(id, transform.rotation);
            }
        }

        if (input.keys.mouse_button_left and info.elapsed_time - player.last_attack >= player.stats.attackSpeed()) {
            player.last_attack = info.elapsed_time;
            const aim_point = aimPoint(physics, transform.position, input.camera_position, camera_forward);
            const start_direction = nz.vec.normalize(aim_point - transform.position);
            const rocket_chance = @min(
                @as(f32, @floatFromInt(player.inventory.get(.rocket))) *
                    shared.Item.Kind.rocket.getAttributeValues().rocket_chance,
                1.0,
            );
            const fires_rocket = rocket_chance > 0 and info.world.prng.random().float(f32) < rocket_chance;
            const projectile_kind: shared.entity.ProjectileKind = if (fires_rocket) .rocket else .cube;
            const projectile_velocity = nz.vec.scale(start_direction, if (fires_rocket) rocket_speed else bullet_speed);
            const projectile = try info.world.spawn(.{
                .kind = switch (projectile_kind) {
                    .cube => .projectile_cube,
                    .rocket => .projectile_rocket,
                },
                .owner_id = player.id,
                .transform = .{
                    .position = player.transform.position + nz.vec.scale(start_direction, 1.5),
                    .rotation = shared.entity.projectileRotation(projectile_kind, start_direction, planet_up),
                },
                .velocity = projectile_velocity,
                .lifetime = if (fires_rocket) rocket_lifetime else bullet_lifetime,
            });
            projectile.stats.setCurrent(.damage, player.stats.get(.damage).current);
            info.world.client_updates.appendAssumeCapacity(.{ .event = .{ .attack = player_id } });
        }
    }
}

fn aimPoint(physics: *Physics, player_position: nz.Vec3(f32), camera_position: nz.Vec3(f32), camera_forward: nz.Vec3(f32)) nz.Vec3(f32) {
    const player_depth = nz.vec.dot(player_position - camera_position, camera_forward);
    const ray_start = camera_position + nz.vec.scale(camera_forward, player_depth + 1.5);
    const translation = nz.vec.scale(camera_forward, aim_range);
    const result = Physics.c.b3World_CastRayClosest(physics.world, Physics.toB3(ray_start), Physics.toB3(translation), Physics.c.b3DefaultQueryFilter());
    if (result.hit) return Physics.toVec(result.point);
    return ray_start + translation;
}
