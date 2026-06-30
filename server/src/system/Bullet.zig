const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const HealthManager = @import("HealthManager.zig");
const Spawner = @import("Spawner.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

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
        if (entity.kind != .bullet) continue;
        const bullet = &entity.bullet;

        bullet.lifetime -= dt;
        if (bullet.lifetime <= 0) {
            spawner.depspawn(entity.id);
            continue;
        }

        const previous_position = entity.transform.position;
        shared.bullet.step(&entity.transform.position, &bullet.velocity, dt);
        entity.velocity = bullet.velocity;
        const travel = entity.transform.position - previous_position;

        const ray_hit = query.castRay(.{
            .origin = .{ previous_position[0], previous_position[1], previous_position[2], 1 },
            .direction = .{ travel[0], travel[1], travel[2], 0 },
        }, .{});
        if (!ray_hit.has_hit) continue;

        const lock_interface = self.physics.physics_system.getBodyLockInterface();
        var hit_body_lock: Physics.zphy.BodyLockRead = .{};
        hit_body_lock.lock(lock_interface, ray_hit.hit.body_id);
        defer hit_body_lock.unlock();

        const hit_body = hit_body_lock.body orelse continue;
        const hit_id: u32 = @intCast(hit_body.user_data);
        if (hit_id == entity.owner_id) continue;

        const hit_entity = self.world.getPtr(hit_id) orelse continue;
        _ = health_manager.removeHealth(hit_entity, entity.damage);
        spawner.depspawn(entity.id);
    }
}
