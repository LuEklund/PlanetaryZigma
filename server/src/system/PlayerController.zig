const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

pub const aim_range: f32 = 300;

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
            player.last_attack = info.elapsed_time;
            _ = info.world.spawn(.{
                .kind = .{ .enemy = .tubloida },
                .transform = .{ .position = player.transform.position },
                .last_attack = info.elapsed_time,
            });
        }

        if (player.controller.input.keys.e) {
            if (info.world.getPtr(info.world.teleporter_id)) |entity| {
                const teleporter = &entity.teleporter;
                if (nz.vec.length(player.transform.position - entity.transform.position) < shared.teleporter.intertact_distance) {
                    if (!teleporter.active) {
                        teleporter.active = true;
                        info.world.outbox.appendAssumeCapacity(.{ .event = .teleport_start });
                        _ = info.world.spawn(.{
                            .kind = .{ .enemy = .wizard },
                            .transform = .{ .position = entity.transform.position + nz.vec.scale(nz.vec.normalize(entity.transform.position), 10) },
                            .flags = .{ .is_teleporter_boss = true },
                            .last_attack = info.elapsed_time,
                        });
                    } else {
                        if (teleporter.charged == teleporter.max_charge and info.world.teleport_bosses.items.len == 0) {
                            info.world.next_stage_requested = true;
                        }
                    }
                }
            }
        }

        const camera_forward = nz.vec.normalize(camera_rotation.rotateVec(.{ 0, 0, -1 }));
        const fwd_proj = camera_forward - nz.vec.scale(planet_up, nz.vec.dot(camera_forward, planet_up));
        const move_fwd = if (nz.vec.length(fwd_proj) > 0.0001)
            nz.vec.normalize(fwd_proj)
        else
            nz.vec.normalize(camera_rotation.rotateVec(.{ 1, 0, 0 }));
        const move_right = nz.vec.normalize(nz.vec.cross(move_fwd, planet_up));
        camera.yaw_rotation = .lookAt(move_fwd, planet_up);

        // --- Apply to body ---
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

        if (input.keys.mouse_button_left and info.elapsed_time - player.last_attack >= player.stats.attackSpeed()) {
            player.last_attack = info.elapsed_time;
            const aim_point = aimPoint(physics, transform.position, input.camera_position, camera_forward);
            const start_direction = nz.vec.normalize(aim_point - transform.position);
            const muzzle_velocity = nz.vec.scale(start_direction, 100);
            const bullet = info.world.spawn(.{
                .kind = .bullet,
                .owner_id = player.id,
                .transform = .{ .position = player.transform.position + nz.vec.scale(start_direction, 1.5), .rotation = player.transform.rotation },
                .velocity = muzzle_velocity,
                .lifetime = 1,
            });
            bullet.stats.setCurrent(.damage, player.stats.get(.damage).current);
            info.world.outbox.appendAssumeCapacity(.{ .event = .{ .attack = player_id } });
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
