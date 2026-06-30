const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const Spawner = @import("Spawner.zig");
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
    const body_interface = self.physics.physics_system.getBodyInterfaceMut();

    for (info.world.entities.values()) |*player| {
        if (player.kind != .player) continue;

        const camera = &player.camera;
        const transform = &player.transform;
        const controller = &player.controller;
        const input = &controller.input;

        // std.log.debug("handle input for: {d}", .{player.id});
        // std.log.debug("pos {any}", .{transform.position});

        camera.boom_offset[2] += @floatCast(-input.mouse_wheel);
        camera.boom_offset[2] = std.math.clamp(camera.boom_offset[2], 0, 1000);

        const planet_up = nz.vec.normalize(transform.position);

        const sensitivity: f32 = 1;
        const delta_yaw: f32 = @floatCast(-input.mouse_delta[0] * sensitivity * info.delta_time);
        const delta_pitch: f32 = @floatCast(-input.mouse_delta[1] * sensitivity * info.delta_time);

        if (input.keys.mouse_button_right) {
            // Yaw rotates around the *current* planet-up so looking is always tangent-aligned.
            const yaw_quat = nz.quat.Hamiltonian(f32).angleAxis(delta_yaw, planet_up);
            camera.yaw_rotation = yaw_quat.mul(camera.yaw_rotation).normalize();
            // Pitch stays as a scalar and is composed on top of yaw at render time.
            const pitch_limit: f32 = std.math.pi / 2.0 - 0.01;
            camera.pitch = std.math.clamp(camera.pitch + delta_pitch, -pitch_limit, pitch_limit);
        }

        const player_forward_direction = player.transform.forward();
        if (input.keys.mouse_button_left and info.elapsed_time - player.last_attack >= 1 / player.attack_speed) {
            player.last_attack = info.elapsed_time;
            const muzzle_velocity = nz.vec.scale(player_forward_direction, shared.bullet.muzzle_speed);
            _ = try self.spawner.spawn(
                .{
                    .kind = .bullet,
                    .owner_id = player.id,
                    .transform = .{ .position = player.transform.position + nz.vec.scale(player_forward_direction, 1.5), .rotation = player.transform.rotation },
                    .velocity = muzzle_velocity,
                    .bullet = .{ .velocity = muzzle_velocity, .lifetime = shared.bullet.lifetime },
                    .damage = player.damage,
                },
            );
        }
        if (player.controller.input.keys.k and info.elapsed_time - player.last_attack >= 0.1) {
            player.last_attack = info.elapsed_time;
            // for (info.world.entities.values()) |entry| {
            //     if (entry.kind != .player) self.spawner.depspawn(entry.id);
            // }
            // try self.spawner.startStage(info.world, self.physics);
            _ = try self.spawner.spawn(.{
                .kind = .skelly,
                .transform = .{ .position = .{ 0, 100, 0 } },
                .collider = .{
                    .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 0.8, .radius = 0.8 } } },
                    .motion_type = .dynamic,
                    .object_layer = .moving,
                },
                .health = .{ .current = 20, .max = 20 },
            });
        }

        if (player.controller.input.keys.e) {
            if (info.world.getPtr(info.world.teleportal.id)) |teleporter| {
                if (nz.vec.length(player.transform.position - teleporter.transform.position) < shared.Teleporter.intertact_distance) {
                    if (!info.world.teleportal.active) {
                        info.world.teleportal.active = true;
                        network_manager.pending_events.appendAssumeCapacity(.teleport_start);
                        _ = try self.spawner.spawn(.{
                            .kind = .wizard,
                            .transform = .{ .position = teleporter.transform.position + nz.vec.scale(nz.vec.normalize(teleporter.transform.position), 10) },
                            .collider = .{
                                .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 2, .radius = 2 } } },
                                .motion_type = .dynamic,
                                .object_layer = .moving,
                            },
                            .attack_speed = 0.25,
                            .health = .{ .current = 100, .max = 100 },
                            .flags = .{ .is_teleporter_boss = true },
                        });
                    } else {
                        if (info.world.teleportal.charged == info.world.teleportal.max_charge and info.world.teleport_bosses.items.len == 0) {
                            for (info.world.entities.values()) |entry| {
                                if (entry.kind != .player) self.spawner.depspawn(entry.id);
                            }
                            try self.spawner.startStage(info.world, self.physics);
                        }
                    }
                }
            }
        }

        // --- Tangent-plane realign ---
        // The player walks around a sphere, so planet_up drifts over time. Re-project the yaw
        // rotation so its local up matches the new planet_up (preserves facing direction).
        const cam_up = nz.vec.normalize(camera.yaw_rotation.rotateVec(.{ 0, 1, 0 }));
        const d = std.math.clamp(nz.vec.dot(cam_up, planet_up), -1.0, 1.0);
        if (d < 0.9999) {
            const cam_fwd_raw = nz.vec.normalize(camera.yaw_rotation.rotateVec(.{ 0, 0, -1 }));
            const axis: nz.Vec3(f32) = if (d > -0.9999)
                nz.vec.normalize(nz.vec.cross(cam_up, planet_up))
            else
                nz.vec.normalize(nz.vec.cross(cam_up, cam_fwd_raw));
            const angle = std.math.acos(d);
            const align_quat: nz.quat.Hamiltonian(f32) = .angleAxis(angle, axis);
            camera.yaw_rotation = align_quat.mul(camera.yaw_rotation).normalize();
        }

        // --- Planet-tangent movement basis ---
        // Projected camera forward: strips out any up-component so WASD moves over the surface.
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

            var vertical: f32 = 0;
            if (input.keys.space) vertical += player.speed;
            if (input.keys.l_shift) vertical -= player.speed;

            Physics.moveOnPlanet(body_interface, id, planet_up, dir, player.speed, vertical);
            const moving = nz.vec.length(dir) > std.math.floatEps(f32);
            const desired: shared.Entity.State =
                if (player.attack_speed < 1.0) .attack else if (moving) .walk else .idle;
            if (player.attack_speed == 0 or desired != player.state)
                network_manager.pending_animatoin_state.appendAssumeCapacity(.{ .id = player.id, .state = desired });
            player.state = desired;

            // Body yaw tracks camera yaw (pitch stays on the camera only).
            body_interface.setRotation(id, camera.yaw_rotation.toVec(), .activate);

            // if (input.forward) std.log.debug("new pos {any}", .{body_interface.getPosition(id)});
            if (input.keys.r) {
                camera.* = .{};
                transform.* = .{};
                body_interface.setLinearVelocity(id, .{ 0, 0, 0 });
                body_interface.setPosition(id, .{ 0, 0, 0 }, .activate);
                body_interface.setRotation(id, .{ 0, 0, 0, 1 }, .activate);
            }
        }
    }
}
