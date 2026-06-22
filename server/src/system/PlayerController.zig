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
        const f = player.flags;
        if (!f.controller or !f.camera or !f.transform or !f.collider) continue;

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

        if (input.mouse_button_right) {
            // Yaw rotates around the *current* planet-up so looking is always tangent-aligned.
            const yaw_quat = nz.quat.Hamiltonian(f32).angleAxis(delta_yaw, planet_up);
            camera.yaw_rotation = yaw_quat.mul(camera.yaw_rotation).normalize();
            // Pitch stays as a scalar and is composed on top of yaw at render time.
            const pitch_limit: f32 = std.math.pi / 2.0 - 0.01;
            camera.pitch = std.math.clamp(camera.pitch + delta_pitch, -pitch_limit, pitch_limit);
        }

        player.attack_cooldown += info.delta_time;
        if (input.mouse_button_left and player.attack_cooldown >= 1.0) {
            player.attack_cooldown = 0;
            const muzzle_speed: f32 = 100;
            const player_direction = player.transform.forward();
            const muzzle_velocity = nz.vec.scale(player_direction, muzzle_speed);
            _ = try self.spawner.spawn(
                .{
                    .kind = .bullet,
                    .owner_id = player.id,
                    .transform = .{ .position = player.transform.position + nz.vec.scale(player_direction, 1.5), .rotation = player.transform.rotation },
                    .bullet = .{ .velocity = muzzle_velocity, .lifetime = 5 },
                    .flags = .{ .transform = true, .bullet = true },
                    .damage = 5,
                },
            );
        }
        if (player.controller.input.k and player.attack_cooldown >= 0.1) {
            player.attack_cooldown = 0;
            _ = try self.spawner.spawn(.{
                .kind = .item,
                .transform = .{ .position = .{ 0, 100, 0 } },
                .collider = .{
                    .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
                    .motion_type = .dynamic,
                },
                .flags = .{
                    .collider = true,
                    .transform = true,
                    .item = true,
                },
                .item = .{ .amount = 10, .kind = .heal },
            });
            _ = try self.spawner.spawn(.{
                .kind = .enemy,
                .transform = .{ .position = .{ 0, 100, 0 } },
                .collider = .{
                    .shape = .{ .primitive = .{ .capsule = .{ .size = 1 } } },
                    .motion_type = .dynamic,
                },
                .health = .{ .current = 5, .max = 5 },
                .flags = .{ .transform = true, .collider = true, .health = true },
            });
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
            const speed: f32 = 10;
            var dir: nz.Vec3(f32) = .{ 0, 0, 0 };
            if (input.forward) dir += move_fwd;
            if (input.backward) dir -= move_fwd;
            if (input.right) dir += move_right;
            if (input.left) dir -= move_right;

            var vertical: f32 = 0;
            if (input.up) vertical += speed;
            if (input.down) vertical -= speed;

            Physics.moveOnPlanet(body_interface, id, planet_up, dir, speed, vertical);
            const moving = nz.vec.length(dir) > std.math.floatEps(f32);
            const desired: shared.Entity.State =
                if (player.attack_cooldown < 1.0) .attack else if (moving) .walk else .idle;
            if (player.attack_cooldown == 0 or desired != player.state)
                network_manager.pending_state.appendAssumeCapacity(.{ .id = player.id, .state = desired });
            player.state = desired;

            // Body yaw tracks camera yaw (pitch stays on the camera only).
            body_interface.setRotation(id, camera.yaw_rotation.toVec(), .activate);

            // if (input.forward) std.log.debug("new pos {any}", .{body_interface.getPosition(id)});
            if (input.r) {
                camera.* = .{};
                transform.* = .{};
                body_interface.setLinearVelocity(id, .{ 0, 0, 0 });
                body_interface.setPosition(id, .{ 0, 0, 0 }, .activate);
                body_interface.setRotation(id, .{ 0, 0, 0, 1 }, .activate);
            }
        }
    }
}
