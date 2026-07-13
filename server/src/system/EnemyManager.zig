const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const Info = system.Info;

pub fn update(info: *const Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (info.world.players.items.len == 0) return;
    const player = info.world.getPtr(info.world.players.getLast()) orelse return;

    for (info.world.entities.values()) |*enemy| {
        if (enemy.kind != .enemy) continue;
        const body_id = enemy.collider.body_id orelse continue;

        const to_player = player.transform.position - enemy.transform.position;
        const distance = nz.vec.length(to_player);

        const up_len = nz.vec.length(enemy.transform.position);
        if (up_len < 0.0001) continue;
        const planet_up = nz.vec.scale(enemy.transform.position, 1.0 / up_len);

        const fwd_proj = to_player - nz.vec.scale(planet_up, nz.vec.dot(to_player, planet_up));
        if (nz.vec.length(fwd_proj) > 0.0001) {
            const forward = nz.vec.normalize(fwd_proj);
            const rot = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
            Physics.setRotation(body_id, rot);
        }

        const forward_dir = enemy.transform.forward();
        const speed = enemy.stats.get(.speed).current;
        const damage = enemy.stats.get(.damage).current;
        const range = enemy.stats.get(.range).current;
        switch (enemy.kind.enemy) {
            .tubloida => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    const muzzle_velocity = nz.vec.scale(forward_dir, 50);
                    const bullet = info.world.spawn(.{
                        .kind = .bullet,
                        .owner_id = enemy.id,
                        .transform = .{ .position = enemy.transform.position + nz.vec.scale(forward_dir, 1.5), .rotation = player.transform.rotation },
                        .velocity = muzzle_velocity,
                        .bullet = .{ .velocity = muzzle_velocity, .lifetime = 2 },
                    });
                    bullet.stats.setCurrent(.damage, damage);
                    info.world.outbox.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
            .tubloid => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    if (!info.world.removeHealth(player, damage)) std.log.debug("did not take damage", .{});
                    info.world.outbox.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
            .wizard => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack > enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    _ = info.world.spawn(.{
                        .kind = .{ .enemy = .tubloid },
                        .transform = .{ .position = player.transform.position },
                        .last_attack = info.elapsed_time,
                    });
                    info.world.outbox.appendAssumeCapacity(.{ .event = .{ .attack = enemy.id } });
                }
            },
        }
    }
}
