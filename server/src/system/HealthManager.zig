const HealthManager = @This();

const shared = @import("shared");
const NetworkManager = @import("NetworkManager.zig");
const Spawner = @import("Spawner.zig");
const Entity = @import("../system.zig").Entity;
const nz = shared.numz;

network_manager: *NetworkManager,
spawner: *Spawner,

pub fn init(network_manager: *NetworkManager, spawner: *Spawner) HealthManager {
    return .{ .network_manager = network_manager, .spawner = spawner };
}

pub fn removeHealth(self: *HealthManager, entity: *Entity, amount: f32) bool {
    if (!shared.Entity.hasHealth(entity.kind)) return false;
    if (entity.flags.invinsible) return false;
    return self.addHealth(entity, -amount);
}

pub fn addHealth(self: *HealthManager, entity: *Entity, amount: f32) bool {
    if (!shared.Entity.hasHealth(entity.kind)) return false;
    const current = entity.stats.addCurrent(.health, amount);
    if (current <= 0) {
        self.spawner.depspawn(entity.id);
    }
    self.network_manager.pending_stats.appendAssumeCapacity(.{ .id = entity.id, .stat_kind = .health, .amount = .{ .set_current = @floatCast(current) } });
    return true;
}
