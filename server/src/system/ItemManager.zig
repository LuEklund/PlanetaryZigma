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

pub fn update(self: *@This(), info: *const Info, ctx: *system.Context) !void {
    _ = self;
    for (info.world.entities.values()) |*entity| {
        const stat_kind = entity.kind.toStat() orelse continue;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            const player_position = player.transform.position;
            const item_position = entity.transform.position;
            const length = player_position - item_position;
            if (nz.vec.length(length) >= 2) continue;

            const quantity: u32 = 1;
            const item_count = player.inventory.addItem(stat_kind, quantity);
            ctx.network_manager.pending_inventory.appendAssumeCapacity(.{
                .id = player_id,
                .stat_kind = stat_kind,
                .set = item_count,
            });

            ctx.spawner.depspawn(entity.id);
            std.log.debug("item {t}, count: {d}", .{ stat_kind, item_count });
        }
    }
}
