const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const Spawner = @import("Spawner.zig");
const BulletManager = @import("BulletManager.zig");
const NetworkManager = @import("NetworkManager.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

physics: *Physics,
spawner: *Spawner,

pub fn init(self: *@This(), physics: *Physics, spawner: *Spawner) !void {
    self.* = .{ .physics = physics, .spawner = spawner };
}

pub fn deinit(self: *@This()) void {
    _ = self;
}

pub fn update(self: *@This(), info: *const system.Info, network_manager: *NetworkManager) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (info.world.entities.values()) |*player| {
        if (player.kind != .player) continue;

        const camera = &player.camera;
        const transform = &player.transform;
        const controller = &player.controller;
        const input = &controller.input;

        // std.log.debug("handle input for: {d}", .{player.id});
        // std.log.debug("pos {any}", .{transform.position});

        const planet_up = nz.vec.normalize(transform.position);
        camera.yaw_rotation = .fromVec(input.camera_yaw_rotation);

        const player_forward_direction = player.transform.forward();
        if (input.keys.mouse_button_left and info.elapsed_time - player.last_attack >= player.stats.attackSpeed()) {
            player.last_attack = info.elapsed_time;
            const muzzle_velocity = nz.vec.scale(player_forward_direction, BulletManager.muzzle_speed);
            const bullet = try self.spawner.spawn(
                .{
                    .kind = .bullet,
                    .owner_id = player.id,
                    .transform = .{ .position = player.transform.position + nz.vec.scale(player_forward_direction, 1.5), .rotation = player.transform.rotation },
                    .velocity = muzzle_velocity,
                    .bullet = .{ .velocity = muzzle_velocity, .lifetime = BulletManager.lifetime },
                },
            );
            bullet.stats.setCurrent(.damage, player.stats.get(.damage).current);
        }
        if (player.controller.input.keys.k and info.elapsed_time - player.last_attack >= 0.1) {
            player.last_attack = info.elapsed_time;
            // try self.spawner.startStage(info.world, self.physics);

            // for (info.world.entities.values()) |entry| {
            //     if (entry.kind != .player) self.spawner.depspawn(entry.id);
            // }
            // try self.spawner.startStage(info.world, self.physics);
            // _ = try self.spawner.spawn(.{
            //     .kind = .attack_speed_item,
            //     .transform = .{ .position = player.transform.position },
            //     .collider = .{
            //         .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
            //         .motion_type = .dynamic,
            //         .object_layer = .planet_only,
            //     },
            // });
            const skelly = try self.spawner.spawn(.{
                .kind = .skelly,
                .transform = .{ .position = .{ 0, @as(f32, @floatFromInt(info.world.planet_radius)) + 10, 0 } },
                .collider = .{
                    .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 0.8, .radius = 0.8 } } },
                    .motion_type = .dynamic,
                    .object_layer = .moving,
                },
            });
            skelly.stats.init(20, 10, 1, 1);
        }

        if (player.controller.input.keys.e) {
            if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                const teleporter = &entity.teleporter;
                if (nz.vec.length(player.transform.position - entity.transform.position) < shared.teleporter.intertact_distance) {
                    if (!teleporter.active) {
                        teleporter.active = true;
                        network_manager.pending_events.appendAssumeCapacity(.teleport_start);
                        const wizard = try self.spawner.spawn(.{
                            .kind = .wizard,
                            .transform = .{ .position = entity.transform.position + nz.vec.scale(nz.vec.normalize(entity.transform.position), 10) },
                            .collider = .{
                                .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 2, .radius = 2 } } },
                                .motion_type = .dynamic,
                                .object_layer = .moving,
                            },
                            .flags = .{ .is_teleporter_boss = true },
                        });
                        wizard.stats.init(100, 10, 1, 0.25);
                    } else {
                        if (teleporter.charged == teleporter.max_charge and info.world.teleport_bosses.items.len == 0) {
                            for (info.world.entities.values()) |entry| {
                                if (entry.kind != .player) self.spawner.depspawn(entry.id);
                            }
                            try self.spawner.startStage(info.world, self.physics);
                        }
                    }
                }
            }
        }

        const cam_fwd = nz.vec.normalize(camera.yaw_rotation.rotateVec(.{ 0, 0, -1 }));
        const fwd_proj = cam_fwd - nz.vec.scale(planet_up, nz.vec.dot(cam_fwd, planet_up));
        const move_fwd = if (nz.vec.length(fwd_proj) > 0.0001)
            nz.vec.normalize(fwd_proj)
        else
            nz.vec.normalize(camera.yaw_rotation.rotateVec(.{ 1, 0, 0 }));
        const move_right = nz.vec.normalize(nz.vec.cross(move_fwd, planet_up));

        // --- Apply to body ---
        if (player.collider.body_id) |id| {
            var dir: nz.Vec3(f32) = .{ 0, 0, 0 };
            if (input.keys.w) dir += move_fwd;
            if (input.keys.s) dir -= move_fwd;
            if (input.keys.d) dir += move_right;
            if (input.keys.a) dir -= move_right;

            const speed = player.stats.get(.speed).current;
            const attack_speed = player.stats.get(.attack_speed).current;
            var vertical: f32 = 0;
            if (input.keys.space) vertical += speed;
            if (input.keys.l_shift) vertical -= speed;

            Physics.moveOnPlanet(id, planet_up, dir, speed, vertical);
            const moving = nz.vec.length(dir) > std.math.floatEps(f32);
            const desired: shared.Entity.State =
                if (attack_speed < 1.0) .attack else if (moving) .walk else .idle;
            if (attack_speed == 0 or desired != player.state)
                network_manager.pending_animatoin_state.appendAssumeCapacity(.{ .id = player.id, .state = desired });
            player.state = desired;

            // Body yaw tracks camera yaw (pitch stays on the camera only).
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
    }
}
