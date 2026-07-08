const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const Physics = @import("Physics.zig");
const HealthManager = @import("HealthManager.zig");
const NetworkManager = @import("NetworkManager.zig");
const Info = system.Info;

gpa: std.mem.Allocator,
world: *system.World,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
    };
}

pub fn deinit(self: *@This()) !void {
    _ = self;
}

pub fn update(self: *@This(), info: *const Info, health_manager: *HealthManager, network_manager: *NetworkManager, spawner: *Spawner) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    // std.log.debug("\n\neneties: {d}\n\n", .{info.world.entities.entries.len});

    if (info.world.players.items.len == 0) return;
    const player = info.world.getPtr(info.world.players.getLast()) orelse return;

    for (info.world.entities.values()) |*enemy| {
        if (enemy.kind != .enemy) continue;
        const body_id = enemy.collider.body_id orelse continue;

        const to_player = player.transform.position - enemy.transform.position;
        const distance = nz.vec.length(to_player);

        // entity.transform = player.transform;

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
                    const bullet = try spawner.spawn(
                        .{
                            .kind = .bullet,
                            .owner_id = enemy.id,
                            .transform = .{ .position = enemy.transform.position + nz.vec.scale(forward_dir, 1.5), .rotation = player.transform.rotation },
                            .velocity = muzzle_velocity,
                            .bullet = .{ .velocity = muzzle_velocity, .lifetime = 2 },
                        },
                    );
                    bullet.stats.setCurrent(.damage, damage);
                    network_manager.pending_events.appendAssumeCapacity(.{ .attack = enemy.id });
                }
            },
            .tubloid => {
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack >= enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    if (!health_manager.removeHealth(player, damage)) std.log.debug("did not take damage", .{});
                    network_manager.pending_events.appendAssumeCapacity(.{ .attack = enemy.id });
                }
            },
            .wizard => {
                // std.log.debug("elapsed_time {d}, cooldown {d}, attack_spped {d}", .{ info.elapsed_time, info.elapsed_time - enemy.last_attack, enemy.attack_speed });
                const chase_dir: nz.Vec3(f32) = if (distance >= range) forward_dir else .{ 0, 0, 0 };
                Physics.moveTowardsOnPlanet(body_id, planet_up, chase_dir, speed, speed * 10, info.delta_time);
                if (distance < range and info.elapsed_time - enemy.last_attack > enemy.stats.attackSpeed()) {
                    enemy.last_attack = info.elapsed_time;
                    _ = try spawner.spawn(.{
                        .kind = .{ .enemy = .tubloid },
                        .transform = .{ .position = player.transform.position },
                        .collider = .{
                            .shape = .{ .primitive = shared.Entity.colliderShape(.{ .enemy = .tubloid }).? },
                            .motion_type = .dynamic,
                            .object_layer = .moving,
                        },
                    });

                    network_manager.pending_events.appendAssumeCapacity(.{ .attack = enemy.id });
                }
            },
        }
    }
}
