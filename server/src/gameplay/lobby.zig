const std = @import("std");
const shared = @import("shared");
const World = @import("../World.zig");
const Entity = World.Entity;

pub fn setSurvivor(world: *World, player: *Entity, survivor: shared.Survivor.Kind) void {
    if (world.place != .ship) return;
    player.survivor = survivor;
    player.max_health = player.stat(.health);
    player.health = player.max_health;
    world.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_max = @floatCast(player.max_health) } } });
    world.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_current = @floatCast(player.health) } } });
    announce(world, player);
}

pub fn setReady(world: *World, player: *Entity, ready: bool) void {
    if (world.place != .ship or player.ready == ready) return;
    player.ready = ready;
    announce(world, player);
}

pub fn setDifficulty(world: *World, setting: shared.difficulty.Setting) void {
    if (world.place != .ship) return;
    world.difficulty_setting = setting;
    world.client_updates.appendAssumeCapacity(.{ .lobby_difficulty = setting });
}

pub fn updateLobby(world: *World) void {
    if (world.place != .ship or world.players.items.len == 0) return;
    for (world.players.items) |player_id| {
        const player = world.getPtrRaw(player_id) orelse return;
        if (!player.ready) return;
    }
    for (world.players.items) |player_id| {
        const player = world.getPtrRaw(player_id) orelse continue;
        player.ready = false;
        announce(world, player);
    }
    world.start_round_requested = true;
}

fn announce(world: *World, player: *const Entity) void {
    world.client_updates.appendAssumeCapacity(.{ .lobby_player = .{ .id = player.id, .survivor = player.survivor, .ready = player.ready } });
}
