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
        if (!shared.Entity.isItem(entity.kind)) continue;
        const item_kind = entity.kind;
        const amount = entity.item_amount;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            const player_position = player.transform.position;
            const item_position = entity.transform.position;
            const length = player_position - item_position;

            if (nz.vec.length(length) < 2) {
                const item_count = player.inventory.getPtr(item_kind).?;
                item_count.* += 1;
                ctx.network_manager.pending_inventory.appendAssumeCapacity(.{
                    .id = player_id,
                    .item_kind = item_kind,
                    .count = .{ .set = item_count.* },
                });
                switch (item_kind) {
                    .health_item => _ = ctx.health_manager.addHealth(player, amount),
                    .damage_item => player.damage += amount,
                    .speed_item => player.speed += amount,
                    .attack_speed_item => player.attack_speed += amount,
                    else => {},
                }
                ctx.spawner.depspawn(entity.id);
                std.log.debug("item {t}, amount: {d}", .{ item_kind, item_count.* });
            }
        }
    }
}
