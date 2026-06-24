const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("NetworkManager.zig");
const Spawner = @import("Spawner.zig");
const Entity = @import("../system.zig").Entity;
const nz = shared.numz;

pub const Health = struct {
    current: f32 = 0,
    max: f32 = 0,
};

network_manager: *NetworkManager,
spawner: *Spawner,

pub fn init(self: *@This(), network_manager: *NetworkManager, spawner: *Spawner) !void {
    self.* = .{
        .network_manager = network_manager,
        .spawner = spawner,
    };
}

pub fn removeHealth(
    self: *@This(),
    entity: *Entity,
    amount: f32,
) bool {
    if (!shared.Entity.hasHealth(entity.kind)) return false;
    if (entity.flags.invinsible) return false;
    return self.addHealth(entity, -amount);
}

pub fn addHealth(
    self: *@This(),
    entity: *Entity,
    amount: f32,
) bool {
    if (!shared.Entity.hasHealth(entity.kind)) return false;
    const health = &entity.health;
    health.current += amount;
    if (health.current <= 0) {
        self.spawner.depspawn(entity.id);
    }
    self.network_manager.pending_stats.appendAssumeCapacity(.{ .id = entity.id, .amount = .{ .add_health = @floatCast(amount) } });
    return true;
}
