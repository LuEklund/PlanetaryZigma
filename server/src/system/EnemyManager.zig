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

pub fn update(self: *@This(), info: *const Info, physics: *const Physics, health_manager: *HealthManager, network_manager: *NetworkManager, spawner: *Spawner) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    // std.log.debug("\n\neneties: {d}\n\n", .{info.world.entities.entries.len});

    if (info.world.players.items.len == 0) return;
    const player = info.world.getPtr(info.world.players.getLast()) orelse return;

    const body_interface = physics.physics_system.getBodyInterfaceMut();

    for (info.world.entities.values()) |*enemy| {
        if (!shared.Entity.isEnemy(enemy.kind)) continue;
        const body_id = enemy.collider.body_id orelse continue;

        const speed = enemy.inventory.getStat(.speed).current;
        const damage = enemy.inventory.getStat(.damage).current;
        const attack_speed = enemy.inventory.getStat(.attack_speed).current;

        const to_player = player.transform.position - enemy.transform.position;
        const distance = nz.vec.length(to_player);

        // entity.transform = player.transform;

        // Skip entities at (or near) world origin — planet_up is undefined there
        // and `nz.vec.normalize` returns the input unchanged on zero length.
        const up_len = nz.vec.length(enemy.transform.position);
        if (up_len < 0.0001) continue;
        const planet_up = nz.vec.scale(enemy.transform.position, 1.0 / up_len);

        // Project onto the tangent plane so enemies yaw toward the player but never pitch.
        // Skips when projection is degenerate (player on top of, or along up from, the enemy).
        const fwd_proj = to_player - nz.vec.scale(planet_up, nz.vec.dot(to_player, planet_up));
        if (nz.vec.length(fwd_proj) > 0.0001) {
            const forward = nz.vec.normalize(fwd_proj);
            const rot = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
            body_interface.setRotation(body_id, rot.toVec(), .activate);
        }

        if (distance < 4 and info.elapsed_time - enemy.last_attack >= attack_speed) {
            enemy.last_attack = info.elapsed_time;
            if (!health_manager.removeHealth(player, damage)) std.log.debug("did not take damage", .{});
        }

        switch (enemy.kind) {
            .skelly => {
                const moving = distance >= 3;
                const desired: shared.Entity.State =
                    if (distance < 4 and attack_speed < 1.0) .attack else if (moving) .walk else .idle;
                if (attack_speed == 0 or desired != enemy.state)
                    network_manager.pending_animatoin_state.appendAssumeCapacity(.{ .id = enemy.id, .state = desired });
                enemy.state = desired;
                if (distance < 3) continue;
                Physics.moveOnPlanet(body_interface, body_id, planet_up, enemy.transform.forward(), speed, 0);
            },
            .wizard => {
                // std.log.debug("elapsed_time {d}, cooldown {d}, attack_spped {d}", .{ info.elapsed_time, info.elapsed_time - enemy.last_attack, enemy.attack_speed });
                const desired: shared.Entity.State = if (distance < 40) .attack else .walk;
                // std.log.debug("desired {t}", .{desired});
                if (desired == .attack and info.elapsed_time - enemy.last_attack > 1 / attack_speed) {
                    if (desired == .attack) {
                        enemy.last_attack = info.elapsed_time;
                        const spawned = try spawner.spawn(.{
                            .kind = .skelly,
                            .transform = .{ .position = player.transform.position },
                            .collider = .{
                                .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 0.8, .radius = 0.8 } } },
                                .motion_type = .dynamic,
                                .object_layer = .moving,
                            },
                        });
                        spawned.inventory.initCombat(20, 10, 1, 1);
                        if (enemy.state != .attack) {
                            enemy.state = .attack;
                        }
                        enemy.last_attack = info.elapsed_time;
                        network_manager.pending_animatoin_state.appendAssumeCapacity(.{ .id = enemy.id, .state = .attack });
                    }
                } else {
                    if (distance < 40) continue;
                    if (enemy.state != .walk) {
                        enemy.state = .walk;
                        network_manager.pending_animatoin_state.appendAssumeCapacity(.{ .id = enemy.id, .state = .walk });
                    }
                    Physics.moveOnPlanet(body_interface, body_id, planet_up, enemy.transform.forward(), speed, 0);
                }
            },
            else => unreachable,
        }
    }
}
