const std = @import("std");
const shared = @import("shared");
const World = @import("../World.zig");

/// Compact text snapshot of the client world for dev tools (`pz state`).
pub fn write(writer: *std.Io.Writer, world: *World, scene: []const u8, overlay: []const u8) !void {
    const radius = world.planet.planet_radius;
    try writer.print("scene {s} overlay {s} stage {d} radius {d} planet {s} fps {d:.0} time {d:.1}\n", .{
        scene,
        overlay,
        world.stage,
        radius,
        shared.PlanetType.forRadius(radius).name,
        world.fps,
        world.elapsed_time,
    });
    try writer.print("chunks {d} entities {d} free_camera {}\n", .{
        world.planet.chunks.count(),
        world.entities.count(),
        world.controller.free_camera,
    });
    if (world.getPtr(world.player_id)) |player| {
        const p = player.transform.position;
        try writer.print("player {s} pos {d:.1} {d:.1} {d:.1} hp {d:.0}/{d:.0} money {d}\n", .{
            @tagName(player.survivor),
            p[0],
            p[1],
            p[2],
            player.health,
            player.max_health,
            player.currency,
        });
    }

    if (world.getPtr(world.player_id)) |player| {
        var nearest: f32 = std.math.inf(f32);
        var nearest_name: []const u8 = "-";
        for (world.entities.values()) |*entity| {
            if (entity.kind != .enemy) continue;
            const distance = shared.numz.vec.distance(entity.transform.position, player.transform.position);
            if (distance >= nearest) continue;
            nearest = distance;
            nearest_name = @tagName(entity.kind.enemy);
        }
        try writer.print("nearest_enemy {s} {d:.1}m\n", .{ nearest_name, nearest });
    }

    var names: [shared.max_entities][]const u8 = undefined;
    var count: usize = 0;
    for (world.entities.values()) |*entity| {
        names[count] = switch (entity.kind) {
            .enemy => |enemy| @tagName(enemy),
            else => @tagName(entity.kind),
        };
        count += 1;
    }
    std.mem.sort([]const u8, names[0..count], {}, lessThan);
    try writer.writeAll("kinds");
    var index: usize = 0;
    while (index < count) {
        var end = index + 1;
        while (end < count and std.mem.eql(u8, names[end], names[index])) end += 1;
        try writer.print(" {s}={d}", .{ names[index], end - index });
        index = end;
    }
    try writer.writeByte('\n');
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
