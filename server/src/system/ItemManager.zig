const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const HealthManager = @import("HealthManager.zig");
const Info = system.Info;

pub fn init(self: *@This()) !void {
    _ = self;
    return;
}

pub fn update(self: *@This(), info: *const Info, spawner: *Spawner, health_manager: *HealthManager) !void {
    _ = self;
    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.item) continue;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            player.flags.invinsible = false;
            const player_position = player.transform.position;
            const item_position = entity.transform.position;
            const length = player_position - item_position;
            if (nz.vec.length(length) < 1.4) {
                _ = health_manager.addHealth(player, entity.item.amount);
                spawner.depspawn(entity.id);
            }
        }
    }
}
