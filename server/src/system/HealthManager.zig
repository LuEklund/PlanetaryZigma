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
    if (entity.flags.invinsible) return false;
    std.log.debug("tried taking dmg {d}, current health {d}", .{ amount, entity.health.current });
    return self.addHealth(entity, -amount);
}

pub fn addHealth(
    self: *@This(),
    entity: *Entity,
    amount: f32,
) bool {
    if (!entity.flags.health) return false;
    const health = &entity.health;
    health.current += amount;
    if (health.current <= 0) {
        try self.spawner.depspawn(entity.id);
    }
    std.log.debug("took dmg {d}, current health {d}", .{ amount, entity.health.current });
    self.network_manager.pending_add_health.appendAssumeCapacity(.{ .id = entity.id, .amount = amount });
    return true;
}
