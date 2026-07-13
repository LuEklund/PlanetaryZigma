const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../system.zig");
const Info = system.Info;

pub fn update(info: *const Info) !void {
    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .item) continue;
        const item_kind = entity.kind.item;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            const length = player.transform.position - entity.transform.position;
            if (nz.vec.length(length) >= 2) continue;

            const item_count = player.inventory.add(item_kind, 1);
            player.stats.gain(item_kind, 1);
            player.stats.refresh(player.inventory);
            info.world.outbox.appendAssumeCapacity(.{ .inventory = .{
                .id = player_id,
                .item_kind = item_kind,
                .set = item_count,
            } });
            for (std.enums.values(shared.Stat.Kind)) |stat_kind| {
                if (item_kind.getAttributeValues().get(stat_kind) == 0) continue;
                const stat = player.stats.get(stat_kind);
                info.world.outbox.appendAssumeCapacity(.{ .stat = .{ .id = player_id, .stat_kind = stat_kind, .amount = .{ .set_max = @floatCast(stat.max) } } });
                info.world.outbox.appendAssumeCapacity(.{ .stat = .{ .id = player_id, .stat_kind = stat_kind, .amount = .{ .set_current = @floatCast(stat.current) } } });
            }

            info.world.queueDespawn(entity.id);
            std.log.debug("item {t}, count: {d}", .{ item_kind, item_count });
        }
    }
}
