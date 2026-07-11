const BulletManager = @This();

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

pub fn init(gpa: std.mem.Allocator, world: *system.World, physics: *Physics) BulletManager {
    return .{
        .gpa = gpa,
        .physics = physics,
        .world = world,
    };
}

pub fn deinit(self: *BulletManager) void {
    self.to_despawn.deinit(self.gpa);
}

pub fn update(
    self: *BulletManager,
    info: *const system.Info,
    health_manager: *HealthManager,
    spawner: *Spawner,
) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
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
        entity.transform.position += nz.vec.scale(bullet.velocity, dt);
        entity.velocity = bullet.velocity;
        const travel = entity.transform.position - previous_position;

        const ray_hit = Physics.c.b3World_CastRayClosest(
            self.physics.world,
            .{ .x = previous_position[0], .y = previous_position[1], .z = previous_position[2] },
            .{ .x = travel[0], .y = travel[1], .z = travel[2] },
            Physics.c.b3DefaultQueryFilter(),
        );
        if (!ray_hit.hit) continue;

        const hit_body = Physics.c.b3Shape_GetBody(ray_hit.shapeId);
        const hit_id: u32 = @intCast(@intFromPtr(Physics.c.b3Body_GetUserData(hit_body)));
        if (hit_id == entity.owner_id) continue;

        const owner_entity = self.world.getPtr(entity.owner_id) orelse continue;
        const hit_entity = self.world.getPtr(hit_id) orelse continue;
        if (owner_entity.kind.eql(hit_entity.kind)) continue;
        std.log.debug("{t} {t}", .{ owner_entity.kind, hit_entity.kind });

        _ = health_manager.removeHealth(hit_entity, entity.stats.get(.damage).current);
        spawner.depspawn(entity.id);
    }
}
