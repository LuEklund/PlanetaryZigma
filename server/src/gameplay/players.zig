const std = @import("std");
const system = @import("../System.zig");
const World = @import("../World.zig");
const combat = @import("combat.zig");
const stage = @import("stage.zig");

pub fn updateWipe(world: *World, gpa: std.mem.Allocator, physics: *system.Physics) !void {
    if (world.players.items.len == 0) return;
    for (world.players.items) |player_id| {
        if (world.getPtr(player_id) != null) return;
    }
    std.log.info("wipe: go again -> ship", .{});
    world.stage = 0;
    world.director.spawning = false;
    try stage.loadPlace(world, gpa, physics, .ship);
}

pub fn playerRegen(world: *World) void {
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        player.regen_carry += world.delta_time * player.stat(.regen);
        if (player.regen_carry < 1) continue;
        const whole_points = @floor(player.regen_carry);
        player.regen_carry -= whole_points;
        _ = combat.addHealth(world, player, whole_points, null);
    }
}
