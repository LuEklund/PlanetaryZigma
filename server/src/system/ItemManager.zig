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
        const item_kind = entity.kind.toItem() orelse continue;
        for (info.world.players.items) |player_id| {
            const player = info.world.getPtr(player_id) orelse return error.PlayerNotFound;
            const length = player.transform.position - entity.transform.position;
            if (nz.vec.length(length) >= 2) continue;

            const item_count = player.inventory.addItem(item_kind, 1);
            ctx.network_manager.pending_inventory.appendAssumeCapacity(.{
                .id = player_id,
                .item_kind = item_kind,
                .set = item_count,
            });
            // One item can touch several stats — mirror each one it moved (addItem already applied them).
            for (std.enums.values(shared.StatKind)) |stat_kind| {
                if (item_kind.stats().get(stat_kind) == 0) continue;
                const stat = player.inventory.getStat(stat_kind);
                ctx.network_manager.pending_stats.appendAssumeCapacity(.{ .id = player_id, .stat_kind = stat_kind, .amount = .{ .set_max = @floatCast(stat.max) } });
                ctx.network_manager.pending_stats.appendAssumeCapacity(.{ .id = player_id, .stat_kind = stat_kind, .amount = .{ .set_current = @floatCast(stat.current) } });
            }

            ctx.spawner.depspawn(entity.id);
            std.log.debug("item {t}, count: {d}", .{ item_kind, item_count });
        }
    }
}
