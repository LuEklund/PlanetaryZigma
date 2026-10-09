const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Entity = World.Entity;

pub fn giveItem(world: *World, player: *Entity, item: shared.Item.Kind, count: u8) ?u8 {
    if (player.inventory.get(item) >= 255) return null;
    if (shared.Item.get(item).is_equipment) for (std.enums.values(shared.Item.Kind)) |held| {
        if (held == item or !shared.Item.get(held).is_equipment or player.inventory.get(held) == 0) continue;
        player.inventory.set(held, 0);
        world.client_updates.appendAssumeCapacity(.{ .inventory = .{ .id = player.id, .item_kind = held, .set = 0 } });
    };
    const item_count = player.inventory.add(item, count);
    const old_max_health = player.max_health;
    player.max_health = player.stat(.health);
    player.health = @min(player.max_health, player.health + @max(0, player.max_health - old_max_health));
    world.client_updates.appendAssumeCapacity(.{ .inventory = .{
        .id = player.id,
        .item_kind = item,
        .set = item_count,
    } });
    world.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_max = @floatCast(player.max_health) } } });
    world.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_current = @floatCast(player.health) } } });
    return item_count;
}

pub fn updateItems(world: *World) !void {
    for (world.entities.values()) |*entity| {
        if (entity.kind != .item_pickup or entity.flags.is_dead) continue;
        const item_kind = entity.item.?;
        for (world.players.items) |player_id| {
            const player = world.getPtr(player_id) orelse continue;
            const length = player.transform.position - entity.transform.position;
            if (nz.vec.length(length) >= 2) continue;

            const item_count = giveItem(world, player, item_kind, 1) orelse continue;
            world.queueDespawn(entity.id);
            std.log.debug("item {t}, count: {d}", .{ item_kind, item_count });
            break;
        }
    }
}
