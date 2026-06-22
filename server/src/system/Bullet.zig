const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const HealthManager = @import("HealthManager.zig");
const Spawner = @import("Spawner.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

const gravity_acceleration: f32 = 100;

gpa: std.mem.Allocator,
physics: *Physics,
world: *system.World,
to_despawn: std.ArrayList(u32) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World, physics: *Physics) !void {
    self.* = .{
        .gpa = gpa,
        .physics = physics,
        .world = world,
    };
}

pub fn deinit(self: *@This()) void {
    self.to_despawn.deinit(self.gpa);
}

pub fn update(
    self: *@This(),
    info: *const system.Info,
    health_manager: *HealthManager,
    spawner: *Spawner,
) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const query = self.physics.physics_system.getNarrowPhaseQuery();
    const dt = info.delta_time;

    self.to_despawn.clearRetainingCapacity();

    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.bullet or !entity.flags.transform) continue;
        const bullet = &entity.bullet;

        bullet.lifetime -= dt;
        if (bullet.lifetime <= 0) {
            spawner.depspawn(entity.id);
            continue;
        }

        const up = nz.vec.normalize(entity.transform.position);
        bullet.velocity += nz.vec.scale(-up, gravity_acceleration * dt);

        const p0 = entity.transform.position;
        const segment = nz.vec.scale(bullet.velocity, dt);

        const result = query.castRay(.{
            .origin = .{ p0[0], p0[1], p0[2], 1 },
            .direction = .{ segment[0], segment[1], segment[2], 0 },
        }, .{});

        if (result.has_hit) {
            const lock_interface = self.physics.physics_system.getBodyLockInterface();
            var read_lock: Physics.zphy.BodyLockRead = .{};
            read_lock.lock(lock_interface, result.hit.body_id);
            defer read_lock.unlock();
            if (read_lock.body) |hit_body| {
                const target_id: u32 = @intCast(hit_body.user_data);
                const hit_entity = self.world.getPtr(target_id) orelse continue;
                if (target_id == entity.owner_id) {
                    continue;
                }
                if (health_manager.removeHealth(hit_entity, entity.damage)) spawner.depspawn(entity.id);
            }
        }
        entity.transform.position = p0 + segment;
    }
}
